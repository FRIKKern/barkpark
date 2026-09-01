defmodule BarkparkWeb.AccessTokenIdentityTest do
  @moduledoc """
  ag-bp-user-identity-auth — an api_token with an `owner_user_id` carries a USER
  identity on the grantee surface, so a terminal `bp access claim`/`mine` works.
  Proved NON-VACUOUSLY:

    1. A NULL-owner token CANNOT claim (fail closed → 401, no grant bound).
    2. An OWNED token claims + binds `grantee_user_id`; a mismatched owner email
       still collapses to the no-oracle `invalid_grant`.
    3. Existing (NULL-owner) api_token auth on a GRANTOR route is BYTE-IDENTICAL.
    4. The self-mint can ONLY create a self-owned token — a body-supplied
       `owner_user_id` for another user is IGNORED (no escalation).
    5. An owned token acts ONLY as its bound owner: `access mine` returns ONLY
       that user's grants, never another user's.
    6. `access mine` never emits `link_token_hash`.

  task-d70c118c80c1d0df — the self-mint's WORKSPACE binding (a cross-tenant
  read escalation, one layer below #4's owner-identity binding):

    7. A caller with ZERO `Tenancy.Membership` rows self-mints a
       WORKSPACE-LESS token (no membership row is ever created for it — in
       particular none in the seeded Default Workspace) and that token is
       REFUSED reading Default-Workspace content on the membership-gated
       scoped route.
    8. A caller who IS a member of workspace W self-mints a token bound to W
       (never the Default Workspace) and reads W's content successfully.
    9. Permissions are DERIVED from the caller's REAL resolved workspace role
       (Option A), never a literal: owner/admin mint up to
       `["read", "write", "admin"]`, a member still gets `["read"]` only, and
       a non-member (no resolvable role) mints the member-tier `["read"]`
       workspace-less token from #7.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.AccountsFixtures
  import Barkpark.TenancyFixtures
  import Ecto.Query

  alias Barkpark.Access
  alias Barkpark.Accounts
  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Content
  alias Barkpark.Repo
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  defp uniq_email(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}@example.com"

  # An api_token OWNED by `user` (owner_user_id set). kind defaults to "api" so
  # verify_token resolves it exactly like any bearer.
  defp owned_token(user) do
    raw = "own-" <> Ecto.UUID.generate()

    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token(raw),
        label: "owned",
        dataset: "test",
        permissions: ["read"],
        owner_user_id: user.id
      })
      |> Repo.insert()

    {raw, token}
  end

  # A normal (NULL-owner) token — the pre-existing shape.
  defp unowned_token(permissions \\ ["read"]) do
    raw = "un-" <> Ecto.UUID.generate()

    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token(raw),
        label: "unowned",
        dataset: "test",
        permissions: permissions
      })
      |> Repo.insert()

    {raw, token}
  end

  # A grantor token that is a workspace admin (so it may mint grants).
  defp grantor(ws) do
    {_raw, token} = unowned_token(["admin"])
    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, "admin", "api_token")
    token
  end

  defp mint_grant(ws, grantee_email, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{grantee_email: grantee_email, workspace_id: ws.id, capabilities: ["read"]},
        overrides
      )

    {:ok, %{grant: grant, token: raw}} = Access.mint(grantor(ws), attrs)
    {grant, raw}
  end

  defp bearer(conn, raw) do
    conn
    |> put_req_header("authorization", "Bearer " <> raw)
    |> put_req_header("content-type", "application/json")
  end

  defp user_bearer(user) do
    {:ok, raw} =
      Accounts.create_user_session_token(user, ip_address: "127.0.0.1", user_agent: "test")

    raw
  end

  # Govern `user` under a NEW require_mfa org (user has no factor enrolled).
  defp govern_require_mfa!(user, org_slug) do
    {:ok, org} = Tenancy.create_organization(%{slug: org_slug, name: org_slug})
    {:ok, org} = Tenancy.set_organization_require_mfa(org.id, true)
    {:ok, ws} = Tenancy.create_workspace(%{slug: "#{org_slug}-ws", name: "#{org_slug}-ws"})
    {:ok, ws} = Tenancy.assign_workspace_to_organization(ws, org.id)
    {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, "member", "user")
    org
  end

  # Enrol a factor so Accounts.mfa_enrolled?/1 returns true (totp_enabled arm),
  # opening the org-MFA gate for this user.
  defp enroll_mfa!(user) do
    user |> Ecto.Changeset.change(%{totp_enabled: true}) |> Repo.update!()
  end

  # ── 1. NULL-owner token → CANNOT claim ──────────────────────────────────────

  describe "case 1 — a NULL-owner token cannot claim (fail closed)" do
    test "POST /v1/access/claim with an unowned token → 401, no grant bound", %{conn: conn} do
      ws = create_workspace!()
      user = register_user(uniq_email("noown"))
      {grant, raw} = mint_grant(ws, user.email)
      {tok_raw, _} = unowned_token()

      conn = conn |> bearer(tok_raw) |> post("/v1/access/claim", %{"token" => raw})

      assert conn.status == 401
      # No principal resolved → the grant stays unclaimed.
      assert is_nil(Access.get_grant(grant.id).grantee_user_id)
      assert is_nil(Access.get_grant(grant.id).claimed_at)
    end
  end

  # ── 2. OWNED token → claims + binds ─────────────────────────────────────────

  describe "case 2 — an owned token claims and binds to its owner" do
    test "owner email == grantee → claim succeeds, grantee_user_id + claimed_at bound",
         %{conn: conn} do
      ws = create_workspace!()
      user = register_user(uniq_email("owner"))
      {grant, raw} = mint_grant(ws, user.email)
      {tok_raw, _} = owned_token(user)

      conn = conn |> bearer(tok_raw) |> post("/v1/access/claim", %{"token" => raw})

      assert %{"grant" => body} = json_response(conn, 200)
      assert body["grantee_user_id"] == user.id

      reloaded = Access.get_grant(grant.id)
      assert reloaded.grantee_user_id == user.id
      refute is_nil(reloaded.claimed_at)
    end

    test "owner email != grantee → uniform invalid_grant (ClaimFlow email match holds)",
         %{conn: conn} do
      ws = create_workspace!()
      user = register_user(uniq_email("mismatch"))
      {grant, raw} = mint_grant(ws, "someone-else@example.com")
      {tok_raw, _} = owned_token(user)

      conn = conn |> bearer(tok_raw) |> post("/v1/access/claim", %{"token" => raw})

      assert json_response(conn, 422)["error"]["code"] == "invalid_grant"
      assert is_nil(Access.get_grant(grant.id).grantee_user_id)
    end
  end

  # ── 3. Existing token auth is BYTE-IDENTICAL ────────────────────────────────

  describe "case 3 — a NULL-owner token authenticates exactly as before" do
    test "verify_token resolves an unowned token unchanged", %{conn: _conn} do
      {raw, token} = unowned_token()
      assert {:ok, resolved} = Auth.verify_token(raw)
      assert resolved.id == token.id
      assert is_nil(resolved.owner_user_id)
    end

    test "a grantor route (GET /v1/access) behaves unchanged for a NULL-owner token",
         %{conn: conn} do
      ws = create_workspace!()
      {admin_raw, _} = unowned_token(["admin"])

      {:ok, _} =
        TenancyAuth.create_membership(ws.id, admin_token_id(admin_raw), "admin", "api_token")

      {grant, _} = mint_grant(ws, "g@example.com")

      conn = conn |> bearer(admin_raw) |> get("/v1/access", %{"workspace_id" => ws.id})

      assert %{"grants" => grants} = json_response(conn, 200)
      assert grant.id in Enum.map(grants, & &1["id"])
    end
  end

  defp admin_token_id(raw) do
    {:ok, token} = Auth.verify_token(raw)
    token.id
  end

  # ── 4. Self-mint can ONLY create a self-owned token ─────────────────────────

  describe "case 4 — the self-mint hard-binds owner to the session user" do
    test "POST /v1/auth/tokens ignores a body owner_user_id for another user", %{conn: conn} do
      user_a = register_user(uniq_email("mint-a"))
      user_b = register_user(uniq_email("mint-b"))

      conn =
        conn
        |> bearer(user_bearer(user_a))
        |> post("/v1/auth/tokens", %{
          "name" => "my token",
          # Escalation attempt — must be IGNORED.
          "owner_user_id" => user_b.id,
          "user_id" => user_b.id
        })

      assert %{"token" => raw, "personal_access_token" => pat} = json_response(conn, 201)
      assert is_binary(raw)
      # The wire echo AND the DB row both bind to A, never B.
      assert pat["owner_user_id"] == user_a.id
      refute pat["owner_user_id"] == user_b.id
      refute Map.has_key?(pat, "token_hash")

      {:ok, resolved} = Auth.verify_token(raw)
      assert resolved.owner_user_id == user_a.id

      # era-w8: minting a standing credential emits a token/personal_access_token_minted
      # audit event (subject = token id, actor = the session user).
      ev =
        Repo.one(
          from(e in Barkpark.Audit.Event,
            where: e.action == "personal_access_token_minted" and e.subject == ^pat["id"]
          )
        )

      assert ev.category == "token"
      assert ev.actor_id == user_a.id
    end
  end

  # ── 5. A token acts ONLY as its bound owner (mine) ──────────────────────────

  describe "case 5 — an owned token lists only its owner's grants" do
    test "GET /v1/access/mine returns U's grants, never V's", %{conn: conn} do
      ws = create_workspace!()
      user_u = register_user(uniq_email("u"))
      user_v = register_user(uniq_email("v"))

      # Bind one active grant to each user (claim binds grantee_user_id).
      {grant_u, raw_u} = mint_grant(ws, user_u.email)
      {:ok, _} = Access.claim(raw_u, user_u)
      {grant_v, raw_v} = mint_grant(ws, user_v.email)
      {:ok, _} = Access.claim(raw_v, user_v)

      {tok_raw, _} = owned_token(user_u)

      conn = conn |> bearer(tok_raw) |> get("/v1/access/mine")

      assert %{"grants" => grants} = json_response(conn, 200)
      ids = MapSet.new(grants, & &1["id"])
      assert grant_u.id in ids
      refute grant_v.id in ids
    end
  end

  # ── 6. mine field hygiene ───────────────────────────────────────────────────

  describe "case 6 — mine never emits link_token_hash" do
    test "GET /v1/access/mine output whitelists fields", %{conn: conn} do
      ws = create_workspace!()
      user = register_user(uniq_email("hygiene"))
      {_grant, raw} = mint_grant(ws, user.email)
      {:ok, _} = Access.claim(raw, user)
      {tok_raw, _} = owned_token(user)

      conn = conn |> bearer(tok_raw) |> get("/v1/access/mine")

      assert %{"grants" => grants} = json_response(conn, 200)
      assert grants != []
      refute Enum.any?(grants, &Map.has_key?(&1, "link_token_hash"))
    end
  end

  # ── 7. org-MFA overlay preserved on the SESSION claim path ───────────────────

  describe "case 7 — the org-MFA-enrolment overlay still gates the session path" do
    test "an unenrolled session-user in a require_mfa org is 403 on POST /v1/access/claim",
         %{conn: conn} do
      ws = create_workspace!()
      user = register_user(uniq_email("mfa-session"))
      _org = govern_require_mfa!(user, "claim-mfa-#{System.unique_integer([:positive])}")
      {_grant, raw} = mint_grant(ws, user.email)

      conn = conn |> bearer(user_bearer(user)) |> post("/v1/access/claim", %{"token" => raw})

      assert json_response(conn, 403)["error"]["code"] == "mfa_enrolment_required"
    end
  end

  # ── 8. token path safety — enrolment is gated at ISSUANCE ────────────────────

  describe "case 8 — an unenrolled require_mfa user cannot MINT an owned token" do
    test "POST /v1/auth/tokens is 403 mfa_enrolment_required (locks the issuance gate)",
         %{conn: conn} do
      user = register_user(uniq_email("mfa-mint"))
      _org = govern_require_mfa!(user, "mint-mfa-#{System.unique_integer([:positive])}")

      conn =
        conn
        |> bearer(user_bearer(user))
        |> post("/v1/auth/tokens", %{"name" => "blocked"})

      assert json_response(conn, 403)["error"]["code"] == "mfa_enrolment_required"
    end
  end

  # ── 9. positive control — the gate ALLOWS an ENROLLED require_mfa user ────────
  # The direct mirror of cases 7/8: the org-MFA gate must BLOCK the unenrolled
  # AND ALLOW the enrolled, both asserted directly (not via ungoverned proxies).

  describe "case 9 — an ENROLLED require_mfa user is allowed on both paths" do
    test "POST /v1/access/claim → 200 (grant binds) for an enrolled session-user",
         %{conn: conn} do
      ws = create_workspace!()
      user = register_user(uniq_email("mfa-ok-claim"))
      _org = govern_require_mfa!(user, "claim-ok-#{System.unique_integer([:positive])}")
      user = enroll_mfa!(user)
      {grant, raw} = mint_grant(ws, user.email)

      conn = conn |> bearer(user_bearer(user)) |> post("/v1/access/claim", %{"token" => raw})

      assert %{"grant" => body} = json_response(conn, 200)
      assert body["grantee_user_id"] == user.id
      assert Access.get_grant(grant.id).grantee_user_id == user.id
    end

    test "POST /v1/auth/tokens → 201 (mints an owned token) for an enrolled user",
         %{conn: conn} do
      user = register_user(uniq_email("mfa-ok-mint"))
      _org = govern_require_mfa!(user, "mint-ok-#{System.unique_integer([:positive])}")
      user = enroll_mfa!(user)

      conn =
        conn
        |> bearer(user_bearer(user))
        |> post("/v1/auth/tokens", %{"name" => "allowed"})

      assert %{"personal_access_token" => pat} = json_response(conn, 201)
      assert pat["owner_user_id"] == user.id
    end
  end

  # ── 10-12. task-d70c118c80c1d0df — self-mint WORKSPACE binding ─────────────
  #
  # The escalation one layer below case 4's owner-identity binding:
  # `AuthController.create_token/2` used to pass NO `:workspace_id`, so
  # `Auth.create_personal_access_token/3` fell back to the seeded Default
  # Workspace for EVERY caller and granted it a `Tenancy.Membership` with
  # zero relationship check. Fixed by resolving the caller's OWN membership
  # (workspace + role) instead, and minting workspace-less when it holds none.

  # Self-mint via the real HTTP route (the vulnerable surface), as the session
  # user. Returns {raw_token, personal_access_token_json}.
  defp self_mint(user, params \\ %{"name" => "cli"}) do
    conn =
      build_conn()
      |> bearer(user_bearer(user))
      |> post("/v1/auth/tokens", params)

    assert %{"token" => raw, "personal_access_token" => pat} = json_response(conn, 201)
    {raw, pat}
  end

  # A minimal public "post" schema in a fresh per-test dataset, so a scoped
  # query has a real row to (fail to) return — mirrors scoped_routing_test.exs.
  defp register_post_schema!(dataset) do
    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "post", "title" => "Post", "visibility" => "public", "fields" => []},
        dataset
      )

    :ok
  end

  defp unique_dataset(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  describe "case 10 — a caller with ZERO membership self-mints WORKSPACE-LESS" do
    test "no Default-Workspace membership is created, and the scoped route refuses the token" do
      {default_ws, default_project} = ensure_default_scope!()
      dataset = unique_dataset("pat-escalation")
      register_post_schema!(dataset)
      {:ok, _doc} = create_document_in!(default_ws, default_project, "post", %{}, dataset)

      user = register_user(uniq_email("zero-member"))
      {raw, pat} = self_mint(user)

      # The no-escalation guarantee from case 4 still holds.
      assert pat["owner_user_id"] == user.id
      # Option A: a non-member resolves no role, so the member-tier default.
      assert pat["permissions"] == ["read"]

      {:ok, minted} = Auth.verify_token(raw)
      # Workspace-less: no fallback to the Default Workspace, and — the actual
      # escalation vector — NO Tenancy.Membership row anywhere, in particular
      # none in the Default Workspace.
      assert is_nil(minted.workspace_id)
      refute TenancyAuth.member?(minted, default_ws.id)

      # The read-leak proof: the membership-gated scoped route (the same gate
      # `ResolveWorkspace`'s own moduledoc calls "the cross-dataset read-leak
      # fix") refuses this token against the Default Workspace's content —
      # where, on unpatched code (workspace_id defaulted to Default + a
      # Membership row inserted for it), this request answered 200.
      resp =
        build_conn()
        |> bearer(raw)
        |> get("/w/#{default_ws.slug}/p/#{default_project.slug}/v1/data/query/#{dataset}/post")

      assert resp.status == 403
      assert Jason.decode!(resp.resp_body)["error"]["code"] == "forbidden"
    end
  end

  describe "case 11 — a member of workspace W self-mints a token bound to W" do
    test "the token binds to W (never the Default Workspace) and reads W's content" do
      {default_ws, _default_project} = ensure_default_scope!()
      ws = create_workspace!()
      project = create_project!(ws)
      dataset = unique_dataset("pat-member-ws")
      register_post_schema!(dataset)
      {:ok, _doc} = create_document_in!(ws, project, "post", %{}, dataset)

      user = register_user(uniq_email("member-w"))
      {:ok, _membership} = TenancyAuth.create_membership(ws.id, user.id, "member", "user")

      {raw, pat} = self_mint(user)

      assert pat["owner_user_id"] == user.id
      assert pat["permissions"] == ["read"]

      {:ok, minted} = Auth.verify_token(raw)
      assert minted.workspace_id == ws.id
      refute minted.workspace_id == default_ws.id
      assert TenancyAuth.member?(minted, ws.id)

      resp =
        build_conn()
        |> bearer(raw)
        |> get("/w/#{ws.slug}/p/#{project.slug}/v1/data/query/#{dataset}/post")

      assert resp.status == 200
    end
  end

  describe "case 12 — permissions are DERIVED from the caller's real role (Option A)" do
    test "an owner self-mints up to [\"read\", \"write\", \"admin\"]" do
      ws = create_workspace!()
      user = register_user(uniq_email("owner-mint"))
      {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, "owner", "user")

      {_raw, pat} = self_mint(user)

      assert Enum.sort(pat["permissions"]) == ["admin", "read", "write"]
    end

    test "an admin self-mints up to [\"read\", \"write\", \"admin\"]" do
      ws = create_workspace!()
      user = register_user(uniq_email("admin-mint"))
      {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, "admin", "user")

      {_raw, pat} = self_mint(user)

      assert Enum.sort(pat["permissions"]) == ["admin", "read", "write"]
    end

    test "a member still gets [\"read\"] only — @pat_allowed_member_permissions is not widened" do
      ws = create_workspace!()
      user = register_user(uniq_email("member-mint"))
      {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, "member", "user")

      {_raw, pat} = self_mint(user)

      assert pat["permissions"] == ["read"]
    end

    test "a client-supplied role in the request body is ignored — the resolved role wins" do
      ws = create_workspace!()
      user = register_user(uniq_email("no-escalate-role"))
      {:ok, _} = TenancyAuth.create_membership(ws.id, user.id, "member", "user")

      {_raw, pat} = self_mint(user, %{"name" => "cli", "role" => "owner"})

      # A member requesting "owner" via the body still gets member-tier read
      # only — the role comes from the caller's REAL membership, never params.
      assert pat["permissions"] == ["read"]
    end
  end
end
