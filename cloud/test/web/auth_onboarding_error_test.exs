defmodule BarkparkCloud.Web.AuthOnboardingErrorTest do
  @moduledoc """
  Protective coverage for wbq-cloud-auth-onboarding-500: router.ex used to
  hard-match `{:ok, _} = Accounts.<fn>(...)` on Repo-backed calls typed
  `{:ok, _} | {:error, Ecto.Changeset.t()}`. A Repo failure raised a bare
  MatchError — a raw Bandit 500 OUTSIDE the JSON error envelope every other
  route uses (there is no Plug.ErrorHandler in cloud). The fix replaced each
  hard match with a `case`/`with` that adds an `{:error, _}` branch returning
  the established envelope, mirroring the already-correct `PUT
  /v1/account/password` arm.

  Six sites were fixed: the 2FA-pending mint and session mint in
  `POST /v1/auth/login`, the session mint in
  `POST /v1/auth/two-factor-challenge`, and the four
  `handle_onboarding_action/3` clauses (advance/ack/skip/complete) behind
  `POST /v1/onboarding`.

  FORCING THE FAILURE (session-token sites): `UserToken.changeset/2` declares
  `unique_constraint(:token_hash)` + `assoc_constraint(:user)`, so a genuine
  Postgres unique-violation on `user_tokens_token_hash_index` IS translated by
  Ecto into `{:error, %Ecto.Changeset{}}` (Ecto only converts a raised DB
  constraint error into a changeset error when the changeset declared a
  matching constraint — see `Ecto.Repo.Schema.constraints_to_errors/3`). A
  per-test BEFORE INSERT trigger on `user_tokens` raises exactly that
  constraint name/sqlstate, giving a REAL, Ecto-translatable failure without
  touching accounts.ex. The trigger is created inside the test's own sandboxed
  transaction, so it never leaks to other tests (rolled back on exit like any
  other DB change).

  ONBOARDING SITES — WHY THEY'RE COVERED DIFFERENTLY: `Team.onboarding_changeset/2`
  declares NO `unique_constraint`/`foreign_key_constraint`/`check_constraint` at
  all, so per that same Ecto mechanism a DB-raised error on `Repo.update` can
  only ever RAISE (`Ecto.ConstraintError`), never degrade into
  `{:error, changeset}` — regardless of what a test's trigger raises. The ONLY
  way `update_onboarding/2` can return `{:error, changeset}` is a *pre-DB*
  cast failure (`changeset.valid? == false` before `Repo.update` ever runs),
  which requires `onboarding_state` to arrive as a non-map — something
  `Accounts.advance_onboarding/2` and siblings never produce (they always
  `Map.merge`/`Map.put` into a real map before calling `update_onboarding/2`).
  So the router's new onboarding branches are unreachable via any live HTTP
  request against the current `accounts.ex` — a real defensive/type-safety
  fix, not a reachable bug. This file proves the CONTRACT is real (the
  changeset genuinely returns `{:error, changeset}` for invalid input, so the
  router's `case` branch is not dead code against the type signature) via a
  direct `Team.onboarding_changeset/2` check, and regression-tests that every
  onboarding action's happy path is unchanged.
  """
  use BarkparkCloud.DataCase, async: false

  import BarkparkCloud.TotpTestHelper
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Accounts.Team
  alias BarkparkCloud.Accounts.TwoFactorRateLimiter
  alias BarkparkCloud.Billing
  alias BarkparkCloud.Registry
  alias BarkparkCloud.Web.Router

  @opts Router.init([])
  @password "correct-horse-battery"

  setup do
    # async: false — enable_two_factor/login share the process-wide ETS rate
    # limiter (mirrors router_two_factor_test.exs).
    TwoFactorRateLimiter.reset()
    :ok
  end

  ## Fixtures / helpers (mirrors router_two_factor_test.exs / router_health_test.exs)

  defp user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> Enum.into(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: @password
      })
      |> Accounts.register_user()

    user
  end

  defp user_with_team do
    user = user_fixture()
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {Accounts.get_user(user.id), team}
  end

  defp call(method, path, body, token \\ nil) do
    conn =
      case body do
        nil ->
          conn(method, path)

        b ->
          conn(method, path, Jason.encode!(b))
          |> put_req_header("content-type", "application/json")
      end

    conn = if token, do: put_req_header(conn, "authorization", "Bearer #{token}"), else: conn
    Router.call(conn, @opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  defp login_token(user) do
    conn = call(:post, "/v1/auth/login", %{email: user.email, password: @password})
    json_body(conn)["token"]
  end

  defp enable_two_factor(user) do
    token = login_token(user)
    enroll = call(:post, "/v1/account/two-factor/enroll", %{}, token)
    %{"secret" => b32} = json_body(enroll)
    {:ok, secret} = Base.decode32(b32, padding: false)

    confirm =
      call(
        :post,
        "/v1/account/two-factor/confirm",
        %{code: totp_code_stable!(secret)},
        token
      )

    {json_body(confirm)["recovery_codes"], secret, token}
  end

  # Installs a BEFORE INSERT trigger on user_tokens that raises a REAL
  # Postgres unique_violation naming the exact constraint
  # `UserToken.changeset/2`'s `unique_constraint(:token_hash)` declares, so
  # Ecto translates it into `{:error, changeset}` (not a raise) for the very
  # next insert into user_tokens. Scoped to the calling test's own sandboxed
  # transaction — nothing to tear down, it rolls back with everything else.
  defp force_next_user_token_insert_to_conflict! do
    Repo.query!("""
    CREATE OR REPLACE FUNCTION barkpark_test_force_token_conflict()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION USING
        ERRCODE = 'unique_violation',
        CONSTRAINT = 'user_tokens_token_hash_index',
        TABLE = 'user_tokens',
        MESSAGE = 'test-forced unique violation on user_tokens_token_hash_index';
    END;
    $$ LANGUAGE plpgsql;
    """)

    Repo.query!("""
    CREATE TRIGGER barkpark_test_force_token_conflict_trigger
    BEFORE INSERT ON user_tokens
    FOR EACH ROW EXECUTE FUNCTION barkpark_test_force_token_conflict();
    """)
  end

  describe "POST /v1/auth/login — Repo failure returns the JSON envelope" do
    test "a 2FA-enabled user: create_two_factor_pending_token failure -> 422 envelope, not a 500" do
      {user, _team} = user_with_team()
      {_codes, _secret, _t} = enable_two_factor(user)

      force_next_user_token_insert_to_conflict!()

      conn = call(:post, "/v1/auth/login", %{email: user.email, password: @password})

      assert conn.status == 422
      body = json_body(conn)
      assert body["error"] == "invalid"
      assert %{"token_hash" => _} = body["details"]
    end

    test "a non-2FA user: create_user_session_token failure -> 422 envelope, not a 500" do
      {user, _team} = user_with_team()

      force_next_user_token_insert_to_conflict!()

      conn = call(:post, "/v1/auth/login", %{email: user.email, password: @password})

      assert conn.status == 422
      body = json_body(conn)
      assert body["error"] == "invalid"
      assert %{"token_hash" => _} = body["details"]
    end
  end

  describe "POST /v1/auth/two-factor-challenge — Repo failure returns the JSON envelope" do
    test "a correct OTP: create_user_session_token failure -> 422 envelope, not a 500" do
      {user, _team} = user_with_team()
      {_codes, secret, _t} = enable_two_factor(user)

      login = call(:post, "/v1/auth/login", %{email: user.email, password: @password})
      challenge = json_body(login)["challenge_token"]

      force_next_user_token_insert_to_conflict!()

      conn =
        call(:post, "/v1/auth/two-factor-challenge", %{
          challenge_token: challenge,
          code: code_for_period_offset!(secret, +1)
        })

      assert conn.status == 422
      body = json_body(conn)
      assert body["error"] == "invalid"
      assert %{"token_hash" => _} = body["details"]
    end
  end

  describe "POST /v1/onboarding — happy paths unchanged (regression)" do
    test "advance persists the resume pointer" do
      {user, team} = user_with_team()
      token = login_token(user)

      conn =
        call(:post, "/v1/onboarding", %{action: "advance", step: "instance"}, token)

      assert conn.status == 200
      assert json_body(conn)["onboarding"]["last_step"] == "instance"
      refute Accounts.get_team(team.id).onboarding_completed_at
    end

    test "ack ticks a manually-verified step" do
      {user, _team} = user_with_team()
      token = login_token(user)

      conn = call(:post, "/v1/onboarding", %{action: "ack", step: "published_doc"}, token)

      assert conn.status == 200
      steps = json_body(conn)["onboarding"]["steps"]
      assert Enum.find(steps, &(&1["key"] == "published_doc"))["done"] == true
    end

    test "skip dismisses the checklist" do
      {user, team} = user_with_team()
      token = login_token(user)

      conn = call(:post, "/v1/onboarding", %{action: "skip"}, token)

      assert conn.status == 200
      assert Accounts.get_team(team.id).onboarding_completed_at
    end

    test "complete is rejected until all steps are done, then succeeds" do
      {user, team} = user_with_team()
      token = login_token(user)

      incomplete = call(:post, "/v1/onboarding", %{action: "complete"}, token)
      assert incomplete.status == 422
      assert json_body(incomplete)["error"] == "steps_incomplete"

      # subscription + instance are LIVE domain checks (Billing/Registry), not
      # affected by "acked" — give the team a real trial + a real barkpark,
      # then ack the one honestly-unverifiable step (published_doc).
      {:ok, _} = Billing.start_trial(team)
      n = System.unique_integer([:positive])
      {:ok, _bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
      {:ok, _} = Accounts.ack_onboarding_step(Accounts.get_team(team.id), "published_doc")

      conn = call(:post, "/v1/onboarding", %{action: "complete"}, token)
      assert conn.status == 200
      assert Accounts.get_team(team.id).onboarding_completed_at
    end
  end

  describe "onboarding dispatcher — {:error, changeset} is a real, reachable TYPE (not dead code)" do
    test "Team.onboarding_changeset/2 (the changeset every handle_onboarding_action/3 clause writes through) rejects a non-map onboarding_state" do
      team = %Team{id: Ecto.UUID.generate(), name: "t", slug: "t", onboarding_state: %{}}

      changeset = Team.onboarding_changeset(team, %{onboarding_state: "not-a-map"})

      refute changeset.valid?
      assert %{onboarding_state: ["is invalid"]} = errors_on(changeset)
    end
  end
end
