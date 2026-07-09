defmodule BarkparkCloud.Workers.UsageSamplerWorker do
  @moduledoc """
  cloud-console wave 3 — the fleet usage sampler. Every ~15 minutes (crontab
  `7,22,37,52`) it walks every checkable instance
  (`Registry.update_checkable_barkparks/0`: host set, not billing-suspended) and
  writes ONE cached `Usage.Sample` row per instance — the full `Usage.compose/1`
  envelope beside a real `measured_at`. `GET /v1/usage/summary` then answers the
  Overview fleet meter strip from those cached rows with ZERO instance HTTP, so
  the ~15s live `/usage` fan-out never blocks the fleet view.

  A row is written on EVERY tick, even for a DOWN box: `Usage.gather/1` degrades
  the instance-sourced meters to "unmetered" (never a fake zero) while the
  control-plane meters (seats) still carry truth, and `measured_at` is always a
  real timestamp — so the console can honestly stamp "as of Xs ago" for any box.

  Per-instance ISOLATION: each sample is wrapped so one pathological box (a raise
  in gather, an insert failure) can never sink the whole sweep. `max_attempts: 1`
  — a missed tick is harmless (the next 15-minute tick re-samples), so Oban must
  not retry-storm a transient blip.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  require Logger

  alias BarkparkCloud.{Registry, Usage}

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Registry.update_checkable_barkparks()
    |> Enum.each(&sample/1)

    :ok
  end

  # `record_sample/1` gathers (fail-soft per meter) + inserts. The rescue is the
  # belt-and-braces backstop so one pathological row never sinks the sweep.
  defp sample(bp) do
    _ = Usage.record_sample(bp)
    :ok
  rescue
    e ->
      Logger.error(
        "UsageSamplerWorker: sample failed for #{inspect(bp.id)}: #{Exception.message(e)}"
      )

      :ok
  end
end
