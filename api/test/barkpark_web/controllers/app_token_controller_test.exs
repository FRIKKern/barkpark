defmodule BarkparkWeb.AppTokenControllerTest do
  @moduledoc """
  Mobile charter D4/D5/D9 — the app-token exchange, instance half.

  `POST /v1/auth/app-tokens` is admin-bearer-gated (the `mint_login_ticket`
  idiom), JIT-provisions the cloud identity as a workspace MEMBER, and mints a
  member-shaped `[read,write,chat]` token via the EXISTING `Auth.create_token/5`
  (atomic token + role=member membership — no new mint primitive).

  The cross-tenant block is the D19a shape cloned from
  `chat_controller_test.exs` "cross-tenant isolation": two workspaces, two
  MINTED app tokens, wrong-tenant reads join the not-found oracle, the owner
  still reads its own, and a `:global` admin retains instance-wide authority.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Accounts
  alias Barkpark.Auth
  alias Barkpark.Repo
  alias Barkpark.Tenancy.Membership

  import Ecto.Query

  @dataset "production"

  setup do
    # The cross-tenant block drives /v1/chat with the minted tokens — same
    # fake-CLI + demo-off flips as chat_controller_test.exs, so session create
    # works without a real `claude` and RequireChatAccess is live.
    prev = Application.get_env(:barkpark, :claude_chat)
    prev_demo = Application.get_env(:barkpark, :public_demo_studio)
    Application.put_env(:barkpark, :claude_chat, enabled: true, command: {"cat", []})
    Application.put_env(:barkpark, :public_demo_studio, false)

    on_exit(fn ->
      Barkpark.StudioChat.RuntimeSupervisor
      |> DynamicSupervisor.which_children()
      |> Enum.each(fn
        {_, pid, _, _} when is_pid(pid) ->
          DynamicSupervisor.terminate_child(Barkpark.StudioChat.RuntimeSupervisor, pid)

        _ ->
          :ok
      end)

      if prev,
        do: Application.put_env(:barkpark, :claude_chat, prev),
        else: Application.delete_env(:barkpark, :claude_chat)

      Application.put_env(:barkpark, :public_demo_studio, prev_demo)
    end)

    admin = "app-token-admin-#{System.unique_integer([:positive])}"
    reader = "app-token-reader-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(admin, "app-admin", @dataset, ["read", "write", "admin"])
    {:ok, _} = Auth.create_token(reader, "app-reader", @dataset, ["read"])

    %{admin: admin, reader: reader}
  end

  defp as(conn, raw) do
    conn
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
  end

  defp json_conn(raw), do: as(scoped_conn(), raw)

  defp unique_email, do: "mobile-#{System.unique_integer([:positive])}@example.com"

  defp mint(bearer, body) do
    json_conn(bearer) |> post("/v1/auth/app-tokens", Jason.encode!(body))
  end

  defp memberships(ws_id, principal_id) do
    Repo.all(
      from(m in Membership,
        where: m.workspace_id == ^ws_id and m.principal_id == ^principal_id
      )
    )
  end

  describe "admin gate (mint_login_ticket idiom)" do
    test "no bearer → 401" do
      conn =
        scoped_conn()
        |> put_req_header("content-type", "application/json")
        |> post("/v1/auth/app-tokens", Jason.encode!(%{email: unique_email()}))

      assert json_response(conn, 401)
    end

    test "a non-admin bearer gets the SAME generic unauthorized as an invalid one (no tier oracle)",
         %{reader: reader} do
      ws = create_workspace!()

      lesser =
        mint(reader, %{email: unique_email(), workspace: ws.slug}) |> json_response(401)

      invalid =
        mint("not-a-real-token", %{email: unique_email(), workspace: ws.slug})
        |> json_response(401)

      assert lesser["error"]["code"] == invalid["error"]["code"]
    end
  end

  describe "mint — JIT member + member-shaped workspace-bound token (D4/D5/D9)" do
    test "201 mints [read,write,chat] bound to the workspace; user JIT-provisioned as member; token membership row is role=member",
         %{admin: admin} do
      ws = create_workspace!()
      email = unique_email()

      assert Accounts.get_user_by_email(email) == nil

      body = mint(admin, %{email: email, workspace: ws.slug}) |> json_response(201)

      assert "bpapp_" <> _ = body["token"]
      assert body["workspace_id"] == ws.id
      assert body["permissions"] == ["read", "write", "chat"]
      assert body["expires_at"] == nil
      refute "admin" in body["permissions"]

      # JIT identity: the user exists, confirmed, with a MEMBER seat (D5).
      user = Accounts.get_user_by_email(email)
      assert user != nil
      assert user.confirmed_at != nil

      assert [user_seat] = memberships(ws.id, user.id)
      assert user_seat.role == "member"
      assert user_seat.principal_type == "user"

      # The minted credential verifies and is member-shaped ROW-LEVEL (D9):
      # workspace-bound, [read,write,chat], and its membership row is
      # role=member / principal_type=api_token — never admin.
      assert {:ok, minted} = Auth.verify_token(body["token"])
      assert minted.workspace_id == ws.id
      assert Enum.sort(minted.permissions) == ["chat", "read", "write"]
      refute Auth.has_permission?(minted, "admin")

      assert [token_seat] = memberships(ws.id, minted.id)
      assert token_seat.role == "member"
      assert token_seat.principal_type == "api_token"
    end

    test "second mint for the same email reuses the identity — no duplicate user, no duplicate seat",
         %{admin: admin} do
      ws = create_workspace!()
      email = unique_email()

      first = mint(admin, %{email: email, workspace: ws.slug}) |> json_response(201)
      second = mint(admin, %{email: email, workspace: ws.slug}) |> json_response(201)

      # Two DISTINCT credentials (each device gets its own token)...
      assert first["token"] != second["token"]

      # ...but ONE identity and ONE member seat for the user.
      user = Accounts.get_user_by_email(email)
      assert [_one_seat] = memberships(ws.id, user.id)
    end

    test "workspace accepts an id as well as a slug", %{admin: admin} do
      ws = create_workspace!()

      body = mint(admin, %{email: unique_email(), workspace: ws.id}) |> json_response(201)
      assert body["workspace_id"] == ws.id
    end

    test "permissions may narrow within the allowlist but keep canonical order",
         %{admin: admin} do
      ws = create_workspace!()

      body =
        mint(admin, %{email: unique_email(), workspace: ws.slug, permissions: ["chat", "read"]})
        |> json_response(201)

      assert body["permissions"] == ["read", "chat"]
    end
  end

  describe "fail-closed validation" do
    test "missing / blank / non-email email → 422", %{admin: admin} do
      ws = create_workspace!()

      for bad <- [%{}, %{email: ""}, %{email: "   "}, %{email: "not-an-email"}] do
        conn = mint(admin, Map.put(bad, :workspace, ws.slug))
        assert json_response(conn, 422)["error"]["code"] == "unprocessable"
      end
    end

    test "admin (or any off-allowlist permission) is unmintable → 422, no token created",
         %{admin: admin} do
      ws = create_workspace!()
      email = unique_email()

      for perms <- [["read", "admin"], ["admin"], ["read", "delete"], [], "read"] do
        conn = mint(admin, %{email: email, workspace: ws.slug, permissions: perms})
        assert json_response(conn, 422)["error"]["code"] == "unprocessable"
      end

      # Nothing was JIT-provisioned on the rejected legs.
      assert Accounts.get_user_by_email(email) == nil
    end

    test "unknown workspace → 422; absent workspace falls back to the Default Workspace; no Default at all → 422 (never an unbound token)",
         %{admin: admin} do
      unknown =
        mint(admin, %{
          email: unique_email(),
          workspace: "no-such-workspace-#{System.unique_integer([:positive])}"
        })

      assert json_response(unknown, 422)["error"]["code"] == "unprocessable"

      # The migration backfill seeds a Default Workspace — an absent
      # `workspace` binds there (guerrilla's live shape).
      default_ws = Barkpark.Tenancy.get_default_workspace()
      assert default_ws != nil

      absent = mint(admin, %{email: unique_email()}) |> json_response(201)
      assert absent["workspace_id"] == default_ws.id

      # With NO Default Workspace resolvable the fallback fails CLOSED: a
      # workspace-less [read,write,chat] token is the tenant-less credential
      # this endpoint must never mint. (Rename inside the sandbox — rolled back.)
      default_ws
      |> Ecto.Changeset.change(slug: "default-hidden-#{System.unique_integer([:positive])}")
      |> Repo.update!()

      hidden = mint(admin, %{email: unique_email()})
      assert json_response(hidden, 422)["error"]["code"] == "unprocessable"
    end
  end

  describe "cross-tenant isolation — minted app tokens cannot reach another tenant (D19a shape)" do
    setup %{admin: admin} do
      ws_a = create_workspace!()
      ws_b = create_workspace!()

      token_a =
        mint(admin, %{email: unique_email(), workspace: ws_a.slug})
        |> json_response(201)
        |> Map.fetch!("token")

      token_b =
        mint(admin, %{email: unique_email(), workspace: ws_b.slug})
        |> json_response(201)
        |> Map.fetch!("token")

      %{ws_a: ws_a, ws_b: ws_b, token_a: token_a, token_b: token_b}
    end

    test "a ws-B app token hits the not-found oracle on ws-A's session across every id route, the owner still reads its own, and a :global admin reads both",
         %{admin: admin, token_a: token_a, token_b: token_b} do
      # ws-A's minted token creates a session (its `chat` permission +
      # workspace binding are LIVE through RequireChatAccess)...
      created =
        json_conn(token_a) |> post("/v1/chat/sessions", Jason.encode!(%{})) |> json_response(201)

      sid = created["id"]
      assert {:ok, _} = Ecto.UUID.cast(sid)

      # POSITIVE isolation leg: the owner reads back what it created and sees
      # it in its own list.
      assert json_conn(token_a) |> get("/v1/chat/sessions/#{sid}") |> json_response(200)

      a_listed = json_conn(token_a) |> get("/v1/chat/sessions") |> json_response(200)
      assert Enum.any?(a_listed["sessions"], &(&1["id"] == sid))

      # ws-B's minted token joins the not-found oracle on that session — the
      # wrong-tenant read is indistinguishable from a missing id (never 403).
      not_found_calls = [
        fn -> json_conn(token_b) |> get("/v1/chat/sessions/#{sid}") end,
        fn ->
          json_conn(token_b)
          |> post("/v1/chat/sessions/#{sid}/messages", Jason.encode!(%{content: "x"}))
        end,
        fn -> json_conn(token_b) |> post("/v1/chat/sessions/#{sid}/interrupt", "") end,
        fn ->
          json_conn(token_b)
          |> post(
            "/v1/chat/sessions/#{sid}/approval",
            Jason.encode!(%{request_id: "r", decision: "allow"})
          )
        end,
        fn -> json_conn(token_b) |> get("/v1/chat/sessions/#{sid}/events") end
      ]

      nonexistent =
        json_conn(token_b)
        |> get("/v1/chat/sessions/#{Ecto.UUID.generate()}")
        |> json_response(404)

      for call <- not_found_calls do
        body = call.() |> json_response(404)

        assert body["error"]["code"] == "not_found",
               "cross-tenant read must join the not-found oracle, not a distinct 403"

        assert body["error"]["code"] == nonexistent["error"]["code"]
      end

      # ws-B's list never surfaces ws-A's session, and the 404s are ISOLATION,
      # not a dead token: ws-B can create its OWN session.
      b_listed = json_conn(token_b) |> get("/v1/chat/sessions") |> json_response(200)
      refute Enum.any?(b_listed["sessions"], &(&1["id"] == sid))

      own =
        json_conn(token_b) |> post("/v1/chat/sessions", Jason.encode!(%{})) |> json_response(201)

      assert {:ok, _} = Ecto.UUID.cast(own["id"])

      # Admin control case: a :global admin retains instance-wide authority.
      assert json_conn(admin) |> get("/v1/chat/sessions/#{sid}") |> json_response(200)
    end
  end
end
