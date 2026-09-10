defmodule BarkparkCloud.DeployLedger.BuildClock do
  @moduledoc """
  The build clock's READER — deploy-reliability W12, charter D180.

  The measurement already exists and nothing reads it: every deployment's
  `console` array carries a per-stage `at` timestamp (`PLAN|BUILD|STAGE|HEALTH|
  SWITCH|RETIRE` x `started|done|failed`, written by
  `BarkparkCloud.Sites.Deploy.console_entry/1`). There is no build-duration
  COLUMN and there never needs to be one. This module folds those timestamps
  into a build-duration distribution.

  ## THE TRAP THIS MODULE EXISTS TO NOT FALL INTO

  The console `BUILD started → done` interval is **NOT compile time**. It
  INCLUDES the fleet build-slot queue wait, because the engine emits the
  `started` line BEFORE it queues for the slot:

      deploy/site-deploy-node.sh:2997   emit BUILD started
      deploy/site-deploy-node.sh:3015   if ! build_gate_acquire; then
      deploy/site-deploy.sh:3494        emit BUILD started
      deploy/site-deploy.sh:3510        if ! build_gate_acquire; then

  (Re-derive with `git grep -n 'emit BUILD started\\|build_gate_acquire' -- deploy/`;
  the line numbers move, the ORDER is the invariant.)

  So on a `BUILD_GATE_SLOTS=1` box, a build that sat behind another site's
  compile reports the other site's compile time as its own. On the 2026-08-07
  cohort the naive all-rows median was 79.3s against a true un-overlapped
  compile median of 28.7s (p95 90.1s, max 263.2s, n=461) — the inflation that
  cost a verifier a false finding, and the same inflation that made six
  apparently concurrent builds on a one-slot box look like a broken gate when
  it was the first-ever measurement of slot QUEUE DEPTH.

  Those figures are the 2026-08-07 CONTEXT, not constants: nothing here
  hard-codes them.

  ## WHICH INTERVAL EACH NUMBER IS

  `report/2` never returns a bare "build duration". It returns BOTH series,
  each named for what it contains, and a `:measured` key naming the one the
  reader stands behind:

    * `:compile_ms` — **un-overlapped**. Queue wait REMOVED. This is
      `:measured`.
    * `:console_interval_ms` — the naive `started → done` span, queue wait
      INCLUDED. Published so the trap is visible rather than absent.
    * `:queue_wait_ms` — the difference, i.e. slot contention itself. Its
      non-zero tail IS the slot queue-depth signal.

  ## HOW THE QUEUE WAIT IS REMOVED (no new instrumentation)

  Nothing on the wire records the acquire moment — `BUILD_GATE_WAIT` reaches a
  console only inside a FAILED gate's detail string, and the box's journald
  retention is minutes (every `cloud/**` merge recreates the container), so a
  log-based census is structurally unavailable. The reader is therefore DB-side
  and reconstructs the acquire moment from the gate's own contract instead:

      one box, N slots  =>  at most N builds compile at once

  Sort a box's BUILD intervals by start; a build cannot begin compiling before
  a slot frees, so its compile starts at `max(own_start, earliest_free_slot)`.
  Everything before that is queue wait. With `slots: 1` this is plain
  serialisation. This is a MODEL of the gate, not a stamp from it: it attributes
  every overlap to the gate, so it is a LOWER bound on compile time and an
  UPPER bound on queue wait. A box whose gate failed open (see
  `build_gate_acquire`'s fail-open branches) genuinely ran concurrent builds,
  and there this model under-reports compile. That is stated, not hidden.

  `claimed_at` is NEVER used: it is written at COMPLETION (max gap to
  `became_live_at` 16.9s over 10,232 rows), so it cannot carry queue math.

  ## SCOPE OF THE INPUT

  The gate is PER BOX, so `report/2` must be handed ONE box's consoles. Mixing
  boxes invents contention that never happened and would inflate the queue-wait
  series — the exact error in the other direction.
  """

  @stage "BUILD"

  @type interval :: %{start_ms: integer(), end_ms: integer()}
  @type summary :: %{
          n: non_neg_integer(),
          p50: integer() | nil,
          p95: integer() | nil,
          max: integer() | nil
        }

  @doc """
  Every cleanly-paired `BUILD started → done` span across `consoles`, as
  `%{start_ms:, end_ms:}`, sorted by start.

  These are the NAIVE spans: each one still includes its queue wait.

  Pairing and timestamp parsing mirror `Registry.deploy_stage_estimates_from_consoles/1`
  (`cloud/lib/barkpark_cloud/registry.ex`, `paired_stage_durations/1` +
  `console_ms/1` — both private there, so the minimal parse is copied rather
  than the module edited; `build_clock_test.exs` pins the two agree on one
  fixture). Contract, verbatim from that source: a `started`/`running` opens an
  attempt, the next `done` closes exactly that one, a `failed`/`skipped`
  discards it, a re-open supersedes an unclosed attempt, and a pair that comes
  out negative is DROPPED rather than clamped.
  """
  @spec build_intervals([list()], keyword()) :: [interval()]
  def build_intervals(consoles, opts \\ []) when is_list(consoles) do
    stage = Keyword.get(opts, :stage, @stage)

    consoles
    |> Enum.flat_map(&paired_intervals(&1, stage))
    |> Enum.sort_by(& &1.start_ms)
  end

  @doc """
  The build-duration report for ONE box's `consoles`.

  Options: `:slots` (default `1`, the box's `BUILD_GATE_SLOTS`) and `:stage`
  (default `"BUILD"`).

  The `:measured` key names the interval the reader stands behind
  (`:compile_excluding_queue_wait`); `:reading` says the same thing in one
  sentence for a human. `:inflation` is
  `console_interval p50 / compile p50` — the trap's size on THIS cohort,
  computed, never assumed.
  """
  @spec report([list()], keyword()) :: map()
  def report(consoles, opts \\ []) when is_list(consoles) do
    slots = Keyword.get(opts, :slots, 1)
    stage = Keyword.get(opts, :stage, @stage)
    intervals = build_intervals(consoles, stage: stage)
    split = unoverlap(intervals, slots)

    naive = Enum.map(intervals, &(&1.end_ms - &1.start_ms))
    compile = Enum.map(split, & &1.compile_ms)
    waits = Enum.map(split, & &1.queue_wait_ms)

    %{
      measured: :compile_excluding_queue_wait,
      stage: stage,
      slots: slots,
      deployments: length(consoles),
      compile_ms: summarize(compile),
      console_interval_ms: summarize(naive),
      queue_wait_ms: summarize(waits),
      inflation: inflation(summarize(naive).p50, summarize(compile).p50),
      reading: reading(stage, slots)
    }
  end

  @doc """
  Per-interval split into compile and queue wait, oldest first — the
  distribution's raw rows, for a caller that wants them instead of percentiles.

  Each row is `%{start_ms:, end_ms:, compile_ms:, queue_wait_ms:}` and
  `compile_ms + queue_wait_ms == end_ms - start_ms` holds for every row.
  """
  @spec unoverlap([interval()], pos_integer()) :: [map()]
  def unoverlap(intervals, slots \\ 1) when is_list(intervals) and slots >= 1 do
    intervals
    |> Enum.sort_by(& &1.start_ms)
    |> Enum.map_reduce(List.duplicate(0, slots), fn interval, free ->
      %{start_ms: s, end_ms: e} = interval
      span = e - s
      [earliest | rest] = Enum.sort(free)

      # THE ONE LINE THAT EXCLUDES THE QUEUE WAIT. Drop the `max(…, earliest)`
      # and this reader silently becomes the naive 4.2x-inflated one again;
      # `build_clock_test.exs` reds on exactly that mutation.
      compile_start = max(s, earliest)

      wait = min(span, max(compile_start - s, 0))
      compile = span - wait

      row = %{start_ms: s, end_ms: e, compile_ms: compile, queue_wait_ms: wait}
      {row, [max(e, earliest) | rest]}
    end)
    |> elem(0)
  end

  @doc "The sentence a human reads: which interval was measured, and why the other one exists."
  @spec reading(binary(), pos_integer()) :: binary()
  def reading(stage \\ @stage, slots \\ 1) do
    "measured=compile_excluding_queue_wait: `compile_ms` is the #{stage} stage's " <>
      "console started→done span with the fleet build-slot queue wait REMOVED " <>
      "(#{slots} slot(s), un-overlapped per box). `console_interval_ms` is the raw " <>
      "started→done span and INCLUDES that wait — the engine emits `#{stage} started` " <>
      "before `build_gate_acquire`, so it is not compile time and must not be " <>
      "reported as one."
  end

  # --- pairing (mirrors registry.ex's private fold; see @moduledoc) -----------

  defp paired_intervals(console, stage) when is_list(console) do
    {_open, pairs} =
      Enum.reduce(console, {nil, []}, fn entry, {open, pairs} ->
        entry_stage = console_value(entry, "stage")
        status = console_value(entry, "status")
        at = console_ms(console_value(entry, "at"))

        cond do
          entry_stage != stage or is_nil(at) ->
            {open, pairs}

          status in ["running", "started"] ->
            {at, pairs}

          status == "done" and is_integer(open) and at - open >= 0 ->
            {nil, [%{start_ms: open, end_ms: at} | pairs]}

          status == "done" ->
            {nil, pairs}

          status in ["failed", "skipped"] ->
            {nil, pairs}

          true ->
            {open, pairs}
        end
      end)

    Enum.reverse(pairs)
  end

  defp paired_intervals(_, _), do: []

  defp console_value(entry, key) when is_map(entry) do
    case Map.fetch(entry, key) do
      {:ok, v} -> v
      :error -> Map.get(entry, safe_atom(key))
    end
  end

  defp console_value(_, _), do: nil

  defp safe_atom("stage"), do: :stage
  defp safe_atom("status"), do: :status
  defp safe_atom("at"), do: :at

  defp console_ms(%DateTime{} = dt), do: DateTime.to_unix(dt, :millisecond)

  defp console_ms(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, dt, _} -> DateTime.to_unix(dt, :millisecond)
      _ -> nil
    end
  end

  defp console_ms(_), do: nil

  # --- summary ---------------------------------------------------------------

  defp summarize([]), do: %{n: 0, p50: nil, p95: nil, max: nil}

  defp summarize(values) do
    sorted = Enum.sort(values)

    %{
      n: length(sorted),
      p50: percentile(sorted, 0.5),
      p95: percentile(sorted, 0.95),
      max: List.last(sorted)
    }
  end

  # Nearest-rank, byte-for-byte the rule in `Registry`'s private `percentile/2`,
  # so the two readers cannot drift on the same sample set.
  defp percentile(sorted, p) do
    n = length(sorted)
    Enum.at(sorted, min(n - 1, max(trunc(p * n), 0)))
  end

  defp inflation(_naive, nil), do: nil
  defp inflation(_naive, 0), do: nil
  defp inflation(nil, _compile), do: nil
  defp inflation(naive, compile), do: Float.round(naive / compile, 2)
end
