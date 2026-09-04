defmodule BarkparkWeb.GrantControllerTest do
  @moduledoc """
  Airdrop-grant CLAIM flow (`GET /grant/:token`), proved NON-VACUOUSLY:

    * the addressed grantee, signed in, claims an active grant → the grant is
      bound to their account and they land in the scoped Studio;
    * an anonymous visitor is bounced to `/login` with a `return_to` that
      carries the token so the claim resumes after sign-in;
    * the load-bearing NO-ORACLE property: a wrong-grantee authenticated user
      gets a response BYTE-IDENTICAL to a nonexistent token — token existence is
      unobservable;
    * expired and already-spent grants collapse to that same failure;
    * a successful claim stamps `grantee_user_id` (account-binding).
  """
  use BarkparkWeb.ConnCase, async: true

  import Barkpark.AccountsFixtures
  import Barkpark.TenancyFixtures

  alias Barkpark.Access
  alias Barkpark.Accounts
  alias Barkpark.Auth.ApiToken
  alias Barkpark.Repo
  alias Barkpark.Tenancy.Auth

  # An API-token grantor made admin of `ws`, so Access.mint's no-escalation
  # gate passes (a grantor can only confer what it holds).
  defp grantor_token(ws) do
    {:ok, token} =
      %ApiToken{}
      |> ApiToken.changeset(%{
        token_hash: ApiToken.hash_token("t-" <> Ecto.UUID.generate()),
        label: "grantor",
        dataset: "test",
        permissions: ["admin"]
      })
      |> Repo.insert()

    {:ok, _} = Auth.create_membership(ws.id, token.id, "admin", "api_token")
    token
  end

  # Authenticate a browser user the way OptionalSessionToken reads it: a real
  # `user_session` cookie that verify_user_session resolves to :current_user.
  defp log_in(conn, user) do
    {:ok, token} =
      Accounts.create_user_session_token(user, ip_address: "127.0.0.1", user_agent: "test")

    init_test_session(conn, %{"user_session" => token})
  end

  # Mint an active grant for `grantee_email`, returning {grant, raw_token}.
  defp mint_grant(ws, grantee_email, overrides \\ %{}) do
    grantor = grantor_token(ws)

    attrs =
      Map.merge(
        %{grantee_email: grantee_email, workspace_id: ws.id, capabilities: ["read"]},
        overrides
      )

    {:ok, %{grant: grant, token: raw}} = Access.mint(grantor, attrs)
    {grant, raw}
  end

  # ---------------------------------------------------------------------------
  # 1. Happy path — addressed grantee claims an active grant
  # ---------------------------------------------------------------------------

  test "authed correct grantee claims an active grant → bound + scoped-studio redirect", %{
    conn: conn
  } do
    ws = create_workspace!()
    project = create_project!(ws)
    user = register_user("grantee-#{System.unique_integer([:positive])}@example.com")
    {_grant, raw} = mint_grant(ws, user.email, %{project_id: project.id, dataset: "production"})

    conn = conn |> log_in(user) |> get("/grant/#{raw}")

    target = redirected_to(conn)
    assert target == "/w/#{ws.slug}/p/#{project.slug}/d/production/studio"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Access granted"

    # account-binding actually happened
    {_id, claimed} = mint_lookup(raw)
    assert claimed.grantee_user_id == user.id
    refute is_nil(claimed.claimed_at)
  end

  # ---------------------------------------------------------------------------
  # 2. Anonymous → /login with a return_to that carries the token
  # ---------------------------------------------------------------------------

  test "unauthenticated visitor is bounced to /login with return_to=/grant/<token>", %{
    conn: conn
  } do
    ws = create_workspace!()
    {_grant, raw} = mint_grant(ws, "someone@example.com")

    conn = get(conn, "/grant/#{raw}")

    location = redirected_to(conn)
    assert String.starts_with?(location, "/login?")

    %{query: query} = URI.parse(location)
    assert %{"return_to" => "/grant/" <> token} = URI.decode_query(query)
    assert token == raw
  end

  # ---------------------------------------------------------------------------
  # 3. NO-ORACLE — wrong grantee ≡ nonexistent token (byte-identical)
  # ---------------------------------------------------------------------------

  test "wrong-grantee response is BYTE-IDENTICAL to a nonexistent token", %{conn: conn} do
    ws = create_workspace!()
    intruder = register_user("intruder-#{System.unique_integer([:positive])}@example.com")

    # A real, active grant addressed to SOMEONE ELSE.
    {_grant, real_raw} = mint_grant(ws, "the-real-grantee@example.com")

    wrong_grantee =
      conn |> log_in(intruder) |> get("/grant/#{real_raw}")

    nonexistent =
      scoped_conn() |> log_in(intruder) |> get("/grant/this-token-does-not-exist")

    # Same status, same redirect, same flash, same bytes — nothing distinguishes
    # a wrong-account claim from a token that never existed.
    assert wrong_grantee.status == nonexistent.status
    assert redirected_to(wrong_grantee) == redirected_to(nonexistent)

    assert Phoenix.Flash.get(wrong_grantee.assigns.flash, :error) ==
             Phoenix.Flash.get(nonexistent.assigns.flash, :error)

    assert wrong_grantee.resp_body == nonexistent.resp_body

    # And the intruder's claim did NOT bind the grant.
    {id, _} = mint_lookup(real_raw)
    assert is_nil(Access.get_grant(id).grantee_user_id)
  end

  # ---------------------------------------------------------------------------
  # 4. Expired grant (correct grantee) → same no-oracle failure
  # ---------------------------------------------------------------------------

  test "expired grant for the correct grantee is the identical no-oracle failure", %{conn: conn} do
    ws = create_workspace!()
    user = register_user("expired-#{System.unique_integer([:positive])}@example.com")
    past = DateTime.add(DateTime.utc_now(), -3600, :second)
    {_grant, raw} = mint_grant(ws, user.email, %{expires_at: past})

    failing = conn |> log_in(user) |> get("/grant/#{raw}")

    reference =
      scoped_conn() |> log_in(user) |> get("/grant/no-such-token")

    assert redirected_to(failing) == redirected_to(reference)

    assert Phoenix.Flash.get(failing.assigns.flash, :error) ==
             Phoenix.Flash.get(reference.assigns.flash, :error)

    assert failing.resp_body == reference.resp_body
  end

  # ---------------------------------------------------------------------------
  # 5. Single-use already-claimed → identical no-oracle failure
  # ---------------------------------------------------------------------------

  test "second claim of a single-use grant is the identical no-oracle failure", %{conn: conn} do
    ws = create_workspace!()
    project = create_project!(ws)
    user = register_user("single-#{System.unique_integer([:positive])}@example.com")

    {_grant, raw} =
      mint_grant(ws, user.email, %{project_id: project.id, single_use: true})

    # First claim succeeds.
    first = conn |> log_in(user) |> get("/grant/#{raw}")
    assert Phoenix.Flash.get(first.assigns.flash, :info) =~ "Access granted"

    # Second claim of the now-spent token collapses to the no-oracle failure.
    second = scoped_conn() |> log_in(user) |> get("/grant/#{raw}")

    reference =
      scoped_conn() |> log_in(user) |> get("/grant/no-such-token")

    assert redirected_to(second) == redirected_to(reference)

    assert Phoenix.Flash.get(second.assigns.flash, :error) ==
             Phoenix.Flash.get(reference.assigns.flash, :error)

    assert second.resp_body == reference.resp_body
  end

  # ---------------------------------------------------------------------------
  # 6. Account-binding is enforced on success
  # ---------------------------------------------------------------------------

  test "a successful claim binds grantee_user_id to the current user", %{conn: conn} do
    ws = create_workspace!()
    user = register_user("bind-#{System.unique_integer([:positive])}@example.com")
    {_grant, raw} = mint_grant(ws, user.email)

    conn |> log_in(user) |> get("/grant/#{raw}")

    {id, _} = mint_lookup(raw)
    assert Access.get_grant(id).grantee_user_id == user.id
  end

  # ---------------------------------------------------------------------------
  # 7. Confirmed-account gate — an UNCONFIRMED grantee cannot claim (finding #2)
  # ---------------------------------------------------------------------------

  test "an unconfirmed grantee (email matches) cannot claim → no-oracle failure, NOT bound", %{
    conn: conn
  } do
    ws = create_workspace!()
    project = create_project!(ws)
    # Self-serve account with the grantee's exact email but NO mailbox proof.
    user =
      register_unconfirmed_user("unconfirmed-#{System.unique_integer([:positive])}@example.com")

    {_grant, raw} = mint_grant(ws, user.email, %{project_id: project.id, dataset: "production"})

    failing = conn |> log_in(user) |> get("/grant/#{raw}")

    # Collapses to the single no-oracle failure — byte-identical to a token that
    # never existed (same redirect, same flash, same body). No account-state leak.
    reference = scoped_conn() |> log_in(user) |> get("/grant/no-such-token")

    assert redirected_to(failing) == redirected_to(reference)

    assert Phoenix.Flash.get(failing.assigns.flash, :error) ==
             Phoenix.Flash.get(reference.assigns.flash, :error)

    assert failing.resp_body == reference.resp_body

    # The account-binding did NOT happen — the whole point of the gate.
    {id, _} = mint_lookup(raw)
    assert is_nil(Access.get_grant(id).grantee_user_id)
  end

  # Resolve a grant id from its raw token via the same hash the context uses,
  # so post-claim assertions can re-fetch by id (lookup_by_token filters out
  # spent single-use grants). Returns {id, grant_or_nil}.
  defp mint_lookup(raw) do
    hash = :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
    grant = Repo.get_by(Access.Grant, link_token_hash: hash)
    {grant && grant.id, grant}
  end
end
