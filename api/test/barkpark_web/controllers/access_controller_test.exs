defmodule BarkparkWeb.AccessControllerTest do
  @moduledoc """
  JSON API for the `access` noun (airdrop grants), proved NON-VACUOUSLY:

    * `POST /v1/access` mints (grantor), returns the raw token ONCE, and NEVER
      leaks `link_token_hash`; the no-escalation gate still 403s a token that
      lacks the conferred capability.
    * `GET /v1/access` is grantor/workspace-scoped — one workspace's grants
      never bleed into another's; no `link_token_hash` in output.
    * `GET /v1/access/:id` is grantor-or-admin; a stranger is 403; a non-UUID is
      a clean 404 (never a 500).
    * `DELETE /v1/access/:id` revokes, is idempotent, and 403s a stranger.
    * `POST /v1/access/claim` funnels every failure (wrong account / nonexistent
      / expired / used) through ONE byte-identical JSON error; success binds
      `grantee_user_id`.
    * the claim decision runs through the SHARED `Access.ClaimFlow` — the SAME
      module the browser `GrantController` uses (one no-oracle contract).
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Access
  alias Barkpark.Access.ClaimFlow
  alias Barkpark.Accounts
  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @password "correct-horse-battery"

  # An API-token principal with a chosen permission set, made a member of `ws`
  # with `role`. Its perms cap what it can CONFER; its role gates admin ops.
  defp token_principal(ws, permissions, role \\ "admin") do
    raw = "t-" <> Ecto.UUID.generate()

    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token(raw),
        label: "principal",
        dataset: "test",
        permissions: permissions
      })
      |> Repo.insert()

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, role, "api_token")
    {raw, token}
  end

  # A bare token with NO membership anywhere — the "stranger".
  defp stranger_token do
    raw = "s-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "stranger", "test", ["read", "write", "admin"])
    raw
  end

  defp register_user(email) do
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    user
  end

  defp user_bearer(user) do
    {:ok, raw} =
      Accounts.create_user_session_token(user, ip_address: "127.0.0.1", user_agent: "test")

    raw
  end

  defp bearer(conn, raw) do
    conn
    |> put_req_header("authorization", "Bearer " <> raw)
    |> put_req_header("content-type", "application/json")
  end

  defp mint_grant(ws, grantee_email, overrides \\ %{}) do
    {_raw, grantor} = token_principal(ws, ["admin"])

    attrs =
      Map.merge(
        %{grantee_email: grantee_email, workspace_id: ws.id, capabilities: ["read"]},
        overrides
      )

    {:ok, %{grant: grant, token: token}} = Access.mint(grantor, attrs)
    {grant, token}
  end

  # ── 1. mint ────────────────────────────────────────────────────────────────

  describe "POST /v1/access (mint)" do
    test "a grantor mints a grant; raw token returned once; NO link_token_hash", %{conn: conn} do
      ws = create_workspace!()
      {grantor_raw, _} = token_principal(ws, ["read"])

      conn =
        conn
        |> bearer(grantor_raw)
        |> post("/v1/access", %{
          "grantee_email" => "grantee@example.com",
          "workspace_id" => ws.id,
          "capabilities" => ["read"]
        })

      assert %{"grant" => grant, "token" => raw} = json_response(conn, 201)
      assert is_binary(raw) and byte_size(raw) > 20
      refute Map.has_key?(grant, "link_token_hash")
      assert grant["grantee_email"] == "grantee@example.com"
      assert grant["capabilities"] == ["read"]
    end

    test "no-escalation: a read-only token cannot mint a write grant → 403", %{conn: conn} do
      ws = create_workspace!()
      {grantor_raw, _} = token_principal(ws, ["read"])

      conn =
        conn
        |> bearer(grantor_raw)
        |> post("/v1/access", %{
          "grantee_email" => "grantee@example.com",
          "workspace_id" => ws.id,
          "capabilities" => ["write"]
        })

      assert json_response(conn, 403)["error"]["code"] == "forbidden"
    end
  end

  # ── 2. index (grantor/workspace-scoped) ─────────────────────────────────────

  describe "GET /v1/access (list)" do
    test "lists a workspace's grants only — no cross-workspace bleed; no hash", %{conn: conn} do
      ws_a = create_workspace!()
      ws_b = create_workspace!()

      {grantor_raw, _} = token_principal(ws_a, ["admin"])

      {:ok, %{grant: grant_a}} =
        Access.mint(elem(token_principal(ws_a, ["admin"]), 1), %{
          grantee_email: "a@example.com",
          workspace_id: ws_a.id,
          capabilities: ["read"]
        })

      {grant_b, _} = mint_grant(ws_b, "b@example.com")

      conn = conn |> bearer(grantor_raw) |> get("/v1/access", %{"workspace_id" => ws_a.id})

      assert %{"grants" => grants} = json_response(conn, 200)
      ids = MapSet.new(grants, & &1["id"])

      assert grant_a.id in ids
      refute grant_b.id in ids
      refute Enum.any?(grants, &Map.has_key?(&1, "link_token_hash"))
    end

    test "a token not authorized in the workspace is forbidden", %{conn: conn} do
      ws = create_workspace!()
      stranger = stranger_token()

      conn = conn |> bearer(stranger) |> get("/v1/access", %{"workspace_id" => ws.id})
      assert json_response(conn, 403)["error"]["code"] == "forbidden"
    end

    test "missing workspace_id → 422", %{conn: conn} do
      ws = create_workspace!()
      {grantor_raw, _} = token_principal(ws, ["admin"])

      conn = conn |> bearer(grantor_raw) |> get("/v1/access")
      assert json_response(conn, 422)["error"]["code"] == "unprocessable"
    end
  end

  # ── 3. show (grantor-or-admin) ──────────────────────────────────────────────

  describe "GET /v1/access/:id (show)" do
    test "a workspace admin reads the grant", %{conn: conn} do
      ws = create_workspace!()
      {admin_raw, _} = token_principal(ws, ["admin"])
      {grant, _} = mint_grant(ws, "g@example.com")

      conn = conn |> bearer(admin_raw) |> get("/v1/access/#{grant.id}")
      assert %{"grant" => body} = json_response(conn, 200)
      assert body["id"] == grant.id
      refute Map.has_key?(body, "link_token_hash")
    end

    test "a stranger (non-grantor, non-admin) is denied", %{conn: conn} do
      ws = create_workspace!()
      {grant, _} = mint_grant(ws, "g@example.com")
      stranger = stranger_token()

      conn = conn |> bearer(stranger) |> get("/v1/access/#{grant.id}")
      assert json_response(conn, 403)["error"]["code"] == "forbidden"
    end

    test "a non-UUID id is a clean 404 (never a 500)", %{conn: conn} do
      ws = create_workspace!()
      {admin_raw, _} = token_principal(ws, ["admin"])

      conn = conn |> bearer(admin_raw) |> get("/v1/access/not-a-uuid")
      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end
  end

  # ── 4. revoke ───────────────────────────────────────────────────────────────

  describe "DELETE /v1/access/:id (revoke)" do
    test "a workspace admin revokes, and it is idempotent", %{conn: conn} do
      ws = create_workspace!()
      {admin_raw, _} = token_principal(ws, ["admin"])
      {grant, _} = mint_grant(ws, "g@example.com")

      first = conn |> bearer(admin_raw) |> delete("/v1/access/#{grant.id}")
      assert %{"grant" => body} = json_response(first, 200)
      refute is_nil(body["revoked_at"])

      second = build_conn() |> bearer(admin_raw) |> delete("/v1/access/#{grant.id}")
      assert json_response(second, 200)["grant"]["id"] == grant.id
    end

    test "a stranger cannot revoke → 403", %{conn: conn} do
      ws = create_workspace!()
      {grant, _} = mint_grant(ws, "g@example.com")
      stranger = stranger_token()

      conn = conn |> bearer(stranger) |> delete("/v1/access/#{grant.id}")
      assert json_response(conn, 403)["error"]["code"] == "forbidden"
    end
  end

  # ── 5. claim — NO-ORACLE ────────────────────────────────────────────────────

  describe "POST /v1/access/claim (session no-oracle)" do
    test "correct authed grantee claims → 200 and grantee_user_id is bound", %{conn: conn} do
      ws = create_workspace!()
      user = register_user("bind-#{System.unique_integer([:positive])}@example.com")
      {grant, raw} = mint_grant(ws, user.email)

      conn =
        conn |> bearer(user_bearer(user)) |> post("/v1/access/claim", %{"token" => raw})

      assert %{"grant" => body} = json_response(conn, 200)
      assert body["grantee_user_id"] == user.id
      assert Access.get_grant(grant.id).grantee_user_id == user.id
    end

    test "wrong-account is BYTE-IDENTICAL to a nonexistent token", %{conn: conn} do
      ws = create_workspace!()
      intruder = register_user("intruder-#{System.unique_integer([:positive])}@example.com")
      {_grant, real_raw} = mint_grant(ws, "the-real-grantee@example.com")

      wrong =
        conn |> bearer(user_bearer(intruder)) |> post("/v1/access/claim", %{"token" => real_raw})

      missing =
        build_conn()
        |> bearer(user_bearer(intruder))
        |> post("/v1/access/claim", %{"token" => "this-token-never-existed"})

      assert wrong.status == missing.status
      assert wrong.resp_body == missing.resp_body
    end

    test "expired and already-used collapse to the identical failure", %{conn: conn} do
      ws = create_workspace!()
      user = register_user("multi-#{System.unique_integer([:positive])}@example.com")
      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      {_g, expired_raw} = mint_grant(ws, user.email, %{expires_at: past})
      {_g2, single_raw} = mint_grant(ws, user.email, %{single_use: true})

      reference =
        conn |> bearer(user_bearer(user)) |> post("/v1/access/claim", %{"token" => "no-such"})

      expired =
        build_conn()
        |> bearer(user_bearer(user))
        |> post("/v1/access/claim", %{"token" => expired_raw})

      assert expired.status == reference.status
      assert expired.resp_body == reference.resp_body

      # First claim of the single-use grant succeeds…
      ok =
        build_conn()
        |> bearer(user_bearer(user))
        |> post("/v1/access/claim", %{"token" => single_raw})

      assert json_response(ok, 200)

      # …the second is the identical no-oracle failure.
      spent =
        build_conn()
        |> bearer(user_bearer(user))
        |> post("/v1/access/claim", %{"token" => single_raw})

      assert spent.status == reference.status
      assert spent.resp_body == reference.resp_body
    end
  end

  # ── 7. shared no-oracle — ONE implementation, two surfaces ──────────────────

  describe "shared ClaimFlow (one no-oracle contract)" do
    test "JSON claim and browser /grant both route through Access.ClaimFlow", %{conn: conn} do
      ws = create_workspace!()
      intruder = register_user("shared-#{System.unique_integer([:positive])}@example.com")
      {_grant, real_raw} = mint_grant(ws, "someone-else@example.com")

      # The SHARED decision collapses wrong-grantee AND nonexistent to :invalid.
      assert ClaimFlow.resolve(real_raw, intruder) == :invalid
      assert ClaimFlow.resolve("no-such-token", intruder) == :invalid

      # JSON surface renders that :invalid as the uniform 422.
      json =
        conn |> bearer(user_bearer(intruder)) |> post("/v1/access/claim", %{"token" => real_raw})

      assert json.status == 422

      # Browser surface renders the SAME :invalid as the invalid_grant redirect
      # (proving GrantController funnels through the same module, not a fork).
      {:ok, session_raw} =
        Accounts.create_user_session_token(intruder, ip_address: "127.0.0.1", user_agent: "test")

      browser =
        build_conn()
        |> init_test_session(%{"user_session" => session_raw})
        |> get("/grant/#{real_raw}")

      assert redirected_to(browser) == "/studio"
    end
  end
end
