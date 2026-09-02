# The migration is not part of the compiled app (migrations live outside the lib
# path), so it is loaded HERE — before this file compiles — rather than in a
# setup block: the tests call the migration's own statement builders, and a
# runtime-only load would leave those calls compiling against an unknown module.
unless Code.ensure_loaded?(BarkparkCloud.Repo.Migrations.FinalizeLapsedTrialSubscriptions) do
  Code.require_file(
    Path.expand(
      "../../../priv/repo/migrations/20260901120000_finalize_lapsed_trial_subscriptions.exs",
      __DIR__
    )
  )
end

defmodule BarkparkCloud.Billing.LapsedTrialFinalisationMigrationTest do
  @moduledoc """
  cch-w50 — the guard on `20260901120000_finalize_lapsed_trial_subscriptions.exs`,
  the one-shot reconciliation of the fifteen trial rows that lapsed while nothing
  in `cloud/lib` was capable of finalising them.

  The migration is a data migration on the MONEY TABLE, so what it must not touch
  matters more than what it touches. Every case here seeds a row the predicate
  must SKIP alongside the row it must catch, and both are checked — a migration
  that flipped every trial row would pass a catch-only test and take a live
  trial's entitlement away with it.

  It runs the migration's OWN `up_statement/0` and `down_statement/0` — not a
  paraphrase — so a predicate change in the migration is a predicate change here.

  MUTATION-PROVED (run before commit, one at a time; counts as measured):

    * dropping the `NOT EXISTS (… barkparks …)` leg from `up_statement/0` reds
      "a lapsed trial whose box is STILL UP is left alone" (1 failure).
    * dropping the `current_period_end < now()` leg reds "a LIVE trial is left
      alone" (1) — the case that keeps a paying-window team's entitlement.
    * widening `status = 'active'` to `IN ('active','canceled')` reds all three
      idempotence/producer cases (3): "running it twice…", "a row the WORKER
      already finalised is skipped", and the down's canceled_at fence.
    * dropping the down's `canceled_at = current_period_end` fence reds "the down
      leaves the WORKER's rows alone" (1).

  THE UPDATED_AT TRAP, RECORDED BECAUSE IT CAUGHT THIS FILE ONCE. An earlier
  draft carried the idempotence on `after_second.updated_at == first.updated_at`,
  which is VACUOUS here: the statement writes `now()`, and inside one transaction
  `now()` is `transaction_timestamp()` — identical across both calls even when the
  second genuinely rewrote the row. The status-widening mutation left it green.
  The assertion is on the match COUNT now.

  `async: false`: these statements are unqualified table-wide UPDATEs whose match
  count this file asserts on. The Ecto sandbox already keeps another case's
  uncommitted rows out of their reach; running sync keeps the count from
  depending on that being true of every future fixture.
  """
  use BarkparkCloud.DataCase, async: false

  alias BarkparkCloud.{Accounts, Registry, Repo}
  alias BarkparkCloud.Billing.Subscription

  @migration BarkparkCloud.Repo.Migrations.FinalizeLapsedTrialSubscriptions

  ## ── Fixtures ─────────────────────────────────────────────────────────────

  defp team_fixture do
    n = System.unique_integer([:positive])
    {:ok, team} = Accounts.create_team(%{name: "Team #{n}", slug: "team-#{n}"})
    team
  end

  defp days_ago(n),
    do: DateTime.utc_now() |> DateTime.add(-n, :day) |> DateTime.truncate(:microsecond)

  defp days_ahead(n),
    do: DateTime.utc_now() |> DateTime.add(n, :day) |> DateTime.truncate(:microsecond)

  defp subscription(team, attrs) do
    Repo.insert!(struct!(%Subscription{team_id: team.id}, attrs))
  end

  defp barkpark_fixture(team) do
    n = System.unique_integer([:positive])
    {:ok, bp} = Registry.register_barkpark(team, %{name: "BP #{n}", slug: "bp-#{n}"})
    bp
  end

  # THE GHOST: the exact live shape — a trial whose window closed weeks ago, whose
  # team has no boxes left, still reading `active`.
  defp ghost_row(lapsed_days_ago \\ 21) do
    team = team_fixture()

    sub =
      subscription(team,
        plan: "trial",
        status: "active",
        current_period_end: days_ago(lapsed_days_ago)
      )

    {team, sub}
  end

  defp run_up do
    {sql, params} = @migration.up_statement()
    %Postgrex.Result{num_rows: n} = Repo.query!(sql, params)
    n
  end

  defp run_down do
    {sql, params} = @migration.down_statement()
    %Postgrex.Result{num_rows: n} = Repo.query!(sql, params)
    n
  end

  defp reload(sub), do: Repo.get!(Subscription, sub.id)

  ## ── The catch ────────────────────────────────────────────────────────────

  describe "the up finalises exactly the ghost shape" do
    test "a lapsed trial with no boxes becomes canceled, backdated to its own window" do
      {_team, sub} = ghost_row()

      assert run_up() >= 1

      row = reload(sub)
      assert row.status == "canceled"
      assert row.plan == "trial", "the plan is the row's history — only the status closes"

      assert DateTime.compare(row.canceled_at, sub.current_period_end) == :eq,
             "backdated to the moment the trial actually ended, not to deploy day"
    end

    test "the finalised row leaves every LIVE read — which is what silences the trial card" do
      {team, _sub} = ghost_row()

      assert BarkparkCloud.Billing.live_subscription(team)
      run_up()

      assert is_nil(BarkparkCloud.Billing.live_subscription(team)),
             "/v1/subscription now answers {subscription: nil} → the honest upsell, not a trial card"

      assert is_nil(BarkparkCloud.Billing.trial_days_remaining(team))
    end

    test "entitlement is UNCHANGED — the expired trial was already un-entitled" do
      {team, _sub} = ghost_row()
      refute BarkparkCloud.Billing.entitled?(team)

      run_up()

      refute BarkparkCloud.Billing.entitled?(team),
             "no team crosses the launch gate in either direction because of this migration"
    end
  end

  ## ── What it must NOT touch ───────────────────────────────────────────────

  describe "the up leaves every other row byte-identical" do
    test "a LIVE trial is left alone" do
      team = team_fixture()

      live =
        subscription(team, plan: "trial", status: "active", current_period_end: days_ahead(7))

      run_up()

      row = reload(live)
      assert row.status == "active"
      assert is_nil(row.canceled_at)

      assert BarkparkCloud.Billing.entitled?(team),
             "a team inside its trial keeps its entitlement"
    end

    test "a lapsed trial whose box is STILL UP is left alone" do
      # The migration mirrors the worker's own gate: finalise only once the
      # teardown has happened. A row finalised while its box is still standing
      # would push a converting team off `activate_from_session/4`'s in-place
      # trial arm — the one that cancels the pending deprovision.
      {team, sub} = ghost_row()
      _bp = barkpark_fixture(team)

      run_up()

      assert reload(sub).status == "active"
      assert %Subscription{plan: "trial"} = BarkparkCloud.Billing.live_subscription(team)
    end

    test "a PAID row past its period is left alone (this is not a subscription reaper)" do
      team = team_fixture()

      paid =
        subscription(team, plan: "supporter", status: "active", current_period_end: days_ago(30))

      run_up()

      assert reload(paid).status == "active"
    end

    test "a `forever` comp and a `free` row are left alone" do
      comp_team = team_fixture()

      comp =
        subscription(comp_team,
          plan: "forever",
          status: "active",
          current_period_end: days_ago(90)
        )

      free_team = team_fixture()

      free =
        subscription(free_team, plan: "free", status: "active", current_period_end: days_ago(90))

      run_up()

      assert reload(comp).status == "active"
      assert reload(free).status == "active"
    end

    test "a past_due row past its grace is left alone (a different lifecycle owns it)" do
      team = team_fixture()

      due =
        subscription(team, plan: "supporter", status: "past_due", current_period_end: days_ago(9))

      run_up()

      assert reload(due).status == "past_due"
    end

    test "a trial with NO window is left alone — a NULL is not a closed window" do
      team = team_fixture()
      malformed = subscription(team, plan: "trial", status: "active", current_period_end: nil)

      run_up()

      assert reload(malformed).status == "active"
    end
  end

  ## ── Idempotence ──────────────────────────────────────────────────────────

  describe "idempotence" do
    test "running it twice is indistinguishable from running it once" do
      {_team, sub} = ghost_row()

      assert run_up() >= 1, "the first pass finalises the ghost"
      first = reload(sub)

      # THE IDEMPOTENCE, MEASURED ON THE MATCH COUNT, NOT ON THE ROW. `updated_at`
      # cannot carry this assertion: the statement writes `now()`, which inside
      # one transaction is `transaction_timestamp()` — byte-identical across both
      # calls even when the second genuinely DID rewrite the row. (Measured:
      # widening the status leg to `IN ('active','canceled')` left an
      # `updated_at` comparison green.) The Ecto sandbox holds this test in its
      # own transaction, so an UPDATE here can only reach rows this test created
      # plus committed ones — of which there are none — making 0 attributable.
      assert run_up() == 0,
             "the second pass matches NOTHING — `status = 'active'` IS the idempotence"

      after_second = reload(sub)
      assert after_second.status == "canceled"
      assert after_second.canceled_at == first.canceled_at
    end

    test "a row the WORKER already finalised is skipped, not rewritten" do
      {team, sub} = ghost_row()

      # The worker's own write: `canceled_at` at the moment it noticed, strictly
      # later than the window.
      assert {:ok, _} = BarkparkCloud.Billing.expire_trial(sub, DateTime.utc_now())
      worker_written = reload(sub)
      assert worker_written.status == "canceled"

      assert DateTime.compare(worker_written.canceled_at, sub.current_period_end) == :gt

      run_up()

      assert reload(sub).canceled_at == worker_written.canceled_at
      assert is_nil(BarkparkCloud.Billing.live_subscription(team))
    end
  end

  ## ── The down ─────────────────────────────────────────────────────────────

  describe "the down reverses exactly what the up wrote" do
    test "a row this migration finalised comes back to active" do
      {_team, sub} = ghost_row()

      run_up()
      assert reload(sub).status == "canceled"

      run_down()

      row = reload(sub)
      assert row.status == "active"
      assert is_nil(row.canceled_at)
    end

    test "the down leaves the WORKER's rows alone — the canceled_at fence" do
      # The worker stamps a LATER canceled_at than the window; this migration
      # stamps the window itself. That difference is the whole down fence: a
      # rollback must not resurrect rows a live producer legitimately closed.
      {_team, worker_row} = ghost_row()
      assert {:ok, _} = BarkparkCloud.Billing.expire_trial(worker_row, DateTime.utc_now())
      worker_written = reload(worker_row)

      {_team2, migration_row} = ghost_row()
      run_up()

      run_down()

      assert reload(worker_row).status == "canceled", "the producer's row survives the rollback"
      assert reload(worker_row).canceled_at == worker_written.canceled_at
      assert reload(migration_row).status == "active", "and this migration's own row is reversed"
    end

    test "a team that SUBSCRIBED after the up is skipped — the down never breaks the live index" do
      # `subscriptions_one_live_per_team_idx` admits one active/past_due row per
      # team. Reviving a dead trial next to a live paid row would violate it and
      # abort the entire down transaction, so the down anti-joins such a team out.
      {team, sub} = ghost_row()
      run_up()

      paid = subscription(team, plan: "supporter", status: "active")

      run_down()

      assert reload(sub).status == "canceled", "the dead trial stays dead"
      assert reload(paid).status == "active", "and the live paid row is untouched"
    end

    test "a never-finalised trial is not swept up by the down either" do
      team = team_fixture()

      live =
        subscription(team, plan: "trial", status: "active", current_period_end: days_ahead(5))

      run_up()
      run_down()

      row = reload(live)
      assert row.status == "active"
      assert is_nil(row.canceled_at)
    end
  end
end
