defmodule BarkparkCloud.DeployLedger.DeferralPacing do
  @moduledoc """
  THE SCHEDULED-VS-ACTUAL READER for deferral chains
  (dr-bl-deferral-scheduled-vs-actual-gap).

  `Sites.Deploy.defer/3` records two seconds-valued columns on every deferral
  past the first round of its chain:

    * `deferral_scheduled_s`  — the window the backoff ladder ASKED for when the
      previous round of this chain re-queued its rebuild;
    * `deferral_actual_gap_s` — the gap that ACTUALLY elapsed,
      `inserted_at(this deferral) - inserted_at(the previous deferral)`.

  Both describe the same interval, so their ratio is a property of one row. This
  module is the reader that turns a pinned window of those rows into the one
  sentence the cap decision turns on:

    * ratio ~= 1.0 → the chain is CLOCK-paced. The lever is our OWN ladder:
      config, in fence, free.
    * ratio >> 1.0 → the wait is real contention on the box, and only then does
      the concurrency-cap experiment earn its 32 hours.

  ## The recorder ships with a reader, on purpose (charter D401-S3)

  A recorder with no human caller is the failure class this epic exists to
  delete. `report/1` returns rendered LINES — the same shape
  `DeployLedger.journey_report/1` returns — so a test can read the bytes an
  operator reads, not a map an operator never sees.

  ## THE LIMIT OF THE CLAIM

  These columns are NULL on every row written before this change, and they are
  never backfilled (the gap for a historical row is recoverable only by the hand
  SQL this module exists to retire). So the 61.6 s p50 / 2,262-deferral /
  55-75 s band figures from wave-23 Verify CANNOT be reproduced from these
  columns today — those rows carry NULL. What this module guarantees is that the
  SAME quantities, measured the SAME way (a difference of `inserted_at`), come
  out of ONE command going forward, with no hand SQL. `summarize/1` reports
  `unmeasured` beside `measured` so a caller can never mistake "no rows carry
  the fields yet" for "the gaps are zero".
  """

  import Ecto.Query, warn: false

  alias BarkparkCloud.Registry.Deployment
  alias BarkparkCloud.Repo

  # The band the wave-23 hand measurement found 1,441 of 2,262 gaps inside. It
  # is INCLUSIVE at both ends and it is a CONSTANT of the report, not of the
  # ladder: the report's job is to say whether today's chains still sit where
  # that measurement found them, which needs the same fence it used.
  @band_low 55
  @band_high 75

  @typedoc "One pinned-window summary of deferral pacing."
  @type summary :: %{
          from: DateTime.t(),
          to: DateTime.t(),
          site_id: binary() | nil,
          deferrals: non_neg_integer(),
          measured: non_neg_integer(),
          unmeasured: non_neg_integer(),
          p50_actual_gap_s: number() | nil,
          p50_scheduled_s: number() | nil,
          ratio: float() | nil,
          in_band: non_neg_integer(),
          below_band: non_neg_integer(),
          band: {pos_integer(), pos_integer()}
        }

  @doc """
  The pinned window's pacing, as data.

  Options:

    * `:from` / `:to` — the `inserted_at` window (required `:from`; `:to`
      defaults to now). Both are compared against the same column the historical
      measurement used.
    * `:site_id` — narrow to one site. `nil` (default) is the whole fleet.

  `deferrals` counts every deferral row in the window; `measured` counts the
  subset carrying BOTH pacing columns. They differ by exactly the rows that are
  depth 1 of their chain (no previous round, so no interval) plus every row
  written before the recorder landed — which is why the difference is REPORTED
  rather than silently divided away.
  """
  @spec summarize(keyword()) :: summary()
  def summarize(opts) do
    from_at = Keyword.fetch!(opts, :from)
    to_at = Keyword.get(opts, :to, DateTime.utc_now())
    site_id = Keyword.get(opts, :site_id)

    rows = pacing_rows(from_at, to_at, site_id)
    total = count_deferrals(from_at, to_at, site_id)

    actuals = Enum.map(rows, & &1.actual)
    scheduleds = Enum.map(rows, & &1.scheduled)

    p50_actual = percentile(actuals, 50)
    p50_scheduled = percentile(scheduleds, 50)

    %{
      from: from_at,
      to: to_at,
      site_id: site_id,
      deferrals: total,
      measured: length(rows),
      unmeasured: total - length(rows),
      p50_actual_gap_s: p50_actual,
      p50_scheduled_s: p50_scheduled,
      ratio: ratio(p50_actual, p50_scheduled),
      in_band: Enum.count(actuals, &(&1 >= @band_low and &1 <= @band_high)),
      below_band: Enum.count(actuals, &(&1 < @band_low)),
      band: {@band_low, @band_high}
    }
  end

  @doc """
  The same window, RENDERED — the bytes a human reads.

  Takes either the option list `summarize/1` takes or a summary it already
  produced, and returns a list of lines. It is the human surface of these two
  columns until the census wire carries them, and it states its own verdict
  rather than leaving the ratio for the reader to divide.
  """
  @spec report(keyword() | summary()) :: [binary()]
  def report(opts) when is_list(opts), do: opts |> summarize() |> report()

  def report(%{band: {low, high}} = s) do
    [
      "DEFERRAL PACING — scheduled window vs actual gap",
      "  window        #{DateTime.to_iso8601(s.from)} → #{DateTime.to_iso8601(s.to)}",
      "  scope         #{s.site_id || "whole fleet"}",
      "  deferrals     #{s.deferrals} (#{s.measured} measured, #{s.unmeasured} unmeasured)",
      "  p50 scheduled #{seconds(s.p50_scheduled_s)}",
      "  p50 actual    #{seconds(s.p50_actual_gap_s)}",
      "  ratio         #{ratio_text(s.ratio)}",
      "  band #{low}-#{high}s  #{s.in_band} inside, #{s.below_band} below",
      "  verdict       #{verdict(s.ratio, s.measured)}"
    ]
  end

  @doc "The band this report pins, as the pair the historical measurement used."
  @spec band() :: {pos_integer(), pos_integer()}
  def band, do: {@band_low, @band_high}

  # A ratio near 1.0 means our own ladder set the pace; well above it means the
  # box did. The verdict names the LEVER, because that is the decision the two
  # columns exist to settle — and it refuses to name one at all when nothing was
  # measured, rather than reading an empty window as "clock-paced".
  defp verdict(_ratio, 0), do: "NOT MEASURED — no deferral in this window carries both fields"
  defp verdict(nil, _measured), do: "NOT MEASURED — no scheduled window to compare against"

  defp verdict(ratio, _measured) when ratio <= 1.25,
    do: "CLOCK-PACED — the lever is our own backoff ladder (config, in fence)"

  defp verdict(ratio, _measured) when ratio <= 2.0,
    do: "MIXED — the ladder explains most of the wait, the box explains the rest"

  defp verdict(_ratio, _measured),
    do: "BOX-PACED — the wait is real contention; the concurrency-cap experiment earns its time"

  defp seconds(nil), do: "n/a"
  defp seconds(value), do: "#{Float.round(value / 1, 1)}s"

  defp ratio_text(nil), do: "n/a"
  defp ratio_text(ratio), do: "#{Float.round(ratio, 2)}× actual/scheduled"

  defp ratio(_actual, nil), do: nil
  defp ratio(nil, _scheduled), do: nil
  defp ratio(_actual, 0), do: nil
  defp ratio(actual, scheduled), do: actual / scheduled

  # The pinned-window scan. Both columns must be present: a row carrying one
  # without the other cannot contribute to a ratio, and quietly counting it on
  # one side would tilt exactly the comparison this report exists to make.
  defp pacing_rows(from_at, to_at, site_id) do
    Deployment
    |> where([d], d.status == "deferred")
    |> where([d], d.inserted_at >= ^from_at and d.inserted_at <= ^to_at)
    |> where([d], not is_nil(d.deferral_scheduled_s) and not is_nil(d.deferral_actual_gap_s))
    |> scoped(site_id)
    |> select([d], %{scheduled: d.deferral_scheduled_s, actual: d.deferral_actual_gap_s})
    |> Repo.all()
  end

  defp count_deferrals(from_at, to_at, site_id) do
    Deployment
    |> where([d], d.status == "deferred")
    |> where([d], d.inserted_at >= ^from_at and d.inserted_at <= ^to_at)
    |> scoped(site_id)
    |> select([d], count(d.id))
    |> Repo.one()
  end

  defp scoped(query, nil), do: query
  defp scoped(query, site_id), do: where(query, [d], d.site_id == ^site_id)

  # The NEAREST-RANK percentile, which is what the hand measurement's
  # `percentile_disc` computed — an interpolating variant would report a gap no
  # deferral ever had, and the whole point is that the recorded field and the
  # historical figure are the same quantity.
  defp percentile([], _p), do: nil

  defp percentile(values, p) do
    sorted = Enum.sort(values)
    index = max(ceil(length(sorted) * p / 100) - 1, 0)
    Enum.at(sorted, index)
  end
end
