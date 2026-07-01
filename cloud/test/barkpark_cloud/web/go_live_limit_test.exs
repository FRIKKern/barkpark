defmodule BarkparkCloud.Web.GoLiveLimitTest do
  @moduledoc """
  usage-limits-quotas: the QUOTA gate at the HTTP boundary — `go_live/1` returns
  403 `limit_reached` when a subscribed team is at its plan's instance ceiling,
  the 402 `no_active_subscription` (entitlement) precedes it, and a create that
  loses a quota race is mapped to a clean 403 (never a 500) by the `with/else`
  backstop. Drives the router directly via Plug.Test, mirroring `router_test.exs`.
  """
  use BarkparkCloud.DataCase, async: true
  import Plug.Test
  import Plug.Conn

  alias BarkparkCloud.{Accounts, Billing, Registry}
  alias BarkparkCloud.Accounts.Team
  alias BarkparkCloud.Web.Router

  @opts Router.init([])

  ## Fixtures / helpers

  defp user_with_team do
    {:ok, user} =
      Accounts.register_user(%{
        email: "user-#{System.unique_integer([:positive])}@example.com",
        password: "correct horse battery staple"
      })

    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    {:ok, _} = Accounts.add_member(team, user, "owner")
    {user, team}
  end

  defp call(method, path, body, token) do
    conn(method, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
    |> Router.call(@opts)
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  # Mark a team's ONE free trial as already used (ledger stamped in the past, no
  # live sub) so go-live's dwb-13 auto-start returns :trial_used → the 402 stands.
  defp exhaust_trial(team) do
    past = DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:microsecond)

    {1, _} =
      Repo.update_all(
        from(t in Team, where: t.id == ^team.id),
        set: [trial_started_at: past, trial_ends_at: past]
      )

    :ok
  end

  ## Tests

  test "go_live returns 403 limit_reached when at the plan ceiling" do
    {user, team} = user_with_team()
    # free plan → limit 1.
    {:ok, _sub} = Billing.subscribe(team, "free")
    {:ok, token} = Accounts.create_user_session_token(user)

    first = call(:post, "/v1/go-live", %{name: "First"}, token)
    assert first.status == 201

    second = call(:post, "/v1/go-live", %{name: "Second"}, token)
    assert second.status == 403

    body = json_body(second)
    assert body["error"] == "limit_reached"
    assert body["limit"] == 1
    assert body["upgrade_path"] == "/v1/billing/checkout"

    # NOTHING extra was provisioned — still exactly one instance.
    assert length(Registry.list_barkparks(team)) == 1
  end

  test "ADVERSARIAL (dwb-13): double-launch during a trial never makes two boxes — quota 1" do
    # A trial's quota is 1. First launch auto-starts the trial AND provisions;
    # the SECOND launch must hit the 403 quota gate, not a second box (nor a
    # second trial). Proves the guard FIRES — one box, one trial sub.
    {user, team} = user_with_team()
    {:ok, token} = Accounts.create_user_session_token(user)

    first = call(:post, "/v1/go-live", %{name: "Only"}, token)
    assert first.status == 201
    # The trial auto-started (entitled) and its ceiling is 1.
    assert Billing.entitled?(team)
    assert Billing.barkpark_limit(team) == 1

    second = call(:post, "/v1/go-live", %{name: "Again"}, token)
    assert second.status == 403
    assert json_body(second)["error"] == "limit_reached"

    # Exactly ONE instance, and exactly ONE (trial) subscription — no doubles.
    assert length(Registry.list_barkparks(team)) == 1
    assert %{plan: "trial"} = Billing.live_subscription(team)

    assert 1 ==
             Repo.aggregate(
               from(s in BarkparkCloud.Billing.Subscription, where: s.team_id == ^team.id),
               :count
             )
  end

  test "402 (no subscription) precedes 403 (limit) — an unentitled team never reaches the quota gate" do
    # SECURITY ordering: the entitlement gate sits BEFORE the quota gate, so an
    # unsubscribed caller learns "subscribe" (402), not "upgrade" (403). dwb-13:
    # a NEVER-trialed team would auto-start its trial here — so to reach the 402
    # the team must have already EXHAUSTED its one free trial.
    {user, team} = user_with_team()
    exhaust_trial(team)
    {:ok, token} = Accounts.create_user_session_token(user)

    conn = call(:post, "/v1/go-live", %{name: "Anything"}, token)
    assert conn.status == 402
    assert json_body(conn)["error"] == "no_active_subscription"
  end

  test "dwb-13: a never-trialed team's first launch auto-starts the free trial → 201" do
    # The auto-start fallback: no subscription + unused trial ledger → the trial
    # starts here (fewest clicks) instead of a dead-end 402, and the box launches.
    {user, team} = user_with_team()
    refute Billing.entitled?(team)
    {:ok, token} = Accounts.create_user_session_token(user)

    conn = call(:post, "/v1/go-live", %{name: "First"}, token)
    assert conn.status == 201
    assert Billing.entitled?(team)
    assert length(Registry.list_barkparks(team)) == 1
  end

  test "a subscribed team below its ceiling still launches (201)" do
    {user, team} = user_with_team()
    # supporter plan → limit 3.
    {:ok, _sub} = Billing.subscribe(team, "supporter")
    {:ok, token} = Accounts.create_user_session_token(user)

    assert call(:post, "/v1/go-live", %{name: "One"}, token).status == 201
    assert call(:post, "/v1/go-live", %{name: "Two"}, token).status == 201
    assert call(:post, "/v1/go-live", %{name: "Three"}, token).status == 201
    # Fourth crosses the supporter ceiling → 403.
    assert call(:post, "/v1/go-live", %{name: "Four"}, token).status == 403
  end

  test "TOCTOU: concurrent go-live at a limit of 1 only ever 201s or 403s — never 500s" do
    # SECURITY: with no DB constraint, a create race can slip past the cond's
    # count check; the register_barkpark/2 backstop then returns
    # {:error, :limit_reached}, which the go_live `with/else` maps to a clean 403.
    # No path may 500. This drives real concurrent tasks (shared-mode sandbox).
    {user, team} = user_with_team()
    {:ok, _sub} = Billing.subscribe(team, "free")
    {:ok, token} = Accounts.create_user_session_token(user)

    parent = self()

    statuses =
      for i <- 1..6 do
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(BarkparkCloud.Repo, parent, self())
          call(:post, "/v1/go-live", %{name: "Race #{i}"}, token).status
        end)
      end
      |> Enum.map(&Task.await/1)

    # Every response is a mapped 201 or 403 — never an unhandled 500.
    assert Enum.all?(statuses, &(&1 in [201, 403]))
    # The success count matches the rows actually created (no phantom 201s).
    assert Enum.count(statuses, &(&1 == 201)) == length(Registry.list_barkparks(team))
  end
end
