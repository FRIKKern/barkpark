defmodule BarkparkWeb.ShareControllerTest do
  @moduledoc """
  P4b — contract tests for `/v1/shares`, the admin-only sharing registry CRUD
  behind `bp share ls/add/rm`.

  Covers:
    * auth gating — 401 anon, 403 non-admin, 200 admin on every verb
    * add upserts a stored share and makes it live (shared?/4)
    * add rejects an invalid scope/surface (422, no row)
    * rm removes a stored share and refreshes the live list
    * ls reports both the env baseline and stored shares, tagged by source

  `async: false`: the registry lives in the process-global `:barkpark, :shares`
  / `:shares_env` env, restored on_exit.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Repo, Sharing}
  alias Barkpark.Auth.ApiToken

  @admin_token "barkpark-test-admin-share"
  @junior_token "barkpark-test-junior-share"

  setup do
    {:ok, _} = Auth.create_token(@admin_token, "share-admin", "test", ["read", "write", "admin"])
    {:ok, _} = Auth.create_token(@junior_token, "share-junior", "test", ["read", "write"])

    prior_shares = Application.get_env(:barkpark, :shares)
    prior_env = Application.get_env(:barkpark, :shares_env)
    Application.put_env(:barkpark, :shares, [])
    Application.put_env(:barkpark, :shares_env, [])

    on_exit(fn ->
      restore(:shares, prior_shares)
      restore(:shares_env, prior_env)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:barkpark, key)
  defp restore(key, value), do: Application.put_env(:barkpark, key, value)

  defp admin_conn(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @admin_token)
    |> put_req_header("content-type", "application/json")
  end

  defp junior_conn(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @junior_token)
    |> put_req_header("content-type", "application/json")
  end

  # ── auth gating ─────────────────────────────────────────────────────────

  describe "auth gating" do
    test "GET /v1/shares is 401 anon, 403 junior, 200 admin", %{conn: conn} do
      assert get(conn, "/v1/shares").status == 401
      assert get(junior_conn(conn), "/v1/shares").status == 403
      assert get(admin_conn(conn), "/v1/shares").status == 200
    end

    test "POST /v1/shares is 401 anon, 403 junior", %{conn: conn} do
      body = %{scope: "gyldendal/default/production", surfaces: "papers"}
      assert post(conn, "/v1/shares", body).status == 401
      assert post(junior_conn(conn), "/v1/shares", body).status == 403
      # the rejected writes never persisted a share
      refute Sharing.shared?("gyldendal", "default", "production", :papers)
    end

    test "DELETE /v1/shares is 401 anon, 403 junior", %{conn: conn} do
      assert delete(conn, "/v1/shares", %{scope: "x"}).status == 401
      assert delete(junior_conn(conn), "/v1/shares", %{scope: "x"}).status == 403
    end
  end

  describe "canonical error envelope" do
    test "validation (422) and not_found (404) are code + request_id objects, not bare strings",
         %{conn: conn} do
      # Missing scope → 422. Was a bare `%{"error" => "scope is required"}`;
      # now a keyable code + the human message + a request_id.
      bad = conn |> admin_conn() |> post("/v1/shares", %{surfaces: "papers"})
      body = json_response(bad, 422)
      assert body["error"]["code"] == "validation_failed"
      assert body["error"]["message"] == "scope is required"
      assert is_binary(body["error"]["request_id"])

      # Revoking a nonexistent share-edit token → 404 canonical envelope.
      nf =
        conn |> admin_conn() |> delete("/v1/shares/tokens/11111111-1111-1111-1111-111111111111")

      nfb = json_response(nf, 404)
      assert nfb["error"]["code"] == "not_found"
      assert nfb["error"]["message"] == "token not found"
      assert is_binary(nfb["error"]["request_id"])
    end

    test "a malformed (non-UUID) token id is a clean 404, not an Ecto CastError 500", %{
      conn: conn
    } do
      # revoke_token queries ApiToken by :binary_id; before the UUID-cast guard a
      # garbage id raised Ecto.CastError → 500. Now it's a canonical 404.
      resp = conn |> admin_conn() |> delete("/v1/shares/tokens/not-a-uuid")
      assert json_response(resp, 404)["error"]["code"] == "not_found"
    end
  end

  # ── add (POST) ──────────────────────────────────────────────────────────

  describe "POST /v1/shares" do
    test "creates a share and it goes live immediately", %{conn: conn} do
      body = %{scope: "gyldendal/books/production", surfaces: "papers,docs", access: "read"}

      resp = conn |> admin_conn() |> post("/v1/shares", body)
      assert resp.status == 201
      assert %{"share" => share} = json_response(resp, 201)
      assert share["source"] == "stored"
      assert Enum.sort(share["surfaces"]) == ["docs", "papers"]

      assert Sharing.shared?("gyldendal", "books", "production", :papers)
      assert Sharing.shared?("gyldendal", "books", "production", :docs)
    end

    test "defaults access to read and scope project/dataset", %{conn: conn} do
      resp = conn |> admin_conn() |> post("/v1/shares", %{scope: "gyldendal", surfaces: "papers"})
      assert resp.status == 201

      assert Sharing.access_for("gyldendal", "default", "production") == :read
    end

    test "edit access is honored", %{conn: conn} do
      body = %{scope: "g/p/production", surfaces: "media", access: "edit"}
      assert (conn |> admin_conn() |> post("/v1/shares", body)).status == 201
      assert Sharing.access_for("g", "p", "production") == :edit
    end

    test "422 on a wildcard scope, no share created", %{conn: conn} do
      resp =
        conn |> admin_conn() |> post("/v1/shares", %{scope: "*/p/production", surfaces: "papers"})

      assert resp.status == 422
      refute Sharing.shared?("*", "p", "production", :papers)
    end

    test "422 when surfaces are all unknown", %{conn: conn} do
      resp =
        conn |> admin_conn() |> post("/v1/shares", %{scope: "g/p/production", surfaces: "wat"})

      assert resp.status == 422
    end

    test "422 when scope is missing", %{conn: conn} do
      resp = conn |> admin_conn() |> post("/v1/shares", %{surfaces: "papers"})
      assert resp.status == 422
    end
  end

  # ── rm (DELETE) ─────────────────────────────────────────────────────────

  describe "DELETE /v1/shares" do
    test "removes a stored share and refreshes the live list", %{conn: conn} do
      assert {:ok, _} = Sharing.add_share("gyldendal/books/production:papers:read")
      assert Sharing.shared?("gyldendal", "books", "production", :papers)

      resp = conn |> admin_conn() |> delete("/v1/shares", %{scope: "gyldendal/books/production"})
      assert resp.status == 200
      assert %{"removed" => 1} = json_response(resp, 200)

      refute Sharing.shared?("gyldendal", "books", "production", :papers)
    end

    test "removing an absent scope returns removed: 0", %{conn: conn} do
      resp = conn |> admin_conn() |> delete("/v1/shares", %{scope: "nobody/here/production"})
      assert %{"removed" => 0} = json_response(resp, 200)
    end
  end

  # ── ls (GET) ────────────────────────────────────────────────────────────

  describe "GET /v1/shares" do
    test "reports env baseline + stored, each tagged by source", %{conn: conn} do
      Application.put_env(:barkpark, :shares_env, Sharing.parse("env-ws:papers:read"))
      assert {:ok, _} = Sharing.add_share("db-ws/default/production:docs:edit")

      body = conn |> admin_conn() |> get("/v1/shares") |> json_response(200)

      assert body["active"] == true
      sources = body["shares"] |> Enum.group_by(& &1["source"])
      assert [%{"workspace" => "env-ws"}] = sources["env"]
      assert [%{"workspace" => "db-ws", "access" => "edit"}] = sources["stored"]
    end

    test "empty when nothing is shared (default-off)", %{conn: conn} do
      body = conn |> admin_conn() |> get("/v1/shares") |> json_response(200)
      assert body == %{"shares" => [], "active" => false}
    end
  end

  # ── share-edit token object-authz confinement (SA-S2) ────────────────────
  #
  # `/v1/shares/tokens*` run `[:api, :require_admin]`, which gates ONLY on the
  # `admin` permission with ZERO workspace binding. A workspace-bound admin
  # token therefore reaches revoke_token / mint_token / list_tokens with a
  # client-supplied id or scope. The controller confines each action to the
  # actor's `api_token.workspace_id`; a nil-workspace host/platform admin is
  # unconfined. `Auth.revoke_token/1` (a shared primitive) is UNCHANGED.
  describe "share-edit token object-authz confinement" do
    setup %{conn: conn} do
      ws_a = create_workspace!()
      proj_a = create_project!(ws_a)
      ws_b = create_workspace!()
      proj_b = create_project!(ws_b)

      scope_a = "#{ws_a.slug}/#{proj_a.slug}/production"
      scope_b = "#{ws_b.slug}/#{proj_b.slug}/production"

      {:ok, _} = Sharing.add_share("#{scope_a}:docs:edit")
      {:ok, _} = Sharing.add_share("#{scope_b}:docs:edit")

      # Workspace-BOUND admin tokens (create_token's 5th arg binds + memberships).
      {:ok, _} = Auth.create_token("sa-admin-a", "admin-a", "test", ["read", "admin"], ws_a.id)
      {:ok, _} = Auth.create_token("sa-admin-b", "admin-b", "test", ["read", "admin"], ws_b.id)

      # nil-workspace HOST admin — direct insert (create_token would fall back to
      # the Default Workspace); this is the unconfined platform-admin arm.
      {:ok, _host} =
        %ApiToken{}
        |> ApiToken.changeset(%{
          token_hash: ApiToken.hash_token("sa-host-admin"),
          label: "host-admin",
          dataset: "test",
          permissions: ["admin"],
          workspace_id: nil
        })
        |> Repo.insert()

      # A live share-edit token in EACH workspace (carries id + workspace_id).
      {:ok, {raw_a, token_a}} =
        Auth.create_share_token(ws_a.slug, proj_a.slug, "production", ["docs"])

      {:ok, {raw_b, token_b}} =
        Auth.create_share_token(ws_b.slug, proj_b.slug, "production", ["docs"])

      %{
        conn: conn,
        ws_a: ws_a,
        ws_b: ws_b,
        scope_a: scope_a,
        scope_b: scope_b,
        token_a: token_a,
        token_b: token_b,
        raw_a: raw_a,
        raw_b: raw_b
      }
    end

    defp bearer(conn, raw) do
      conn
      |> put_req_header("authorization", "Bearer " <> raw)
      |> put_req_header("content-type", "application/json")
    end

    test "revoke_token: a ws-A admin canNOT revoke a ws-B share token (404, stays live)", %{
      conn: conn,
      token_b: token_b,
      raw_b: raw_b
    } do
      resp = conn |> bearer("sa-admin-a") |> delete("/v1/shares/tokens/#{token_b.id}")

      assert json_response(resp, 404)["error"]["code"] == "not_found"
      # The foreign token is untouched — still resolves, revoked_at still nil.
      assert Repo.get(ApiToken, token_b.id).revoked_at == nil
      assert {:ok, _} = Auth.verify_token(raw_b)
    end

    test "revoke_token: a same-workspace admin revoke still succeeds", %{
      conn: conn,
      token_b: token_b,
      raw_b: raw_b
    } do
      resp = conn |> bearer("sa-admin-b") |> delete("/v1/shares/tokens/#{token_b.id}")

      assert %{"revoked" => true, "token_id" => id} = json_response(resp, 200)
      assert id == token_b.id
      assert Repo.get(ApiToken, token_b.id).revoked_at != nil
      assert {:error, :unauthorized} = Auth.verify_token(raw_b)
    end

    test "list_tokens: a ws-A admin sees only its own workspace share tokens", %{
      conn: conn,
      token_a: token_a,
      token_b: token_b
    } do
      body = conn |> bearer("sa-admin-a") |> get("/v1/shares/tokens") |> json_response(200)
      ids = Enum.map(body["tokens"], & &1["id"])

      assert token_a.id in ids
      refute token_b.id in ids
    end

    test "mint_token: a ws-A admin canNOT mint against a ws-B scope (404)", %{
      conn: conn,
      scope_b: scope_b
    } do
      resp =
        conn
        |> bearer("sa-admin-a")
        |> post("/v1/shares/tokens", %{scope: scope_b, surfaces: "docs"})

      assert json_response(resp, 404)["error"]["code"] == "not_found"
    end

    test "mint_token: a same-workspace mint still succeeds", %{conn: conn, scope_a: scope_a} do
      resp =
        conn
        |> bearer("sa-admin-a")
        |> post("/v1/shares/tokens", %{scope: scope_a, surfaces: "docs"})

      assert %{"token" => raw, "share_token" => st} = json_response(resp, 201)
      assert String.starts_with?(raw, "bpshare_")
      assert st["scope"] == scope_a
    end

    test "host admin (nil workspace) still reaches revoke/list/mint across any workspace", %{
      conn: conn,
      token_a: token_a,
      token_b: token_b,
      scope_a: scope_a,
      scope_b: scope_b
    } do
      # list — sees BOTH workspaces' tokens
      body = conn |> bearer("sa-host-admin") |> get("/v1/shares/tokens") |> json_response(200)
      ids = Enum.map(body["tokens"], & &1["id"])
      assert token_a.id in ids
      assert token_b.id in ids

      # mint — against either workspace's scope
      assert (conn
              |> bearer("sa-host-admin")
              |> post("/v1/shares/tokens", %{scope: scope_a, surfaces: "docs"})).status == 201

      assert (conn
              |> bearer("sa-host-admin")
              |> post("/v1/shares/tokens", %{scope: scope_b, surfaces: "docs"})).status == 201

      # revoke — a foreign (ws-B) token, allowed for the host admin
      resp = conn |> bearer("sa-host-admin") |> delete("/v1/shares/tokens/#{token_b.id}")
      assert %{"revoked" => true} = json_response(resp, 200)
      assert Repo.get(ApiToken, token_b.id).revoked_at != nil
    end
  end
end
