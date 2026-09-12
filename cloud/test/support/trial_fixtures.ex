defmodule BarkparkCloud.TrialFixtures do
  @moduledoc """
  THE FIXTURE HOLE, CLOSED (task-267f329679b38a00 c3).

  `Accounts.create_team/1` is a bare `%Team{} |> changeset |> Repo.insert()` —
  it grants NO trial and writes NO `subscriptions` row. Every suite fixture used
  it, so no test in `cloud/test` ever exercised a status-reading predicate
  against a team that actually HAD a subscription row: the lying-`status` defect
  recorded on this task (a raw-SQL `EXISTS … status IN ('active','past_due')`
  leg that was true forever for every signed-up team) was machine-invisible for
  exactly that reason. A green suite over teams with no subscription row says
  nothing about the shape that produced the defect.

  These helpers grant the trial through the PRODUCTION path
  (`Billing.start_trial/1` → the atomic `teams.trial_started_at` ledger claim →
  `insert_trial_subscription/2`), not by hand-inserting a `%Subscription{}`, so
  a fixture can never encode a row shape the product cannot produce.

    * `team_with_live_trial/0` — the row as a signup gets it: `plan "trial"`,
      `status "active"`, window in the FUTURE.
    * `team_with_lapsed_trial/0` — the same row, window moved into the PAST.
      This is the shape the console/billing readers disagree about: the column
      still says `active`, the clock says the trial is over.

  The backdate goes through `Subscription.changeset/2` so the validated status
  enumeration still applies; only `current_period_end` moves.
  """

  alias BarkparkCloud.Accounts
  alias BarkparkCloud.Billing
  alias BarkparkCloud.Billing.Subscription
  alias BarkparkCloud.Repo

  @doc "A team plus its live, PRODUCTION-granted `trial` subscription (window in the future)."
  @spec team_with_live_trial() :: {Accounts.Team.t(), Subscription.t()}
  def team_with_live_trial do
    n = System.unique_integer([:positive])

    {:ok, team} = Accounts.create_team(%{name: "Trial Team #{n}", slug: "trial-team-#{n}"})
    {:ok, %Subscription{} = sub} = Billing.start_trial(team)

    {team, sub}
  end

  @doc """
  A team whose granted trial has LAPSED — `current_period_end` `seconds_ago`
  in the past, `status` untouched at `"active"` (nothing reconciles it until
  `TrialExpiryWorker` finalises the row).
  """
  @spec team_with_lapsed_trial(pos_integer()) :: {Accounts.Team.t(), Subscription.t()}
  def team_with_lapsed_trial(seconds_ago \\ 3_600) do
    {team, sub} = team_with_live_trial()

    ends =
      DateTime.utc_now()
      |> DateTime.add(-seconds_ago, :second)
      |> DateTime.truncate(:microsecond)

    {:ok, sub} =
      sub
      |> Subscription.changeset(%{current_period_end: ends})
      |> Repo.update()

    {team, sub}
  end
end
