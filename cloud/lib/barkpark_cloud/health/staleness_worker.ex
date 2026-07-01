defmodule BarkparkCloud.Health.StalenessWorker do
  @moduledoc """
  The per-minute staleness sweep — the `ServerManagerJob` analog for Barkpark
  Cloud (Coolify `app/Jobs/ServerManagerJob.php`). Push-only ingest cannot notice
  an agent going SILENT (nothing flips `agent_status → offline` when
  `POST /v1/agent/report` simply stops arriving); this worker does.

  Each tick it loads the candidate set (`Registry.stale_online_barkparks/1` —
  managed/byo, agent online, team subscription active, last heartbeat older than
  the staleness threshold) and, per instance:

    * bumps `unreachable_count`;
    * once the count crosses `health_down_after_count` AND the alert latch is
      still clear, flips the instance offline (`agent_status → offline`,
      `health_status → unknown`), records a `"status"` event, fires ONE
      transition alert via the platform `Notifications` context
      (`dispatch_event(team_id, :agent_unreachable, …)` — the same first-class
      per-team-opt-in event the report-flip path uses), and live-pushes
      `"fleet"` so open dashboards refetch.

  Two debounce mechanisms, both straight ports of Coolify:

    * the `>= health_down_after_count` gate absorbs a single transient miss (a
      slow agent tick, a GC pause) — Coolify `ServerConnectionCheckJob.php:155`;
    * the `unreachable_notification_sent` latch + the online-only scan filter
      mean exactly one alert per outage and no re-scan of an already-offline box
      (the natural backoff — Barkpark has no active-probe channel, so a silent
      box simply leaves the candidate set until its agent reports again, which
      re-arms the latch via `Registry.record_agent_report/2`).

  Runs on the EXISTING `:maintenance` Oban queue (the oban-substrate foundation
  already ships Oban + a maintenance queue + the Cron plugin; config.exs merely
  appends this worker to the crontab). `Notifications.dispatch_event/3` is
  best-effort and never raises, and the flip is committed BEFORE the dispatch, so
  a flaky mail relay can never undo a status flip.

  Crash-safe: a failed flip/alert for ONE instance is logged and the loop
  continues; the next tick re-evaluates from current DB state. `max_attempts: 1`
  — a missed tick is harmless (the next minute's tick is identical), so Oban
  should not retry-storm a transient DB blip.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  require Logger

  alias BarkparkCloud.{Events, Notifications, Registry}

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    threshold =
      DateTime.utc_now()
      |> DateTime.add(-Registry.health_stale_after_seconds(), :second)

    Registry.stale_online_barkparks(threshold)
    |> Enum.each(&evaluate/1)

    :ok
  end

  # Bump the missed-heartbeat counter, then flip offline once the debounce gate
  # is crossed and the alert isn't already latched. Wrapped so ONE bad row never
  # sinks the whole sweep.
  defp evaluate(bp) do
    {:ok, bumped} = Registry.bump_unreachable(bp)

    if bumped.unreachable_count >= Registry.health_down_after_count() and
         not bumped.unreachable_notification_sent do
      flip_offline(bumped)
    end
  rescue
    e ->
      Logger.error(
        "StalenessWorker: evaluate failed for #{inspect(bp.id)}: #{Exception.message(e)}"
      )
  end

  defp flip_offline(bp) do
    case Registry.mark_offline(bp) do
      {:ok, offline} ->
        _ =
          Registry.record_event(offline, "status", %{
            transition: "offline",
            reason: "agent_silent",
            unreachable_count: offline.unreachable_count,
            at: DateTime.utc_now()
          })

        # Alert on the flip via the platform Notifications context — the SAME
        # per-team-opt-in `:agent_unreachable` event the report-flip path emits
        # (router maybe_dispatch_health_flip). dispatch_event/3 is best-effort:
        # it logs + swallows any delivery failure, so the flip (already
        # committed above) is never rolled back by a flaky relay.
        _ =
          Notifications.dispatch_event(offline.team_id, :agent_unreachable, %{name: offline.name})

        Events.broadcast(offline.team_id, "fleet")

      {:error, cs} ->
        Logger.error("StalenessWorker: mark_offline failed for #{bp.id}: #{inspect(cs)}")
    end
  end
end
