defmodule Mix.Tasks.Barkpark.Sheets.Bench do
  @shortdoc "Log-log complexity sweep for the Sheets recompute engine"

  @moduledoc """
  A controlled complexity benchmark for `Barkpark.Plugins.Sheets.Engine.recompute/1`.

  The engine documents itself (engine.ex §Complexity) as ONE topological pass
  (Kahn) over the formula-dependency graph — **O(cells + edges)**. A wall-clock
  threshold test cannot tell a linear engine from a quadratic one; only a fitted
  exponent across a size ladder can. This task fits that exponent.

  ## Why a Mix task and not a `:bench`-tagged ExUnit file

  Three reasons, all about a stranger being able to re-run this:

    1. **Arguments.** A sweep is only useful when you can move the ladder and
       the shape (`--shapes chain --sizes 500,1000,2000,4000`). ExUnit takes no
       arguments, so a tagged test file hard-codes one experiment; the next
       person edits the file to ask a different question, and the answer stops
       being comparable to yours.
    2. **A tagged test is invisible.** `@tag :bench` excluded by default means
       `mix test` never runs it, nobody sees output, and it silently rots. A
       Mix task is discoverable (`mix help | grep sheets`) and prints a table.
    3. **Separation of duties.** The *guard* belongs in ExUnit —
       `test/barkpark/sheets/engine_perf_test.exs` owns the wall-clock ceiling
       and the range-index regression lock, and runs on every push. The
       *measurement* belongs here. Mixing them produces a test that is either
       too slow for CI or too small to fit an exponent.

  ## Protocol

  Every number below is produced the same way, because an uncontrolled
  benchmark measures the runner, not the engine:

    * **Fixed graph shape per sweep.** Each shape holds the formula-graph
      topology constant and grows only `n`, so the fitted exponent describes
      the engine and not a fixture that got structurally denser with size.
    * **Warmup.** `--warmup` (default 1) untimed recomputes per size, discarded.
      The first run of a size pays lazy-literal/atom/binary allocation that has
      nothing to do with complexity.
    * **Median of N.** `--runs` (default 7) timed runs, median reported. The
      median rejects a scheduler spike in a way a mean cannot; the min would
      hide a genuine regression that is present in every run.
    * **Reductions, as the PRIMARY instrument.** Wall clock on a shared
      developer machine is not a controlled quantity: a burst of contention
      landing inside one rung's measurement block moves that rung's number and
      therefore BOTH exponents adjacent to it, in whichever direction the burst
      happened to fall. A reduction count is a deterministic function of the
      work performed — it does not move with CPU speed, other processes, or GC
      timing — so `Mreds` and `k_red` say what the ALGORITHM does while `ms` and
      `k_ms` say what this machine felt. When the two disagree, `k_red` is the
      measurement and `k_ms` is the weather. One probe per size is enough
      precisely because it is deterministic.
    * **GC between runs.** `:erlang.garbage_collect/0` before every timed run,
      so one size's garbage is never charged to the next run's clock.
    * **Geometric ladder.** Sizes double by default, so `log(t2/t1)/log(n2/n1)`
      is a clean *local* exponent per step rather than a single global fit that
      averages a linear head with a quadratic tail into a meaningless ~1.4.
    * **Build cost excluded from nothing.** The timed region is exactly
      `Engine.recompute/1` on a pre-built document; document construction
      happens once, outside the clock.

  ## Shapes

  Linear-by-construction (total evaluation work is O(n) — the engine's own
  contract says these must come out at k ≈ 1.0):

    * `independent` — `B_r = A_r*2+1` over literal `A_r`. No formula→formula
      edges, no ranges. The floor: parse + evaluate + write-back only.
    * `chain`      — `B_1 = A_1+1`, `B_r = B_{r-1}+A_r`. n−1 edges, depth n.
      The deepest possible topological order.
    * `window`     — `L_r = SUM(A_r:J_r)` over a FIXED 10-column literal block.
      n ranges, each covering a constant 10 cells and ZERO formula cells.
      Total real work O(n). This is the shape the original ledger measurement
      used, and the one that exposes the defect.
    * `fanin`      — `C_r = SUM($A$1:$A$50)`: n formulas, all reading the SAME
      constant-size literal range. Work O(n).

  Quadratic-by-construction — O(n²) in Excel too, and NOT a mark against this
  engine. Reported for contrast so a reader can see what a real quadratic looks
  like next to an implementation artefact:

    * `prefix`     — `B_r = SUM($A$1:A_r)`: a growing prefix sum. The r-th
      formula must read r cells, so total work is Σr = n(n+1)/2 by definition.
      Expect k ≈ 2.0 on any correct engine, Excel included.

  ## Usage

      mix barkpark.sheets.bench
      mix barkpark.sheets.bench --shapes window,chain --sizes 500,1000,2000,4000
      mix barkpark.sheets.bench --shapes prefix --sizes 250,500,1000 --runs 5

  Options:

    * `--shapes`  comma-separated (default: all five)
    * `--sizes`   comma-separated row counts (default: `250,500,1000,2000,4000`)
    * `--runs`    timed runs per size, median reported (default: 7)
    * `--warmup`  untimed runs per size (default: 1)

  Output is one table per shape: rows, cells, formulas, median wall ms, the
  wall-clock local exponent `k_ms` against the previous rung, millions of
  reductions, and the reduction local exponent `k_red`. Read `k_red`.
  """

  use Mix.Task

  alias Barkpark.Plugins.Sheets.Core
  alias Barkpark.Plugins.Sheets.Engine

  @default_sizes [250, 500, 1000, 2000, 4000]
  @shapes ~w(independent chain window fanin prefix)
  @linear_shapes ~w(independent chain window fanin)

  @window_cols 10
  @fanin_span 50

  @requirements ["app.config"]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [shapes: :string, sizes: :string, runs: :integer, warmup: :integer]
      )

    shapes = parse_list(opts[:shapes], @shapes, & &1)
    sizes = parse_list(opts[:sizes], @default_sizes, &String.to_integer/1)
    runs = opts[:runs] || 7
    warmup = opts[:warmup] || 1

    Enum.each(shapes, fn shape ->
      unless shape in @shapes do
        Mix.raise("unknown shape #{inspect(shape)}; known: #{Enum.join(@shapes, ", ")}")
      end
    end)

    Mix.shell().info("""
    Sheets recompute complexity sweep
      runs=#{runs} (median)  warmup=#{warmup}  gc=between every timed run
      otp=#{:erlang.system_info(:otp_release)}  schedulers=#{:erlang.system_info(:schedulers_online)}
      sizes=#{Enum.join(sizes, ",")}
    """)

    Enum.each(shapes, &sweep(&1, sizes, runs, warmup))
  end

  defp sweep(shape, sizes, runs, warmup) do
    label =
      if shape in @linear_shapes,
        do: "LINEAR by construction (expect k ~ 1.0)",
        else: "QUADRATIC by construction (expect k ~ 2.0 on ANY engine, Excel included)"

    Mix.shell().info("\n## #{shape} — #{label}\n")

    Mix.shell().info(
      String.pad_trailing("rows", 8) <>
        String.pad_leading("cells", 9) <>
        String.pad_leading("formulas", 10) <>
        String.pad_leading("median ms", 12) <>
        String.pad_leading("k_ms", 8) <>
        String.pad_leading("Mreds", 12) <>
        String.pad_leading("k_red", 8)
    )

    Enum.reduce(sizes, nil, fn n, prev ->
      content = build(shape, n)
      {cells, formulas} = census(content)

      Enum.each(1..warmup//1, fn _ -> Engine.recompute(content) end)

      ms = median(for _ <- 1..runs, do: time_ms(content))
      reds = reductions(content)

      Mix.shell().info(
        String.pad_trailing(Integer.to_string(n), 8) <>
          String.pad_leading(Integer.to_string(cells), 9) <>
          String.pad_leading(Integer.to_string(formulas), 10) <>
          String.pad_leading(fmt(ms, 1), 12) <>
          String.pad_leading(exponent(prev, n, ms, 0), 8) <>
          String.pad_leading(fmt(reds / 1_000_000, 2), 12) <>
          String.pad_leading(exponent(prev, n, reds, 1), 8)
      )

      {n, ms, reds}
    end)
  end

  # log(v / v_prev) / log(n / n_prev) — the LOCAL exponent against the previous
  # rung. `slot` picks which measurement out of the previous rung's tuple.
  defp exponent(nil, _n, _v, _slot), do: "-"

  defp exponent({pn, _, _} = prev, n, v, slot) do
    pv = elem(prev, slot + 1)

    if pv > 0 and v > 0,
      do: fmt(:math.log(v / pv) / :math.log(n / pn), 2),
      else: "-"
  end

  # Reductions consumed by ONE recompute, measured in a dedicated process so
  # nothing else is charged to the number. Deterministic for a given input:
  # unlike wall clock it cannot be moved by machine load, which is what makes
  # it the instrument this sweep actually rules on.
  defp reductions(content) do
    parent = self()
    tag = make_ref()

    {pid, mref} =
      spawn_monitor(fn ->
        Engine.recompute(content)
        {:reductions, r} = Process.info(self(), :reductions)
        send(parent, {tag, r})
      end)

    receive do
      {^tag, r} ->
        Process.demonitor(mref, [:flush])
        r

      {:DOWN, ^mref, :process, ^pid, reason} ->
        Mix.raise("reduction probe died: #{inspect(reason)}")
    end
  end

  # One timed recompute with a forced collection first, so the clock never
  # charges this run for the previous run's garbage.
  defp time_ms(content) do
    :erlang.garbage_collect()
    {micros, _} = :timer.tc(fn -> Engine.recompute(content) end)
    micros / 1_000
  end

  defp median(samples) do
    sorted = Enum.sort(samples)
    n = length(sorted)

    if rem(n, 2) == 1 do
      Enum.at(sorted, div(n, 2))
    else
      (Enum.at(sorted, div(n, 2) - 1) + Enum.at(sorted, div(n, 2))) / 2
    end
  end

  # ── document builders ───────────────────────────────────────────────────────
  #
  # Every builder produces a SINGLE tab (the per-tab fast path — no cross-tab
  # refs), so a shape's exponent is not confounded by the unified graph.

  @doc false
  def build(shape, rows), do: %{"tabs" => [%{"name" => "Bench", "cells" => cells(shape, rows)}]}

  # B_r = A_r*2+1. Zero formula→formula edges, zero ranges.
  defp cells("independent", rows) do
    Enum.flat_map(1..rows, fn row ->
      [{ref(1, row), literal(row)}, {ref(2, row), %{"f" => "=#{ref(1, row)}*2+1"}}]
    end)
    |> Map.new()
  end

  # B_1 = A_1+1; B_r = B_{r-1}+A_r. n-1 edges, depth n.
  defp cells("chain", rows) do
    Enum.flat_map(1..rows, fn row ->
      f =
        if row == 1,
          do: "=#{ref(1, 1)}+1",
          else: "=#{ref(2, row - 1)}+#{ref(1, row)}"

      [{ref(1, row), literal(row)}, {ref(2, row), %{"f" => f}}]
    end)
    |> Map.new()
  end

  # L_r = SUM(A_r:J_r) over a fixed @window_cols literal block. n ranges, each
  # a constant 10 cells wide and containing NO formula cell.
  defp cells("window", rows) do
    Enum.flat_map(1..rows, fn row ->
      literals = for col <- 1..@window_cols, do: {ref(col, row), literal(row + col)}

      [
        {ref(@window_cols + 1, row), %{"f" => "=SUM(#{ref(1, row)}:#{ref(@window_cols, row)})"}}
        | literals
      ]
    end)
    |> Map.new()
  end

  # C_r = SUM($A$1:$A$50). n formulas, all reading one constant-size range.
  defp cells("fanin", rows) do
    Enum.flat_map(1..rows, fn row ->
      [
        {ref(1, row), literal(row)},
        {ref(3, row), %{"f" => "=SUM(#{ref(1, 1)}:#{ref(1, @fanin_span)})"}}
      ]
    end)
    |> Map.new()
  end

  # B_r = SUM($A$1:A_r). Growing prefix: total work Sum(r) = n(n+1)/2 BY
  # DEFINITION. Quadratic on any engine; here as the contrast case.
  defp cells("prefix", rows) do
    Enum.flat_map(1..rows, fn row ->
      [
        {ref(1, row), literal(row)},
        {ref(2, row), %{"f" => "=SUM(#{ref(1, 1)}:#{ref(1, row)})"}}
      ]
    end)
    |> Map.new()
  end

  defp literal(n), do: %{"v" => rem(n * 7, 97) + 1}

  defp ref(col, row), do: Core.format_ref({col, row})

  defp census(%{"tabs" => tabs}) do
    Enum.reduce(tabs, {0, 0}, fn %{"cells" => cells}, {total, formulas} ->
      {total + map_size(cells),
       formulas + Enum.count(cells, fn {_k, c} -> is_map(c) and is_binary(c["f"]) end)}
    end)
  end

  defp fmt(f, places), do: f |> Float.round(places) |> Float.to_string()

  defp parse_list(nil, default, _cast), do: default

  defp parse_list(str, _default, cast),
    do: str |> String.split(",", trim: true) |> Enum.map(&(&1 |> String.trim() |> cast.()))
end
