defmodule BarkparkCloud.Workers.UpdateStatusWorker do
  @moduledoc """
  isu-6 — the hourly self-update status sweep. Each live instance is the SOURCE
  OF TRUTH for its own update availability (it knows its own upstream/fork), so
  this worker never computes a verdict: it asks each instance
  (`Registry.refresh_update_status/1` → `GET /v1/admin/self-update` with the
  stored admin token, server-side) and mirrors the answer onto the row the
  fleet dashboard reads.

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
    :ok
  rescue
    e ->
      Logger.error(
        "UpdateStatusWorker: refresh failed for #{inspect(bp.id)}: #{Exception.message(e)}"
      )

      :ok
  end
end
