defmodule BarkparkWeb.ChatTokenControllerTest do
  @moduledoc """
  Controller tests for the admin-gated workspace-bound `chat` token mint
  (`POST /w/:ws/p/:project/v1/chat/tokens`, Connectors D36).

  The gap being closed: the connector bridge drove EVERY tenant with one global
  operator token. `RequireChatAccess.chat_scope/1` checks `admin` FIRST, so such
  a token resolves to `:global`, and `StudioChat`'s `owner_ws_from_scope/1`
  stamps `owner_workspace_id = NULL` — every bridge session was TENANT-LESS. A
  `["chat"]`-only, workspace-bound token instead resolves to `{:workspace, ws}`
  and stamps the real tenant.

  The invariants under test:

    * SCOPED-ADMIN GATE — only an owner/admin of the workspace can mint; a member
      (even one holding global admin perms) → 403; a non-member → 403; anonymous
      → 401/403/404.
    * NO PRIVILEGE-MINT — the permission set is hardcoded `["chat"]`; a body
      asking for `admin`/`write` is ignored, and the PERSISTED token holds only
      `["chat"]`.
    * THE CLOSE — a session created with the minted token is stamped with the
      REAL workspace, not NULL.
    * CROSS-TENANT — ws_A's minted token hits the 404 not-found oracle on a ws_B
      session and never sees it in a list read.

  PROTECTIVE: mutating `@permissions` in the controller to `["chat", "admin"]`
  reds THE CLOSE (`expected owner_workspace_id=…, got nil`) and CROSS-TENANT
  (leak) — the suite fails for the right reason, not a vacuous green.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, StudioChat, Tenancy}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  setup do
    {:ok, ws_a} = Tenancy.create_workspace(%{slug: "chat-mint-a", name: "Chat Mint A"})
    {:ok, _proj_a} = Tenancy.create_project(ws_a, %{slug: "default", name: "Default"})

    {:ok, ws_b} = Tenancy.create_workspace(%{slug: "chat-mint-b", name: "Chat Mint B"})
    {:ok, _proj_b} = Tenancy.create_project(ws_b, %{slug: "default", name: "Default"})

    # ADMIN of ws_a — the legit minter. Admin authority on the scoped surface is
    # the membership ROLE, not the token's global permissions[].
    admin_raw = "chat-admin-#{System.unique_integer([:positive])}"
    {:ok, admin_tok} = Auth.create_token(admin_raw, "admin", @dataset, ["read", "write", "admin"])
    {:ok, _} = TenancyAuth.create_membership(ws_a.id, admin_tok.id, "admin")

    # MEMBER of ws_a holding global admin perms — must NOT be able to mint.
    member_raw = "chat-member-#{System.unique_integer([:positive])}"

    {:ok, member_tok} =
      Auth.create_token(member_raw, "member", @dataset, ["read", "write", "admin"])

    {:ok, _} = TenancyAuth.create_membership(ws_a.id, member_tok.id)

    # NON-MEMBER with global admin perms — no membership in ws_a at all.
    nonmember_raw = "chat-nonmember-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(nonmember_raw, "nonmember", @dataset, ["read", "write", "admin"])

    %{
      ws_a: ws_a,
      ws_b: ws_b,
      admin_raw: admin_raw,
      member_raw: member_raw,
      nonmember_raw: nonmember_raw
    }
  end

  defp authed(conn, raw) do
    conn
    |> put_req_header("authorization", "Bearer " <> raw)
    |> put_req_header("content-type", "application/json")
  end

  defp mint(conn, raw, body) do
    conn
    |> authed(raw)
    |> post("/w/chat-mint-a/p/default/v1/chat/tokens", Jason.encode!(body))
  end

  defp mint_token!(conn, raw, label) do
    resp = mint(conn, raw, %{"label" => label})
    assert resp.status == 201
    resp.resp_body |> Jason.decode!() |> Map.fetch!("token")
  end

  describe "admin mint (happy path)" do
    test "workspace admin mints a chat token: 201, permissions are exactly [\"chat\"]", %{
      conn: conn,
      admin_raw: raw
    } do
      resp = mint(conn, raw, %{"label" => "slack-install"})
      assert resp.status == 201
      body = Jason.decode!(resp.resp_body)

      assert is_binary(body["token"]) and byte_size(body["token"]) > 0
      assert body["label"] == "slack-install"
      assert body["permissions"] == ["chat"]
      assert body["dataset"] == "production"
      assert body["workspace"] == "chat-mint-a"
    end

    test "the minted token is BOUND to the workspace (workspace_id + membership row)", %{
      conn: conn,
      admin_raw: raw,
      ws_a: ws_a
    } do
      minted = mint_token!(conn, raw, "install")

      {:ok, tok} = Auth.verify_token(minted)
      assert tok.permissions == ["chat"]
      assert tok.workspace_id == ws_a.id

      # create_token/5 with a workspace_id also grants the tenancy membership —
      # role `member` (role_for_permissions/1 only grants admin for an "admin"
      # permission), so a chat token can never mint another chat token.
      assert TenancyAuth.membership_role(tok, ws_a.id) == "member"
    end

    test "dataset defaults to production and is overridable", %{conn: conn, admin_raw: raw} do
      default = mint(conn, raw, %{"label" => "d"}) |> Map.get(:resp_body) |> Jason.decode!()
      assert default["dataset"] == "production"

      override =
        mint(conn, raw, %{"label" => "d2", "dataset" => "staging"})
        |> Map.get(:resp_body)
        |> Jason.decode!()

      assert override["dataset"] == "staging"
      # The dataset leaf is caller-chosen; the permission set never is.
      assert override["permissions"] == ["chat"]
    end
  end

  describe "no privilege-mint (permissions are HARDCODED)" do
    test "a body asking for admin/write is IGNORED — the mint is still [\"chat\"]", %{
      conn: conn,
      admin_raw: raw
    } do
      resp =
        mint(conn, raw, %{
          "label" => "evil",
          "permissions" => ["admin", "write", "chat"]
        })

      assert resp.status == 201
      minted = Jason.decode!(resp.resp_body)
      assert minted["permissions"] == ["chat"]

      # And the PERSISTED token really holds only ["chat"] — not just the
      # response body. A response-only assertion would pass on a token that was
      # written with admin.
      {:ok, tok} = Auth.verify_token(minted["token"])
      assert tok.permissions == ["chat"]
      refute Auth.has_permission?(tok, "admin")
      refute Auth.has_permission?(tok, "write")
    end

    test "the minted chat token cannot mint another token (no self-escalation)", %{
      conn: conn,
      admin_raw: raw
    } do
      minted = mint_token!(conn, raw, "install")

      resp =
        scoped_conn()
        |> authed(minted)
        |> post(
          "/w/chat-mint-a/p/default/v1/chat/tokens",
          Jason.encode!(%{"label" => "escalate"})
        )

      assert resp.status in [401, 403, 404]
    end
  end

  describe "scoped-admin gate" do
    test "a member of the workspace (global admin perms) → 403", %{conn: conn, member_raw: raw} do
      resp = mint(conn, raw, %{"label" => "nope"})
      assert resp.status == 403
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "forbidden"
    end

    test "a non-member (global admin perms) → 403", %{conn: conn, nonmember_raw: raw} do
      resp = mint(conn, raw, %{"label" => "nope"})
      assert resp.status == 403
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "forbidden"
    end

    test "anonymous → 401/403/404 (no token)", %{conn: conn} do
      resp =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/w/chat-mint-a/p/default/v1/chat/tokens", Jason.encode!(%{"label" => "nope"}))

      assert resp.status in [401, 403, 404]
    end
  end

  describe "the close — a minted token stamps the REAL tenant" do
    test "a session created with the minted token is stamped owner_workspace_id = the workspace (not NULL)",
         %{conn: conn, admin_raw: raw, ws_a: ws_a} do
      minted = mint_token!(conn, raw, "install")

      resp =
        scoped_conn()
        |> authed(minted)
        |> post("/v1/chat/sessions", Jason.encode!(%{mode: "plan"}))

      assert resp.status == 201
      sid = Jason.decode!(resp.resp_body)["id"]

      # Read at :global scope so the assertion sees the raw stamp, not a
      # scope-filtered view that could hide a NULL owner.
      session = StudioChat.get_session(sid)

      # THE assertion. With the old global operator/admin token this is NIL
      # (RequireChatAccess resolves `admin` → :global → owner stamped NULL).
      assert session.owner_workspace_id == ws_a.id,
             "expected owner_workspace_id=#{ws_a.id}, got #{inspect(session.owner_workspace_id)}"
    end

    test "CROSS-TENANT: ws_A's minted token cannot read a ws_B session (404 oracle)", %{
      conn: conn,
      admin_raw: raw,
      ws_b: ws_b
    } do
      tok_a = mint_token!(conn, raw, "a")

      # A session owned by ws_B, created directly at the sealed store layer.
      {:ok, sess_b} =
        StudioChat.create_session(
          %{id: Ecto.UUID.generate(), title: "b-secret"},
          {:workspace, ws_b.id}
        )

      assert sess_b.owner_workspace_id == ws_b.id

      resp = scoped_conn() |> authed(tok_a) |> get("/v1/chat/sessions/#{sess_b.id}")

      assert resp.status == 404,
             "ws_A's chat token READ ws_B's session (status #{resp.status}) — CROSS-TENANT LEAK"

      # And it is absent from the list read too — a 404 on the id route with a
      # leaky index would still expose the title in the sidebar.
      list = scoped_conn() |> authed(tok_a) |> get("/v1/chat/sessions")
      ids = Jason.decode!(list.resp_body)["sessions"] |> Enum.map(& &1["id"])

      refute sess_b.id in ids, "ws_A's chat token LISTED ws_B's session — CROSS-TENANT LEAK"
    end
  end

  describe "validation" do
    test "missing label → 422, no token issued", %{conn: conn, admin_raw: raw} do
      resp = mint(conn, raw, %{})
      assert resp.status == 422
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "unprocessable"
    end

    test "blank label → 422", %{conn: conn, admin_raw: raw} do
      resp = mint(conn, raw, %{"label" => "   "})
      assert resp.status == 422
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "unprocessable"
    end
  end
end
