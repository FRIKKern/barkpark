defmodule BarkparkCloud.Usage.SamplerGaps do
  @moduledoc """
  dr-w26-bl-cp-deploy-eats-a-scheduled-sampler-tick — make a DROPPED sampler
  tick report itself, from inside the app, on the next tick.

  ## The mechanism this exists for

  `Oban.Plugins.Cron` (OSS, the one `cloud/config/config.exs` configures) is a
  self-re-arming per-minute loop inside a RUNNING node — the PLUGIN's own clock,
  in the dependency, not anything this app arms: on each evaluate it asks
  `Expression.now?/2` of the wall clock it holds *right then* and inserts the
  matching jobs, then schedules itself for the next minute boundary. It keeps no
  cursor and never backfills. So a minute no node was up for is not a late tick
  — it is a tick that never existed. `UsageSamplerWorker` runs
  `max_attempts: 1`, so the loss leaves **no row anywhere**: not `available`,
  not `retryable`, not `discarded`. The only trace is a hole in the
  `usage_samples` series, and a hole is indistinguishable by inspection from a
  STOPPED worker.

  A control-plane container replacement crossing a cron boundary is the routine
  way to lose one (2026-08-08: `23:22 / 23:37 / [NOTHING] / 00:07 / 00:22`,
  `UsageSamplerWorker` 664 completed / 1 discarded).

  ## What this module does — and what it deliberately does NOT

  It **reports**. It reconstructs the tick instants the crontab *should* have
  produced across a trailing window, checks each against the `usage_samples`
  rows actually on disk, and logs one `usage_sampler_missed_tick` warning per
  hole. That makes the loss attributable from journald/Sentry with no ssh and
  no container-uptime read.

  It does **not** recover the lost measurement. Closing the cause needs either a
  guaranteed-cron engine (Oban Pro `DynamicCron`) or a catch-up producer — a
  charter D14 decision, recorded as a residual here and in
  `daily_digest_worker.ex`, not a builder's call.

  ## Why the expected minutes are DERIVED, never written down twice

  `cron_minutes/0` reads the live `Oban` crontab out of the application
  environment and parses the minute field of whatever expression is bound to
  `UsageSamplerWorker`. Re-spelling `7,22,37,52` here would make a cadence
  change silently produce false holes — the failure mode is the one the row is
  about. No crontab entry for the worker → `{:error, :unscheduled}`, and the
  reporter stays SILENT: an unscheduled worker has no ticks to miss.

  ## Coverage rule

  A tick `T` is COVERED iff some sample's `measured_at` falls in `[T, N)`, where
  `N` is the next expected tick (or the window end for the last one). The lower
  bound is exact and needs no grace: the job is inserted by a node at the minute
  boundary and `Usage.record_sample/1` stamps `DateTime.utc_now()` on the same
  node strictly afterwards, so a sample can never precede the tick that produced
  it. The upper bound is the next tick because a sweep that has not finished by
  then is a LATE tick, which is a different (and visible) fault.
  """

  import Ecto.Query

  require Logger

  alias BarkparkCloud.Repo
  alias BarkparkCloud.Usage.Sample
  alias BarkparkCloud.Workers.UsageSamplerWorker

  # Two 15-minute intervals plus a minute of slack. Short on purpose: the window
  # bounds how many times one hole is re-reported (twice, then it ages out), so
  # the warning stays an event rather than a standing siren.
  @lookback_ms :timer.minutes(31)

  @doc "The trailing window `report/2` reads, in milliseconds."
  @spec lookback_ms() :: pos_integer()
  def lookback_ms, do: @lookback_ms

  @doc """
  The minutes-of-the-hour `UsageSamplerWorker` is scheduled for, read from the
  LIVE Oban crontab. `{:error, :unscheduled}` when no crontab entry names the
  worker (or the Cron plugin is absent), which is the honest "nothing to miss".
  """
  @spec cron_minutes(module()) :: {:ok, [0..59]} | {:error, :unscheduled}
  def cron_minutes(worker \\ UsageSamplerWorker) do
    :barkpark_cloud
    |> Application.get_env(Oban, [])
    |> Keyword.get(:plugins, [])
    |> Enum.flat_map(fn
      {Oban.Plugins.Cron, opts} -> Keyword.get(opts, :crontab, [])
      _ -> []
    end)
    |> Enum.flat_map(fn
      {expr, ^worker} -> parse_minutes(expr)
      {expr, ^worker, _opts} -> parse_minutes(expr)
      _ -> []
    end)
    |> Enum.uniq()
    |> Enum.sort()
    |> case do
      [] -> {:error, :unscheduled}
      minutes -> {:ok, minutes}
    end
  end

  @doc """
  The minute field of a 5-field cron expression, expanded to a sorted list.
  Supports `*`, `*/n`, `a`, `a-b`, `a-b/n` and comma lists of those. Anything
  else expands to `[]` — an unparsed expression must never manufacture holes.
  """
  @spec parse_minutes(String.t()) :: [0..59]
  def parse_minutes(expr) when is_binary(expr) do
    case String.split(expr, ~r/\s+/, trim: true) do
      [minute_field | _rest] -> expand_field(minute_field)
      _ -> []
    end
  end

  def parse_minutes(_), do: []

  defp expand_field(field) do
    field
    |> String.split(",", trim: true)
    |> Enum.flat_map(&expand_term/1)
    |> Enum.filter(&(&1 in 0..59))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp expand_term(term) do
    {base, step} =
      case String.split(term, "/", parts: 2) do
        [base, step] -> {base, to_int(step)}
        [base] -> {base, 1}
      end

    case {base, step} do
      {_, nil} -> []
      {_, s} when s < 1 -> []
      {"*", s} -> Enum.take_every(0..59, s)
      {b, s} -> expand_range(b, s)
    end
  end

  defp expand_range(base, step) do
    case String.split(base, "-", parts: 2) do
      [from, to] ->
        case {to_int(from), to_int(to)} do
          {f, t} when is_integer(f) and is_integer(t) and f <= t -> Enum.take_every(f..t, step)
          _ -> []
        end

      [single] ->
        case to_int(single) do
          nil -> []
          n -> [n]
        end
    end
  end

  defp to_int(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  @doc """
  Every tick instant the crontab should have produced in `[from, to)`, oldest
  first. Walks the window minute by minute (≤ 31 iterations at the default
  lookback) and keeps the minutes the expression selects — generic over whatever
  `cron_minutes/0` returns, so a cadence change needs no edit here.
  """
  @spec expected_ticks(DateTime.t(), DateTime.t()) ::
          {:ok, [DateTime.t()]} | {:error, :unscheduled}
  def expected_ticks(from, to) do
    with {:ok, minutes} <- cron_minutes() do
      {:ok,
       from
       |> floor_to_minute()
       |> Stream.iterate(&DateTime.add(&1, 60, :second))
       |> Stream.take_while(&(DateTime.compare(&1, to) == :lt))
       |> Stream.filter(&(DateTime.compare(&1, from) != :lt))
       |> Stream.filter(&(&1.minute in minutes))
       |> Enum.to_list()}
    end
  end

  @doc """
  The expected ticks in `[from, to)` with NO `usage_samples` row covering them.

  The read is bounded on BOTH sides by the caller's window — never a whole-table
  scan — and selects only `measured_at`, so a fleet of any size costs one narrow
  index range read.
  """
  @spec missed(DateTime.t(), DateTime.t()) :: {:ok, [DateTime.t()]} | {:error, :unscheduled}
  def missed(from, to) do
    with {:ok, ticks} <- expected_ticks(from, to) do
      measured = measured_at_in_window(from, to)
      {:ok, Enum.filter(ticks, &(not covered?(&1, ticks, to, measured)))}
    end
  end

  defp measured_at_in_window(from, to) do
    from(s in Sample,
      where: s.measured_at >= ^from and s.measured_at < ^to,
      select: s.measured_at,
      order_by: [asc: s.measured_at]
    )
    |> Repo.all()
  end

  # Covered iff a sample lands in [tick, next_tick) — see the moduledoc's
  # coverage rule for why neither bound carries a fudge factor.
  defp covered?(tick, ticks, window_end, measured) do
    upper =
      Enum.find(ticks, window_end, &(DateTime.compare(&1, tick) == :gt))

    Enum.any?(measured, fn at ->
      DateTime.compare(at, tick) != :lt and DateTime.compare(at, upper) == :lt
    end)
  end

  @doc """
  Read the trailing window and REPORT: one `usage_sampler_missed_tick` warning
  per hole, and an accounting map either way.

  `:swept` is the number of instances the caller's sweep just sampled. **Zero is
  a hard stop**: an empty checkable fleet writes no rows on ANY tick, so every
  expected instant would read as missed and the warning would be pure noise
  about a fleet that does not exist. That guard is a control, not an
  optimisation — it is the difference between "a tick was eaten" and "there is
  nothing to sample".

  Returns `%{reported: boolean, reason: atom | nil, expected: n, missed: [DateTime]}`.
  Total: never raises out of the sampler's own `perform/1`.
  """
  @spec report(DateTime.t(), keyword()) :: %{
          reported: boolean(),
          reason: atom() | nil,
          expected: non_neg_integer(),
          missed: [DateTime.t()]
        }
  def report(now, opts \\ []) do
    swept = Keyword.get(opts, :swept, 0)
    window_start = DateTime.add(now, -@lookback_ms, :millisecond)

    cond do
      swept <= 0 ->
        quiet(:no_checkable_instances)

      true ->
        case missed(window_start, now) do
          {:error, :unscheduled} ->
            quiet(:unscheduled)

          {:ok, missed} ->
            {:ok, ticks} = expected_ticks(window_start, now)
            log_missed(missed, ticks, window_start, now)
            %{reported: true, reason: nil, expected: length(ticks), missed: missed}
        end
    end
  end

  defp quiet(reason), do: %{reported: false, reason: reason, expected: 0, missed: []}

  defp log_missed(missed, ticks, window_start, window_end) do
    Enum.each(missed, fn tick ->
      Logger.warning(
        "usage_sampler_missed_tick at=#{DateTime.to_iso8601(tick)} " <>
          "window_start=#{DateTime.to_iso8601(window_start)} " <>
          "window_end=#{DateTime.to_iso8601(window_end)} " <>
          "expected=#{length(ticks)} missed=#{length(missed)} " <>
          "cause=no_node_observed_the_cron_minute " <>
          "note=a_missing_row_here_is_a_LOST_TICK_not_a_stopped_worker"
      )
    end)
  end

  defp floor_to_minute(dt), do: %{dt | second: 0, microsecond: {0, 0}}
end
