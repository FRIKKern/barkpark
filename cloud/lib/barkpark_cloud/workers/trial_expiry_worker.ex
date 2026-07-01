defmodule BarkparkCloud.Workers.TrialExpiryWorker do
  @moduledoc """
  dwb-13 — the free-trial lifecycle worker. Runs hourly on the `:maintenance`
  queue and, over every LIVE `trial` subscription (`Billing.active_trials/0`):

    1. **Advance notices.** Sends a T-3-day and a T-1-day heads-up via the
       notifications system (`:trial_expiring`). Each threshold is claimed with
       an atomic `UPDATE … WHERE <stamp> IS NULL` on the team ledger, so an
       hourly cadence sends each notice EXACTLY ONCE — no spam.

    2. **Expiry teardown.** For a trial whose window has closed
       (`current_period_end <= now`) and that did NOT convert, enqueues a
       DEPROVISION job for each of the team's boxes through the EXISTING
       deprovision path (`Registry.enqueue_deprovision_job/1`) — no parallel
       teardown machinery. Idempotent: a still-pending teardown is deduped
       (`:already_deprovisioning`), and once the boxes are gone the scan is a
       no-op.

  MONEY-PATH SAFETY (adversarial): a CONVERTED team's live row is a PAID plan, so
  `active_trials/0` never returns it — this worker only ever sees `plan ==
  "trial"` rows and thus can NEVER tear down a subscribed team's box or spam it
  with expiry notices. The trial→paid conversion additionally cancels any
  in-flight teardown (`Registry.cancel_pending_deprovision_jobs/1`), closing the
  convert-just-after-expiry race.

  Idempotent + never raises: a run over nothing due returns zero counts. The
  `unique` window collapses a slow run + the next tick to one in-flight job.
  """
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: 600, states: [:available, :scheduled, :executing, :retryable, :suspended]]

  import Ecto.Query, warn: false

  alias BarkparkCloud.Accounts.Team
  alias BarkparkCloud.Billing.Subscription
  alias BarkparkCloud.{Billing, Notifications, Registry, Repo}

  # Advance-notice thresholds, in seconds. A trial with `remaining <= @one_day`
  # gets the T-1 notice; `@one_day < remaining <= @three_days` gets the T-3 one.
  @one_day 86_400
  @three_days 3 * 86_400

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {:ok, run(DateTime.utc_now())}
  end

  @doc """
  Scan the live trials once against `now`. Returns a summary map
  `%{noticed_3d, noticed_1d, expired, teardowns}`. Public so tests can drive it
  deterministically (the `perform/1` entry passes `DateTime.utc_now/0`).
  """
  @spec run(DateTime.t()) :: %{
          noticed_3d: non_neg_integer(),
          noticed_1d: non_neg_integer(),
          expired: non_neg_integer(),
          teardowns: non_neg_integer()
        }
  def run(now) do
    zero = %{noticed_3d: 0, noticed_1d: 0, expired: 0, teardowns: 0}

    Billing.active_trials()
    |> Enum.reduce(zero, fn sub, acc ->
      case Repo.get(Team, sub.team_id) do
        nil -> acc
        team -> handle_trial(acc, team, sub, now)
      end
    end)
  end

  # A trial with no window is malformed — skip it (never entitled anyway).
  defp handle_trial(acc, _team, %Subscription{current_period_end: nil}, _now), do: acc

  defp handle_trial(acc, team, %Subscription{current_period_end: ends} = sub, now) do
    if DateTime.compare(ends, now) != :gt do
      # Window closed and this is still a `trial` row (unconverted) → tear down.
      n = teardown(team)
      %{acc | expired: acc.expired + 1, teardowns: acc.teardowns + n}
    else
      maybe_notice(acc, team, sub, DateTime.diff(ends, now, :second), now)
    end
  end

  # T-1 supersedes T-3: at <= 1 day we claim+send the 1-day notice AND silently
  # claim the 3-day stamp so a late 3-day email can never fire afterward.
  defp maybe_notice(acc, team, sub, remaining, now) when remaining <= @one_day do
    if claim_notice(team.id, :trial_notice_1d_sent_at, now) do
      _ = claim_notice(team.id, :trial_notice_3d_sent_at, now)
      notify(team, sub, 1)
      %{acc | noticed_1d: acc.noticed_1d + 1}
    else
      acc
    end
  end

  defp maybe_notice(acc, team, sub, remaining, now) when remaining <= @three_days do
    if claim_notice(team.id, :trial_notice_3d_sent_at, now) do
      notify(team, sub, 3)
      %{acc | noticed_3d: acc.noticed_3d + 1}
    else
      acc
    end
  end

  defp maybe_notice(acc, _team, _sub, _remaining, _now), do: acc

  # Atomically claim a per-threshold notice stamp: the UPDATE only matches while
  # the stamp is NULL, so exactly one run per threshold wins → the notice sends
  # once. Returns true when this call claimed it.
  defp claim_notice(team_id, field, now) do
    {count, _} =
      from(t in Team, where: t.id == ^team_id and is_nil(field(t, ^field)))
      |> Repo.update_all(set: [{field, now}])

    count == 1
  end

  # One advance-notice alert. Rides the notifications system; `:trial_expiring`
  # is on the always-send allowlist (it still honours a team's global mute).
  defp notify(team, _sub, days) do
    detail =
      "Your Barkpark free trial ends in #{days} #{if(days == 1, do: "day", else: "days")}. " <>
        "Upgrade to keep your instance running — it's torn down automatically when the trial ends."

    Notifications.dispatch_event(team, :trial_expiring, %{
      days: days,
      name: team.name,
      detail: detail
    })
  end

  # Enqueue a deprovision through the EXISTING path for each of the team's boxes.
  # Deduped + idempotent; returns how many fresh teardowns were enqueued.
  defp teardown(team) do
    team
    |> Registry.list_barkparks()
    |> Enum.reduce(0, fn bp, n ->
      case Registry.enqueue_deprovision_job(bp) do
        {:ok, _job} -> n + 1
        _ -> n
      end
    end)
  end
end
