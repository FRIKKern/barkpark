defmodule BarkparkCloud.DeployLedger.DrainDistribution do
  @moduledoc """
  THE RE-TAKER for the post-regime deferral DRAIN distribution
  (dr-w13-bl-waiting-alert-population-is-empty, charter D190/D211(b)).

  ## Why this is a module and not a paragraph

  Wave 13 measured the drain and found a population of ZERO: not one publish had
  waited a full hour in the post-D179 regime, so the WAITING alert
  (`dr-w11-s5-waiting-alert`) was scoped against nothing. That finding is a claim
  about the WORLD, and a claim about the world ROTS. The wave's own recipe
  (`tooling/grip/ledger/post-regime-drain-stability-2026-08-07.md`) said as much:
  re-take the distribution at 24h and again at 72h past the regime boundary,
  because the tail is not demand-driven and can return without warning.

  A recipe is a document a human has to find, paste into `psql` on a box, and get
  right five times in a row. This module is the same five queries as ONE call, so
  the next reader MEASURES instead of QUOTING. That is the only honest way to
  ship an alert whose population is currently empty: not a threshold, a
  re-measurement.

  ## What it refuses to do

  It never carries wave 13's numbers as its own. `inherited_reading/0` returns
  them, every field labelled with the instant they were taken and the word
  `inherited` — they are somebody else's measurement at an earlier date, and a
  caller that prints them has printed history, not a reading.

  ## The five things the recipe insists on, all of them structural here

    1. **THE REGIME IS PINNED.** `regime_boundary/0` is the D179 rollback
       instant. A window that starts before it BLENDS two regimes whose p95 are
       45x apart, and the blended number describes neither.

    2. **CENSORING IS NAMED, NEVER DROPPED.** A deferral inserted 10 minutes
       before the query has not been observed for an hour, so it CANNOT be
       counted as a row that waited an hour — and it cannot be counted as one
       that did not, either. `:censor_seconds` (default one hour) fences those
       rows OUT of the sample and the summary reports them as
       `censored_recent`. Wave 13's eight "unserved" rows were all 0-17 minutes
       old: pure right-censoring, and a reader who saw only the eight would have
       read a returning tail.

    3. **THE UNIT IS NAMED.** Deferrals arrive about once a minute on the same
       site and all resolve at one live instant, so a single 42-minute wait
       contributes ~40 ROWS. Rows over-weight long waits. CHAIN HEADS (a gap
       over `:chain_gap_seconds` opens a new chain) count WAITING PUBLISHES.
       The recipe measured the same fleet 53% apart on this axis alone, so both
       units are computed and every rendered figure says which one it is.

    4. **THE CLOCK HAS TWO KEYS.** `:became_live_at` is the mark the fleet
       publishes; `:inserted_at` is when the covering build row was minted. They
       must agree in SHAPE — a divergence in SIGN is the alarm for a
       `became_live_at` backfill artifact. `:key` selects; `report/1` says which
       was used.

    5. **ELAPSED-SINCE-REGIME IS REPORTED.** Every wave-13 figure was taken
       12h13m after the boundary and the criterion asks for 24h and 72h.
       `regime_age_seconds` is in the summary so a reader can never mistake a
       12-hour window for a 24-hour one, and `report/1` says `WINDOW TOO YOUNG`
       below 24h rather than printing a verdict off it.

  ## The cause split, through the ledger's own classifier

  The recipe split causes with `failure_reason ILIKE '%box_at_capacity%'`. This
  module calls `DeployLedger.classify/1` instead — the SAME function the census
  uses — so the split cannot drift from the ledger's vocabulary and a row the
  classifier cannot name lands in `DEFERRED_UNCLASSIFIED` rather than in a
  silently-mislabelled bucket. The buckets are therefore the ledger's class
  names (`BOX_AT_CAPACITY_DEFERRED`, `BOX_BUSY_DEFERRED`,
  `DEFERRED_UNCLASSIFIED`), not the recipe's prose ones.

  ## The verdict

  `report/1` ends in a RULING, because the row this module was built for asks for
  one: either `no_live_1h` is zero over an uncensored sample and the population
  is still empty (an alert scoped here can never fire — charter D3's discipline
  from the other side), or it is not, and the report DERIVES a candidate
  threshold from the distribution it just took, naming its unit, its window and
  its regime. A threshold that did not come out of a live sample is not offered.
  """

  import Ecto.Query, warn: false

  alias BarkparkCloud.DeployLedger
  alias BarkparkCloud.Registry.Deployment
  alias BarkparkCloud.Repo

  # D179's rollback to `ef77af274`. Everything before this instant is a DIFFERENT
  # regime: the recipe measured pre-D179 p95 at 42,854s against post-D179 945s,
  # a 45x gap, so a window straddling it answers for neither side.
  @regime_boundary ~U[2026-08-06 22:19:52.000000Z]

  # The observation an hour-plus wait needs before it can be said not to have
  # happened. It is the SAME hour the WAITING alert would fire on, on purpose:
  # the censoring fence and the alert's threshold are the same quantity, and
  # letting them drift apart would let the instrument disagree with the alarm.
  @censor_seconds 3600

  # A gap over this opens a new chain. The recipe's value, kept because changing
  # it changes the UNIT and every historical chain figure with it.
  @chain_gap_seconds 300

  # 24h and 72h past the boundary — the two re-takes the row asks for, as data so
  # a caller can test its own window against them instead of re-deriving.
  @retake_marks [{"24h", 86_400}, {"72h", 259_200}]

  @type slice :: %{
          cause: binary(),
          n: non_neg_integer(),
          p50: float() | nil,
          p95: float() | nil,
          max: float() | nil,
          no_live_1h: non_neg_integer()
        }

  @type summary :: %{
          from: DateTime.t(),
          to: DateTime.t(),
          key: :became_live_at | :inserted_at,
          regime_boundary: DateTime.t(),
          regime_age_seconds: integer(),
          censor_seconds: pos_integer(),
          chain_gap_seconds: pos_integer(),
          population: map(),
          rows: [slice()],
          chains: [slice()]
        }

  @doc """
  The whole drain distribution over a pinned window, as data.

  Options:

    * `:from` — the window's lower bound. Defaults to `regime_boundary/0`, and a
      value EARLIER than it is accepted but reported: the summary's
      `straddles_regime?` is the machine-readable form of "this number blends two
      regimes".
    * `:to` — the window's upper bound AND the observation instant. Defaults to
      `DateTime.utc_now/0`. It is pinned into the summary so the same window
      answers the same way on every read.
    * `:censor_seconds` — how long a row must have been observed to enter the
      sample. Default one hour.
    * `:chain_gap_seconds` — the gap that opens a new chain. Default 300.
    * `:key` — `:became_live_at` (default) or `:inserted_at`.
    * `:site_id` — narrow to one site; `nil` (default) is the whole fleet.
  """
  @spec summarize(keyword()) :: summary()
  def summarize(opts \\ []) do
    from_at = Keyword.get(opts, :from, @regime_boundary)
    to_at = Keyword.get(opts, :to, DateTime.utc_now())
    censor = Keyword.get(opts, :censor_seconds, @censor_seconds)
    gap = Keyword.get(opts, :chain_gap_seconds, @chain_gap_seconds)
    key = Keyword.get(opts, :key, :became_live_at)
    site_id = Keyword.get(opts, :site_id)

    censor_edge = DateTime.add(to_at, -censor, :second)

    deferrals = deferrals(from_at, to_at, site_id)
    {uncensored, censored} = Enum.split_with(deferrals, &(DateTime.compare(&1.inserted_at, censor_edge) == :lt))

    marks = live_marks(uncensored, key, site_id)
    observed = uncensored |> mark_heads(gap) |> Enum.map(&observe(&1, marks, censor))
    heads = Enum.filter(observed, & &1.head?)

    %{
      from: from_at,
      to: to_at,
      key: key,
      site_id: site_id,
      regime_boundary: @regime_boundary,
      regime_age_seconds: DateTime.diff(to_at, @regime_boundary, :second),
      straddles_regime?: DateTime.compare(from_at, @regime_boundary) == :lt,
      censor_seconds: censor,
      chain_gap_seconds: gap,
      population: %{
        total: length(deferrals),
        uncensored: length(uncensored),
        censored_recent: length(censored),
        chains: length(heads),
        earliest: deferrals |> Enum.map(& &1.inserted_at) |> min_at(),
        latest: deferrals |> Enum.map(& &1.inserted_at) |> max_at()
      },
      rows: slices(observed),
      chains: slices(heads),
      retake_marks: @retake_marks
    }
  end

  @doc """
  The same window, RENDERED — the bytes an operator reads.

  Every figure carries its unit; the censored arm is a line of its own; and the
  last line is the RULING the WAITING alert is waiting for.
  """
  @spec report(keyword() | summary()) :: [binary()]
  def report(opts \\ [])
  def report(opts) when is_list(opts), do: opts |> summarize() |> report()

  def report(%{population: pop} = s) do
    [
      "DRAIN DISTRIBUTION — post-regime deferral wait",
      "  window        #{DateTime.to_iso8601(s.from)} → #{DateTime.to_iso8601(s.to)}",
      "  regime        D179 @ #{DateTime.to_iso8601(s.regime_boundary)} (#{age(s.regime_age_seconds)} old)#{straddle(s)}",
      "  scope         #{s.site_id || "whole fleet"}",
      "  clock key     #{s.key}",
      "  deferrals     #{pop.total} (#{pop.uncensored} uncensored, #{pop.censored_recent} censored: younger than #{age(s.censor_seconds)})",
      "  chains        #{pop.chains} heads (a gap over #{s.chain_gap_seconds}s opens one)"
    ] ++
      unit_lines("rows", s.rows) ++
      unit_lines("chains", s.chains) ++
      ["  ruling        #{ruling(s)}"]
  end

  @doc """
  The RULING this re-take supports, as one sentence.

  Three outcomes and no fourth: the window is too young to answer, the population
  is still empty, or a threshold is DERIVED from the sample just taken — naming
  its unit, its window and its regime, per charter D191.
  """
  @spec ruling(summary()) :: binary()
  def ruling(%{regime_age_seconds: age}) when age < 86_400,
    do:
      "WINDOW TOO YOUNG — #{age(age)} past the regime boundary; the row asks for 24h and 72h. No ruling."

  def ruling(%{population: %{uncensored: 0}}),
    do: "NO SAMPLE — every deferral in this window is censored or the window is empty. No ruling."

  def ruling(%{chains: chains} = s) do
    overall = Enum.find(chains, &(&1.cause == "ALL"))

    if overall.no_live_1h == 0 do
      "POPULATION EMPTY — 0 of #{overall.n} chain heads waited #{age(s.censor_seconds)} " <>
        "(p95 #{secs(overall.p95)}, max #{secs(overall.max)}). An alert scoped at " <>
        "#{age(s.censor_seconds)} cannot fire in this regime; it stays filed, not shipped."
    else
      "THRESHOLD DERIVABLE — #{overall.no_live_1h} of #{overall.n} chain heads waited " <>
        "#{age(s.censor_seconds)}. Candidate: p95 #{secs(overall.p95)} per CHAIN HEAD over " <>
        "#{DateTime.to_iso8601(s.from)}→#{DateTime.to_iso8601(s.to)}, post-D179 regime only."
    end
  end

  @doc "The D179 rollback instant every window here is pinned against."
  @spec regime_boundary() :: DateTime.t()
  def regime_boundary, do: @regime_boundary

  @doc "The two re-takes the row asks for, as `{label, seconds_past_boundary}`."
  @spec retake_marks() :: [{binary(), pos_integer()}]
  def retake_marks, do: @retake_marks

  @doc """
  Wave 13's reading, LABELLED AS INHERITED.

  It is here so a caller can print it BESIDE a fresh reading and see the drift —
  never instead of one. Every value is stamped with `taken_at` and the word
  `inherited`, because a number repeated without its date is a number presented
  as current.
  """
  @spec inherited_reading() :: map()
  def inherited_reading do
    %{
      provenance: "inherited",
      taken_at: ~U[2026-08-07 10:31:00Z],
      taken_by: "deploy-reliability wave 13 verify (hand SQL, not this module)",
      recipe: "tooling/grip/ledger/post-regime-drain-stability-2026-08-07.md",
      unit: "rows",
      key: :became_live_at,
      n: 1_110,
      p50: 212.4,
      p95: 949.1,
      max: 2_539.0,
      no_live_1h: 0,
      caveat:
        "taken 12h13m past the regime boundary, not the 24h the criterion asks for. Re-run summarize/1 before quoting any of it."
    }
  end

  # ── the fold ──────────────────────────────────────────────────────────────

  defp deferrals(from_at, to_at, site_id) do
    Deployment
    |> where([d], d.status == "deferred")
    |> where([d], d.environment == "production")
    |> where([d], d.inserted_at >= ^from_at and d.inserted_at < ^to_at)
    |> then(fn q -> if site_id, do: where(q, [d], d.site_id == ^site_id), else: q end)
    |> select([d], %{
      site_id: d.site_id,
      inserted_at: d.inserted_at,
      status: d.status,
      stage: d.stage,
      failure_reason: d.failure_reason,
      box_refusal_code: d.box_refusal_code
    })
    |> Repo.all()
    |> Enum.sort_by(&{&1.site_id, DateTime.to_unix(&1.inserted_at, :microsecond)})
  end

  # ONE covering query for the whole population, folded once — never one probe
  # per deferred row. Bounded on the LEFT only: a live build minted after the
  # window's `to` still covers a row inside it, and pretending otherwise would
  # manufacture waits that the fleet actually served.
  defp live_marks([], _key, _site_id), do: %{}

  defp live_marks(deferrals, key, site_id) do
    site_ids = deferrals |> Enum.map(& &1.site_id) |> Enum.uniq()
    earliest = deferrals |> Enum.map(& &1.inserted_at) |> Enum.min(DateTime)

    Deployment
    |> where([d], d.status == "live")
    |> where([d], d.environment == "production")
    |> where([d], d.site_id in ^site_ids)
    |> then(fn q -> if site_id, do: where(q, [d], d.site_id == ^site_id), else: q end)
    |> select([d], %{site_id: d.site_id, became_live_at: d.became_live_at, inserted_at: d.inserted_at})
    |> Repo.all()
    |> Enum.flat_map(fn row ->
      # A live row with a NULL `became_live_at` carries no mark under that key.
      # It is DROPPED from the marks, never defaulted to `inserted_at`: a
      # fallback would quietly make the two keys the same measurement and
      # destroy the cross-check they exist to be.
      case Map.fetch!(row, key) do
        nil -> []
        %DateTime{} = at -> if DateTime.compare(at, earliest) == :gt, do: [{row.site_id, at}], else: []
      end
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {site, stamps} -> {site, Enum.sort(stamps, DateTime)} end)
  end

  defp observe(row, marks, censor) do
    live =
      marks
      |> Map.get(row.site_id, [])
      |> Enum.find(&(DateTime.compare(&1, row.inserted_at) == :gt))

    seconds = live && DateTime.diff(live, row.inserted_at, :microsecond) / 1_000_000

    %{
      cause: DeployLedger.classify(row) || "DEFERRED_UNCLASSIFIED",
      seconds: seconds,
      # A row with NO covering mark at all is `no_live_1h` too: it has been
      # uncensored for at least an hour by construction (the censor fence
      # already removed everything younger) and it still has not been served.
      no_live_1h?: is_nil(seconds) or seconds > censor,
      head?: row.head?
    }
  end

  # CHAIN HEADS, the unit that counts WAITING PUBLISHES rather than waiting rows.
  # `deferrals/3` already sorted by `{site_id, inserted_at}`, so one pass with a
  # lag is enough: the first row of a site opens a chain, and so does any row
  # more than `gap` after its predecessor ON THE SAME SITE. Crossing a site
  # boundary must open a chain too, which is why the previous row's site is
  # compared and not only its instant.
  defp mark_heads(rows, gap) do
    rows
    |> Enum.reduce({[], nil}, fn row, {acc, prev} ->
      head? =
        case prev do
          nil -> true
          %{site_id: site} when site != row.site_id -> true
          %{inserted_at: at} -> DateTime.diff(row.inserted_at, at, :second) > gap
        end

      {[Map.put(row, :head?, head?) | acc], row}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp slices(observed) do
    by_cause = Enum.group_by(observed, & &1.cause)

    ([{"ALL", observed}] ++ Enum.sort_by(Map.to_list(by_cause), &(-length(elem(&1, 1)))))
    |> Enum.map(fn {cause, rows} ->
      served = rows |> Enum.map(& &1.seconds) |> Enum.reject(&is_nil/1) |> Enum.sort()

      %{
        cause: cause,
        n: length(rows),
        p50: percentile(served, 0.5),
        p95: percentile(served, 0.95),
        max: percentile(served, 1.0),
        no_live_1h: Enum.count(rows, & &1.no_live_1h?)
      }
    end)
  end

  # `percentile_cont` — linear interpolation between the bracketing ranks, the
  # SAME estimator the recipe's SQL uses. Nearest-rank would answer differently
  # on a small sample and the two readings could never be compared.
  defp percentile([], _q), do: nil
  defp percentile([one], _q), do: Float.round(one, 1)

  defp percentile(sorted, q) do
    pos = q * (length(sorted) - 1)
    lo = trunc(pos)
    hi = min(lo + 1, length(sorted) - 1)
    frac = pos - lo
    value = Enum.at(sorted, lo) * (1 - frac) + Enum.at(sorted, hi) * frac
    Float.round(value, 1)
  end

  # ── rendering ─────────────────────────────────────────────────────────────

  defp unit_lines(unit, slices) do
    ["  per #{unit}:"] ++
      Enum.map(slices, fn s ->
        "    #{pad(s.cause)} n=#{s.n} p50=#{secs(s.p50)} p95=#{secs(s.p95)} max=#{secs(s.max)} waited_1h=#{s.no_live_1h}"
      end)
  end

  defp pad(cause), do: String.pad_trailing(cause, 26)

  defp secs(nil), do: "n/a"
  defp secs(v), do: "#{:erlang.float_to_binary(v / 1, decimals: 1)}s"

  defp straddle(%{straddles_regime?: true}),
    do: " — WINDOW STRADDLES THE BOUNDARY: this blends two regimes"

  defp straddle(_), do: ""

  defp age(seconds) when seconds < 60, do: "#{seconds}s"
  defp age(seconds) when seconds < 3_600, do: "#{div(seconds, 60)}m"
  defp age(seconds), do: "#{div(seconds, 3_600)}h#{rem(div(seconds, 60), 60)}m"

  defp min_at([]), do: nil
  defp min_at(list), do: Enum.min(list, DateTime)
  defp max_at([]), do: nil
  defp max_at(list), do: Enum.max(list, DateTime)
end
