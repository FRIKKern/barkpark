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
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.Access
  alias Barkpark.Accounts
  alias Barkpark.Auth
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @password "correct-horse-battery"

  defp register_user(email) do
    {:ok, user} = Accounts.register_user(%{email: email, password: @password})
    user
  end

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
      {:ok, _} = TenancyAuth.create_membership(ws.id, admin_token_id(admin_raw), "admin", "api_token")
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
end
