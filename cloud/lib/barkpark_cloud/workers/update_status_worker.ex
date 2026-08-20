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

  Crash-safe: `refresh_update_status/1` never raises by contract (every failure
  lands `update_state: "unknown"` best-effort), and each instance is wrapped so
  ONE bad row can never sink the sweep. `max_attempts: 1` — a missed tick is
  harmless (the next hour's tick is identical), so Oban should not retry-storm
  a transient blip.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  require Logger

  alias BarkparkCloud.Registry

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"barkpark_id" => id}}) do
    case Registry.get_barkpark(id) do
      # Removed between enqueue and run — nothing to refresh.
      nil -> :ok
      bp -> refresh(bp)
    end
  end

  def perform(%Oban.Job{}) do
    Registry.update_checkable_barkparks()
    |> Enum.each(&refresh/1)

    :ok
  end

  # refresh_update_status/1 already persists "unknown" on every failure and
  # never raises by contract; the rescue is the belt-and-braces backstop so one
  # pathological row never sinks the whole sweep.
  defp refresh(bp) do
    _ = Registry.refresh_update_status(bp)

    # SECOND, and STRICTLY second (deploy-reliability W21). The mirror above is
    # the pre-existing contract and must be unaffected by anything here: this
    # arm runs AFTER it, is separately rescued, and its result is discarded, so
    # a GitHub outage, a rate-limit refusal or an exception cannot fail, skip or
    # reorder the update mirror. It re-reads the row so it grades the
    # `git_commit` the mirror write left behind rather than a stale struct.
    _ = grade_commit_distance(bp)

    :ok
  rescue
    e ->
      Logger.error(
        "UpdateStatusWorker: refresh failed for #{inspect(bp.id)}: #{Exception.message(e)}"
      )

      :ok
  end

  defp grade_commit_distance(bp) do
    case Registry.get_barkpark(bp.id) do
      nil -> :ok
      fresh -> Registry.refresh_commit_distance(fresh)
    end
  rescue
    e ->
      Logger.error(
        "UpdateStatusWorker: commit distance failed for #{inspect(bp.id)}: #{Exception.message(e)}"
      )

      :ok
  end
end
