defmodule BarkparkCloud.Workers.UsageSamplerWorker do
  @moduledoc """
  cloud-console wave 3 — the fleet usage sampler. Every ~15 minutes (crontab
  `7,22,37,52`) it walks every checkable instance
  (`Registry.update_checkable_barkparks/0`: host set, not billing-suspended) and
  writes ONE cached `Usage.Sample` row per instance — the full `Usage.compose/1`
  envelope beside a real `measured_at`. `GET /v1/usage/summary` then answers the
  Overview fleet meter strip from those cached rows with ZERO instance HTTP, so
  the ~15s live `/usage` fan-out never blocks the fleet view.

  A LOST tick reports itself (dr-w26-bl…-sampler-tick). `Oban.Plugins.Cron`
  (OSS) only inserts for a minute a RUNNING node observes and never backfills,
  so a control-plane container replacement crossing `7,22,37,52` eats that tick
  and leaves no row anywhere — not `available`, not `discarded`. At the END of
  every sweep this worker hands the trailing window to
  `Usage.SamplerGaps.report/2`, which reconstructs the instants the crontab
  should have produced and logs one `usage_sampler_missed_tick` warning per
  hole. That turns "a gap in the series" — which by inspection is
  indistinguishable from a STOPPED worker — into an attributable event readable
  without ssh or a container-uptime read. It reports only; RECOVERING the lost
  measurement needs a guaranteed-cron engine or a catch-up producer, a charter
  D14 decision recorded as a residual in `SamplerGaps`' moduledoc.

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
  alias BarkparkCloud.Usage.SamplerGaps

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    swept =
      Registry.update_checkable_barkparks()
      |> Enum.reduce(0, fn bp, n ->
        sample(bp)
        n + 1
      end)

    # Report AFTER the sweep so this tick's own rows are on disk and can never
    # read as a hole. `swept` is passed through because an empty checkable fleet
    # writes no rows on ANY tick — reporting then would be noise about a fleet
    # that does not exist, so `report/2` stops on it.
    #
    # The accounting is RETURNED, not merely logged: `config/test.exs` pins the
    # primary Logger level to :warning, so a routine info line is invisible to a
    # test — and a wiring arm that can only grep a log it cannot see is a green
    # with no subject. Oban keeps a `{:ok, term}` return, so this is the same
    # value in production and under `perform_job/2`.
    {:ok, %{swept: swept, gaps: report_gaps(swept)}}
  end

  # Never let the reporter sink the sweep: the sampler's job is the samples, and
  # a gap report is diagnostics riding along. A failure here is logged and
  # swallowed exactly the way a pathological instance's sample is.
  defp report_gaps(swept) do
    result = SamplerGaps.report(DateTime.utc_now(), swept: swept)

    Logger.info(
      "usage_sampler_gaps swept=#{swept} reported=#{result.reported} " <>
        "reason=#{result.reason} expected=#{result.expected} " <>
        "missed=#{length(result.missed)}"
    )

    result
  rescue
    e ->
      Logger.error("UsageSamplerWorker: gap report failed: #{Exception.message(e)}")
      %{reported: false, reason: :report_raised, expected: 0, missed: []}
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
