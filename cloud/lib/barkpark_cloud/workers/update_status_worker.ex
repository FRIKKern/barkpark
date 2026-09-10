defmodule BarkparkCloud.Workers.UpdateStatusWorker do
  @moduledoc """
  isu-6 — the hourly self-update status sweep. Each live instance is the SOURCE
  OF TRUTH for its own update availability (it knows its own upstream/fork), so
  this worker never computes a verdict: it asks each instance
  (`Registry.refresh_update_status/1` → `GET /v1/admin/self-update` with the
  stored admin token, server-side) and mirrors the answer onto the row the
  fleet dashboard reads.

  deploy-reliability W21 adds a SECOND, independent arm after that mirror: the
  control plane's OWN freshness measurement
  (`Registry.refresh_commit_distance/2` → one unauthenticated GitHub compare of
  the box's `git_commit` against `main`), landing in its own three columns. It
  exists because the mirrored verdict is a release-TAG self-grade — six live
  boxes all read `current` at `0.2.25` while sitting 4 / 227 / 592 / 886 / 2,468
  commits behind. The arm is strictly second and separately rescued: it can
  never fail, skip or reorder the mirror above it.

  Two entry modes:

    * no args (the hourly cron tick) — sweep every update-checkable instance
      (`Registry.update_checkable_barkparks/0`: host set, not billing-suspended);
    * `%{"barkpark_id" => id}` — refresh ONE instance; enqueued by the
      `POST /v1/barkparks/:id/self-update` route (scheduled shortly after the
      trigger so the row reflects the run without waiting for the next sweep).

  The commit-distance arm is BUDGETED and ACCOUNTED by
  `BarkparkCloud.GitHub.CommitDistanceSweep`, opened once per tick: boxes
  sharing a `git_commit` cost ONE compare call (per-sha memo), the tick halts
  issuing compares after the first 403 rather than burning the rest of the
  shared 60/h anonymous budget on refusals, and the tick logs + emits telemetry
  saying how many boxes went UNMEASURED and why — `no_sha`, `rate_limited`,
  `unknown_commit`, `unreachable`, `unusable_body`, `write_failed` kept
  DISTINCT, never folded together. Without that report a fleet past ~60 boxes
  degrades to all-unknown in silence, and a blocked egress looks identical to
  an exhausted budget.

  Crash-safe: `refresh_update_status/1` never raises by contract (every failure
  lands `update_state: "unknown"` best-effort), and each instance is wrapped so
  ONE bad row can never sink the sweep. `max_attempts: 1` — a missed tick is
  harmless (the next hour's tick is identical), so Oban should not retry-storm
  a transient blip.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  require Logger

  alias BarkparkCloud.GitHub.CommitDistanceSweep
  alias BarkparkCloud.Registry

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"barkpark_id" => id}}) do
    case Registry.get_barkpark(id) do
      # Removed between enqueue and run — nothing to refresh.
      nil -> :ok
      bp -> sweep([bp])
    end
  end

  def perform(%Oban.Job{}) do
    sweep(Registry.update_checkable_barkparks())
  end

  # One CommitDistanceSweep per tick: the memo, the budget halt and the
  # unmeasured accounting all live for exactly this run and are torn down with
  # it. `after` runs even if the enumeration blows up, so the ETS table can
  # never outlive the job process's work.
  defp sweep(barkparks) do
    tick = CommitDistanceSweep.new()

    try do
      Enum.each(barkparks, &refresh(&1, tick))
      CommitDistanceSweep.report(tick)
    after
      CommitDistanceSweep.close(tick)
    end

    :ok
  end

  # refresh_update_status/1 already persists "unknown" on every failure and
  # never raises by contract; the rescue is the belt-and-braces backstop so one
  # pathological row never sinks the whole sweep.
  defp refresh(bp, tick) do
    _ = Registry.refresh_update_status(bp)

    # SECOND, and STRICTLY second (deploy-reliability W21). The mirror above is
    # the pre-existing contract and must be unaffected by anything here: this
    # arm runs AFTER it, is separately rescued, and its result is discarded, so
    # a GitHub outage, a rate-limit refusal or an exception cannot fail, skip or
    # reorder the update mirror. It re-reads the row so it grades the
    # `git_commit` the mirror write left behind rather than a stale struct.
    _ = grade_commit_distance(bp, tick)

    :ok
  rescue
    e ->
      Logger.error(
        "UpdateStatusWorker: refresh failed for #{inspect(bp.id)}: #{Exception.message(e)}"
      )

      :ok
  end

  # Once this tick has taken a 403 the shared anonymous budget is spent until
  # the hour rolls, so every remaining compare would be refused too. Skipping
  # them costs nothing and, crucially, does NOT overwrite their existing
  # verdict with `unknown` plus a fresh `commit_distance_checked_at` that would
  # claim we measured. They are counted under the rate-limited bucket instead.
  defp grade_commit_distance(bp, tick) do
    if CommitDistanceSweep.halted?(tick) do
      CommitDistanceSweep.skip(tick)
    else
      case Registry.get_barkpark(bp.id) do
        nil ->
          :ok

        fresh ->
          result = Registry.refresh_commit_distance(fresh, CommitDistanceSweep.client_opts(tick))
          CommitDistanceSweep.observe(tick, fresh.git_commit, result)
      end
    end
  rescue
    e ->
      Logger.error(
        "UpdateStatusWorker: commit distance failed for #{inspect(bp.id)}: #{Exception.message(e)}"
      )

      :ok
  end
end
