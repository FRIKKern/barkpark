defmodule BarkparkWeb.AccessControllerTest do
  @moduledoc """
  JSON API for the `access` noun (airdrop grants), proved NON-VACUOUSLY:

    * `POST /v1/access` mints (grantor), returns the raw token ONCE, and NEVER
      leaks `link_token_hash`; the no-escalation gate still 403s a token that
      lacks the conferred capability, and the RULING that a grant confers READ
      or WRITE only is enforced at the edge (`["admin"]` → 422, and no row).
    * `GET /v1/access` is grantor/workspace-scoped — one workspace's grants
      never bleed into another's; no `link_token_hash` in output.
    * `GET /v1/access/:id` is grantor-or-admin; a stranger — who can see no
      workspace at all — gets the missing-grant 404, never a 403 confirming the
      id is real; a non-UUID is a clean 404 (never a 500).
    * `DELETE /v1/access/:id` revokes, is idempotent, and gives a stranger the
      same missing-grant 404.
    * `POST /v1/access/claim` funnels every failure (wrong account / nonexistent
      / expired / used) through ONE byte-identical JSON error; success binds
      `grantee_user_id`.
    * the claim decision runs through the SHARED `Access.ClaimFlow` — the SAME
      module the browser `GrantController` uses (one no-oracle contract).
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.AccountsFixtures
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
      # `["read", "write"]`, not `["read"]` (task-a85afbbc0c4b1be3). `POST
      # /v1/access` rides `:require_token`, which now carries
      # `Plugs.RequireWriteForMutation` — a read-only token WRITING a grant row
      # was the defect that row closed, so a read-only grantor here would be
      # asserting the hole. `write` is what a real grantor holds; `read` is kept
      # alongside it because the read ladder is `~w(read admin public-read)` and
      # the grant below confers `read`.
      {grantor_raw, _} = token_principal(ws, ["read", "write"])

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

    # The no-escalation gate lives INSIDE `Access.mint/2` and must keep speaking
    # over HTTP. It USED to be probed with a write-capable grantor asking for
    # `admin` (task-a85afbbc0c4b1be3) — that shape now answers 422 at the edge
    # (see the admin tests below), so it can no longer reach the gate. The probe
    # moved INSIDE the narrowed vocabulary: a WRITE-only token clears
    # `Plugs.RequireWriteForMutation` (so `Access.mint/2` really runs) and is
    # then refused for conferring `read`, which `@read_perms ~w(read admin
    # public-read)` does not give it.
    test "no-escalation: a write-only token cannot mint a read grant → 403", %{conn: conn} do
      ws = create_workspace!()
      {grantor_raw, _} = token_principal(ws, ["write"])

      conn =
        conn
        |> bearer(grantor_raw)
        |> post("/v1/access", %{
          "grantee_email" => "grantee@example.com",
          "workspace_id" => ws.id,
          "capabilities" => ["read"]
        })

      assert json_response(conn, 403)["error"]["message"] =~
               "capabilities you do not hold"
    end

    # ── the RULING: grants confer read/write only ────────────────────────────
    #
    # `admin` is a third spelling of tenant-control authority beside the
    # membership role and the token permission bit. The Studio picker only ever
    # surfaced read/write (`@surfaced_caps`); the server now matches it, at the
    # edge, BEFORE `Access.mint/2`. The grantor below holds `admin` and would
    # have sailed through the no-escalation gate — this is a REFUSAL OF THE
    # VOCABULARY, not of the grantor, which is why the negative store readback
    # matters.
    test "capabilities [\"admin\"] → 422 and NO grant row is written", %{conn: conn} do
      ws = create_workspace!()
      {grantor_raw, _} = token_principal(ws, ["read", "write", "admin"])
      email = "admin-cap-#{Ecto.UUID.generate()}@example.com"

      conn =
        conn
        |> bearer(grantor_raw)
        |> post("/v1/access", %{
          "grantee_email" => email,
          "workspace_id" => ws.id,
          "capabilities" => ["admin"]
        })

      body = json_response(conn, 422)
      assert body["error"]["code"] == "unprocessable"
      assert body["error"]["message"] =~ "read or write"

      # Read the STORE back: the refusal happened before `Access.mint/2`, so
      # this workspace (fresh, so no whole-table count) holds nothing.
      assert Access.list_grants_for_workspace(ws.id) == []
    end

    test "a mixed [\"read\", \"admin\"] mint is refused whole → 422, no row", %{conn: conn} do
      ws = create_workspace!()
      {grantor_raw, _} = token_principal(ws, ["read", "write", "admin"])

      conn =
        conn
        |> bearer(grantor_raw)
        |> post("/v1/access", %{
          "grantee_email" => "mixed-#{Ecto.UUID.generate()}@example.com",
          "workspace_id" => ws.id,
          "capabilities" => ["read", "admin"]
        })

      assert json_response(conn, 422)["error"]["code"] == "unprocessable"
      assert Access.list_grants_for_workspace(ws.id) == []
    end

    # POSITIVE CONTROLS — the refusal is narrow. Without these the 422 above
    # would be green even if the endpoint refused everything.
    test "positive control: [\"read\"] still mints → 201", %{conn: conn} do
      ws = create_workspace!()
      {grantor_raw, _} = token_principal(ws, ["read", "write"])

      conn =
        conn
        |> bearer(grantor_raw)
        |> post("/v1/access", %{
          "grantee_email" => "read-#{Ecto.UUID.generate()}@example.com",
          "workspace_id" => ws.id,
          "capabilities" => ["read"]
        })

      assert %{"grant" => grant} = json_response(conn, 201)
      assert grant["capabilities"] == ["read"]
      assert [%Access.Grant{}] = Access.list_grants_for_workspace(ws.id)
    end

    test "positive control: [\"read\", \"write\"] still mints → 201", %{conn: conn} do
      ws = create_workspace!()
      {grantor_raw, _} = token_principal(ws, ["read", "write"])

      conn =
        conn
        |> bearer(grantor_raw)
        |> post("/v1/access", %{
          "grantee_email" => "rw-#{Ecto.UUID.generate()}@example.com",
          "workspace_id" => ws.id,
          "capabilities" => ["read", "write"]
        })

      assert %{"grant" => grant} = json_response(conn, 201)
      assert grant["capabilities"] == ["read", "write"]
      assert [%Access.Grant{}] = Access.list_grants_for_workspace(ws.id)
    end

    # The upstream half of the same refusal, kept separate so the two reasons
    # never collapse into one assertion: a read-only token never reaches
    # `Access.mint/2` at all.
    test "a read-only token is refused by the pipeline write gate → 403", %{conn: conn} do
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

    # A stranger is a member of NO workspace, so it cannot see this grant's
    # workspace at all — it gets the missing-grant answer, not a 403 that would
    # confirm the id is real. The in-tenant 403 is pinned separately in
    # `access_controller_oracle_crash_test.exs`.
    test "a stranger (non-grantor, non-admin) gets the missing-grant 404", %{conn: conn} do
      ws = create_workspace!()
      {grant, _} = mint_grant(ws, "g@example.com")
      stranger = stranger_token()

      conn = conn |> bearer(stranger) |> get("/v1/access/#{grant.id}")
      assert json_response(conn, 404)["error"]["code"] == "not_found"
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

      second = scoped_conn() |> bearer(admin_raw) |> delete("/v1/access/#{grant.id}")
      assert json_response(second, 200)["grant"]["id"] == grant.id
    end

    # Same denial-shape reason as `show`: a stranger must not learn the id is real.
    test "a stranger cannot revoke → the missing-grant 404", %{conn: conn} do
      ws = create_workspace!()
      {grant, _} = mint_grant(ws, "g@example.com")
      stranger = stranger_token()

      conn = conn |> bearer(stranger) |> delete("/v1/access/#{grant.id}")
      assert json_response(conn, 404)["error"]["code"] == "not_found"
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
        scoped_conn()
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
        scoped_conn()
        |> bearer(user_bearer(user))
        |> post("/v1/access/claim", %{"token" => expired_raw})

      assert expired.status == reference.status
      assert expired.resp_body == reference.resp_body

      # First claim of the single-use grant succeeds…
      ok =
        scoped_conn()
        |> bearer(user_bearer(user))
        |> post("/v1/access/claim", %{"token" => single_raw})

      assert json_response(ok, 200)

      # …the second is the identical no-oracle failure.
      spent =
        scoped_conn()
        |> bearer(user_bearer(user))
        |> post("/v1/access/claim", %{"token" => single_raw})

      assert spent.status == reference.status
      assert spent.resp_body == reference.resp_body
    end

    test "an UNCONFIRMED grantee cannot claim — byte-identical to a nonexistent token", %{
      conn: conn
    } do
      ws = create_workspace!()
      # Self-serve account with the grantee's exact email but NO mailbox proof.
      user =
        register_unconfirmed_user("unconfirmed-#{System.unique_integer([:positive])}@example.com")

      {grant, raw} = mint_grant(ws, user.email)

      failing =
        conn |> bearer(user_bearer(user)) |> post("/v1/access/claim", %{"token" => raw})

      reference =
        scoped_conn()
        |> bearer(user_bearer(user))
        |> post("/v1/access/claim", %{"token" => "this-token-never-existed"})

      # Same status + same body — the confirmed gate leaks neither grant
      # existence nor account state.
      assert failing.status == reference.status
      assert failing.resp_body == reference.resp_body

      # And the grant was NOT bound.
      assert is_nil(Access.get_grant(grant.id).grantee_user_id)
    end

    # Positive control: a CONFIRMED grantee (same email) DOES claim — proving the
    # gate blocks only unconfirmed accounts, not every claim (no over-deny).
    test "a CONFIRMED grantee with the same email claims successfully (no over-deny)", %{
      conn: conn
    } do
      ws = create_workspace!()
      email = "confirmed-#{System.unique_integer([:positive])}@example.com"
      unconfirmed = register_unconfirmed_user(email)
      confirmed = Repo.update!(Accounts.User.confirm_changeset(unconfirmed))
      {grant, raw} = mint_grant(ws, email)

      conn =
        conn |> bearer(user_bearer(confirmed)) |> post("/v1/access/claim", %{"token" => raw})

      assert %{"grant" => body} = json_response(conn, 200)
      assert body["grantee_user_id"] == confirmed.id
      assert Access.get_grant(grant.id).grantee_user_id == confirmed.id
    end

    # IdP-trust exception (documented, accepted): SSO / SCIM / social provisioning
    # stamp `confirmed_at` via the SAME `User.confirm_changeset` — WITHOUT any
    # email round-trip (sso/oidc.ex, sso/social.ex, scim.ex all do exactly this).
    # The gate is a PLAIN `confirmed_at` check, so an IdP-provisioned account
    # satisfies it and claims. Proven a PASS so the gate is not accidentally
    # tightened to a stricter "mailbox-token-consumed" rule that would reject
    # legitimate IdP users.
    test "an SSO/SCIM-provisioned account (confirmed WITHOUT a mailbox token) claims", %{
      conn: conn
    } do
      ws = create_workspace!()
      email = "idp-#{System.unique_integer([:positive])}@example.com"
      # Provisioned like the IdP paths: registered, then confirmed with no email
      # round-trip — the identical Repo.update!(User.confirm_changeset/1) call.
      {:ok, provisioned} = Accounts.register_user(%{email: email, password: @password})
      idp_user = Repo.update!(Accounts.User.confirm_changeset(provisioned))
      {grant, raw} = mint_grant(ws, email)

      conn =
        conn |> bearer(user_bearer(idp_user)) |> post("/v1/access/claim", %{"token" => raw})

      assert %{"grant" => body} = json_response(conn, 200)
      assert body["grantee_user_id"] == idp_user.id
      assert Access.get_grant(grant.id).grantee_user_id == idp_user.id
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

      # And an UNCONFIRMED grantee — even with a matching email + active grant —
      # collapses to the SAME :invalid (the confirmed-account gate, finding #2).
      unconfirmed =
        register_unconfirmed_user("uc-#{System.unique_integer([:positive])}@example.com")

      {_g, uc_raw} = mint_grant(ws, unconfirmed.email)
      assert ClaimFlow.resolve(uc_raw, unconfirmed) == :invalid

      # JSON surface renders that :invalid as the uniform 422.
      json =
        conn |> bearer(user_bearer(intruder)) |> post("/v1/access/claim", %{"token" => real_raw})

      assert json.status == 422

      # Browser surface renders the SAME :invalid as the invalid_grant redirect
      # (proving GrantController funnels through the same module, not a fork).
      {:ok, session_raw} =
        Accounts.create_user_session_token(intruder, ip_address: "127.0.0.1", user_agent: "test")

      browser =
        scoped_conn()
        |> init_test_session(%{"user_session" => session_raw})
        |> get("/grant/#{real_raw}")

      assert redirected_to(browser) == "/studio"
    end
  end

  # ── 8. malformed workspace_id → 403, never a crash (CONTRACT PIN) ───────────

  # Pins the observable HTTP contract the `Barkpark.Tenancy.Auth.membership/2`
  # totality seam (#12616) produces on the two access-GRANT verbs that take a
  # client-supplied `workspace_id` in a NON-id position: `index/2` and `mint/2`.
  #
  # BEFORE the seam these two answered HTTP 400 `Ecto.Query.CastError` — NOT a
  # 500. `deps/phoenix_ecto/lib/phoenix_ecto/plug.ex` maps
  # `{Ecto.Query.CastError, 400}`; 500 is Plug's `Any` fallback and covers the
  # nil / non-binary `FunctionClauseError` class, which is UNREACHABLE here
  # because both entry guards (`fetch_workspace_id/1` and
  # `Access.authorize_capabilities/3`) already require `is_binary`. The
  # exception module is `Ecto.Query.CastError`, never `Ecto.CastError` — the
  # latter fires zero times on this path, so asserting it would be vacuous.
  #
  # AFTER the seam all three answer 403 `forbidden`, indistinguishable from a
  # well-formed-but-unauthorized id. That collapse is the point: splitting
  # "malformed" from "not yours" would re-open the existence oracle the `:id`
  # ladder in this controller's moduledoc closes.
  #
  # Each row is its own test so each reds INDIVIDUALLY under the pre-seam
  # mutation, and the three control rows below stay green in both worlds.
  describe "malformed workspace_id on the grant surface (403, not a crash)" do
    # CHANGED ROW 1. `index/2` never resolves the workspace — it hands the raw
    # param straight to `Auth.authorize/3`, so a short non-UUID reached the
    # `:binary_id` comparison inside `Repo.one`. This is the crash the existing
    # `show/:id` non-UUID coverage in this file did NOT reach, which is exactly
    # why it survived.
    test "GET /v1/access?workspace_id=zzz → 403 for a non-member read token", %{conn: conn} do
      raw = unaffiliated_token(["read"])

      conn = conn |> bearer(raw) |> get("/v1/access", %{"workspace_id" => "zzz"})

      assert json_response(conn, 403)["error"]["code"] == "forbidden"
    end

    # CHANGED ROW 2. The 16-byte row, and it is NOT the same mechanism as row 1.
    # `Ecto.UUID.cast/1` accepts ANY 16-byte binary as raw UUID bytes, so the
    # seam NORMALISES this one into a well-formed uuid that REACHES the query
    # and denies by matching no row — it does not short-circuit. Pre-seam it
    # raised anyway, because `Ecto.UUID.dump/1` (what a query param binding
    # runs) accepts ONLY the 36-character form.
    test "GET /v1/access?workspace_id=<16-byte non-UUID> → 403", %{conn: conn} do
      raw = unaffiliated_token(["read"])

      conn = conn |> bearer(raw) |> get("/v1/access", %{"workspace_id" => "0123456789abcdef"})

      assert json_response(conn, 403)["error"]["code"] == "forbidden"
    end

    # CHANGED ROW 3. The MINT half — the credential-MINTING surface, which is
    # why this class mattered enough to pin. The crash sat in
    # `Access.authorize_capabilities/3`, i.e. BEFORE `Grant.changeset/2` ever
    # ran, so no changeset validation could have caught it.
    #
    # The token holds `["write"]`, not `["read"]`: `POST /v1/access` rides
    # `:require_token`, which carries `Plugs.RequireWriteForMutation`, so a
    # read-only token is refused by the PIPELINE and never reaches
    # `Access.mint/2` at all — a 403 that would be green in both worlds and
    # prove nothing. `["write"]` is the weakest principal that actually reaches
    # the seam. It is still NON-ADMIN and a member of NO workspace.
    test "POST /v1/access with workspace_id=zzz and a non-empty capabilities list → 403",
         %{conn: conn} do
      raw = unaffiliated_token(["write"])

      conn =
        conn
        |> bearer(raw)
        |> post("/v1/access", %{
          "workspace_id" => "zzz",
          "capabilities" => ["read"],
          "grantee_email" => "x@example.com"
        })

      assert json_response(conn, 403)["error"]["code"] == "forbidden"
    end

    # CONTROL 1 (UNCHANGED by the seam). An EMPTY workspace_id is caught by
    # `fetch_workspace_id/1`'s own `id != ""` guard, upstream of any query, so
    # it answers 422 in both worlds. A run where this row also reds is a run
    # where the mutation broke something wider than the seam.
    test "CONTROL: GET /v1/access?workspace_id= (empty) → 422, never 403", %{conn: conn} do
      raw = unaffiliated_token(["read"])

      conn = conn |> bearer(raw) |> get("/v1/access", %{"workspace_id" => ""})

      assert json_response(conn, 422)["error"]["code"] == "unprocessable"
    end

    # CONTROL 2 (UNCHANGED by the seam). An EMPTY capabilities list falls to
    # `Access.authorize_capabilities/3`'s own arity catch-all — the guarded head
    # requires `caps != []` — so it denies WITHOUT ever binding the malformed
    # workspace_id into a query. The crash required a NON-EMPTY list; this row
    # proves the pre-seam reds in this describe come from the seam and not from
    # merely mentioning "zzz".
    test "CONTROL: POST /v1/access with workspace_id=zzz and capabilities=[] → 403", %{conn: conn} do
      raw = unaffiliated_token(["write"])

      conn =
        conn
        |> bearer(raw)
        |> post("/v1/access", %{
          "workspace_id" => "zzz",
          "capabilities" => [],
          "grantee_email" => "x@example.com"
        })

      assert json_response(conn, 403)["error"]["code"] == "forbidden"
    end

    # CONTROL 3 (UNCHANGED by the seam). A WELL-FORMED workspace id the caller
    # is not a member of. This is the answer the three changed rows above are
    # now indistinguishable from — the whole point of choosing 403 over a 422
    # "malformed" body.
    test "CONTROL: GET /v1/access?workspace_id=<valid uuid, non-member> → 403", %{conn: conn} do
      ws = create_workspace!()
      raw = unaffiliated_token(["read"])

      conn = conn |> bearer(raw) |> get("/v1/access", %{"workspace_id" => ws.id})

      assert json_response(conn, 403)["error"]["code"] == "forbidden"
    end
  end

  # A bearer token with the given permissions and NO membership row ANYWHERE —
  # the weakest principal that can present a valid bearer. Deliberately NOT
  # `Barkpark.Auth.create_token/5`, which falls back to `default_workspace_id()`
  # and would CREATE a membership; this inserts the row directly so "member of
  # no workspace" is true by construction. Label is unique: the test database is
  # shared across concurrent agents.
  defp unaffiliated_token(permissions) do
    raw = "u-" <> Ecto.UUID.generate()

    {:ok, _token} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token(raw),
        label: "unaffiliated-#{System.unique_integer([:positive])}",
        dataset: "test",
        permissions: permissions
      })
      |> Repo.insert()

    raw
  end
end
