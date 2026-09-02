defmodule Barkpark.Plugins.Sheets.EnginePerfTest do
  @moduledoc """
  Complexity-contract guard for `Barkpark.Plugins.Sheets.Engine`.

  The engine's documented contract (engine.ex §Complexity) is ONE topological
  pass (Kahn) over the formula-dependency graph — **O(cells + edges)**, no
  per-cell rescans. That contract has no executable guard: a regression to an
  O(n²) rescan (e.g. re-walking the whole cell set per formula, or expanding a
  range rectangle instead of intersecting the occupied set) would still return
  correct values, so every value-oriented test in `engine_test.exs` stays
  green. Only the wall clock notices.

  This file is that clock. It builds a sheet document near the `@cell_cap`
  (50_000, `plugins/sheets.ex`) — tens of thousands of non-empty cells with
  thousands of formula cells (a long arithmetic dependency CHAIN, per-row SUM
  ranges over the occupied region, and cross-tab references that force the
  unified `{tab, col, row}` graph, which is the heavier of the two recompute
  paths) — and asserts `Engine.recompute/1` finishes inside a generous
  `:timer.tc` bound. A quadratic rescan on ~48k cells blows past the bound by
  orders of magnitude; a linear pass clears it with room to spare.

  Pure `Engine`, no Repo/DB — same shape as `engine_test.exs`.

  ## The bound, and why it will not flake

  Measured local baseline (Apple Silicon M-series, Erlang/OTP 28,
  `MIX_ENV=test`) for the ~47k-cell UNIFIED recompute built below: **~0.8–1.3 s
  wall** across repeated runs (parse + evaluate dominate; ~47k cells at tens of
  µs each). That is higher than a naive "toposort is instant" guess — the cost
  is a real constant factor, but it is *linear*: tripling the row count grows
  the time ~4× on a quiet machine (see §The linearity ratio below for the
  measured distribution), nowhere near the ~9× a quadratic rescan would show.

  The guard bound is **10_000 ms** — roughly **8× the worst observed run
  (~1.3 s) and ~10× the typical run (~1.0 s)**, the headroom the slice brief
  calls for. CI runners are slower and noisier than a dev laptop, but not 8×
  on a pure-CPU toposort, so a healthy engine clears 10 s with wide margin
  while a genuine O(n²) regression — which on 47k cells with a 3.6k-deep
  dependency chain would need tens of seconds to minutes — fails hard. The
  bound guards the *shape* of the algorithm, not a micro-benchmark number.
  The main test performs exactly ONE near-cap recompute and the linearity
  test uses small grids, so the file's own wall time stays a few seconds,
  well under the 10 s file budget even on a 2–3× slower runner.

  ## The linearity ratio, and why its ceiling is 8×

  The second test divides the big grid's time by the small grid's. It is a
  *wall-clock ratio*, so it inherits every scheduler artefact of the machine it
  runs on. Its ceiling was 6.0 with a documented "~3.9× observed locally"; both
  numbers were wrong, and the gap red-flagged main on PR #4686 — a PR that
  changed one shell script and zero Elixir. A re-run of the identical sha
  passed 11957/0, and no `api/` file changed anywhere in that PR's range
  (`Engine.recompute` is untouched since #2044). It was contention, not a
  regression.

  Measured ratios, `MIX_ENV=test`, Apple Silicon, best-of-3 as shipped:

    * quiet machine, 6 samples: **4.0, 4.3, 2.7, 4.2, 4.3, 4.3**
    * same machine under moderate load, 5 samples: **6.2, 4.0, 5.6, 5.7, 5.8**
    * shared CI runner (#4686), 1 sample: **6.1**

  Two things fall out. First, the loaded local machine printed **6.2** — the
  old 6.0 ceiling is reproducibly exceeded by a *healthy* engine, so #4686 was
  not bad luck. Second, the 2.7 sample is the tell: its small grid measured
  119.7 ms against a typical 65 ms, i.e. contention landed in the *small*
  block and DEFLATED the ratio. Noise here is not a one-sided upward push; it
  skews whichever grid's measurement block it happens to land in.

  That is also why best-of-3 cannot save this: min-of-N removes a spike shorter
  than one sample, but a contention burst spanning a whole block is present in
  every sample the min chooses from. Contention on a shared runner is
  correlated, and correlated noise survives minimisation.

  **A denoising fix was tried and rejected on the evidence.** Interleaving the
  grids (small, big, small, big …) so a shared burst hits both and cancels in
  the ratio is the textbook answer, and it did NOT help this workload: in a
  paired A/B controlling for load drift, block-sequential gave 6.2/4.0/5.6/5.7/5.8
  (median 5.7) and interleaved gave 7.4/5.3/5.2/5.0/5.2 (median 5.2) — a lower
  median but a HIGHER maximum, which is the only statistic a guard's ceiling
  cares about. Plausibly the alternation costs cache locality that the big grid
  pays for. The measurement code is therefore left exactly as it was; do not
  re-try interleaving without re-measuring maxima, not medians.

  So the fix is margin, honestly sized. The ceiling is **8.0×**: ~1.3× above the
  worst healthy sample ever observed (6.2), ~1.9× above the quiet-machine
  typical (4.3), and below the ~9× floor of a genuine quadratic.

  The margin between 8 and 9 is admittedly thin, and it is thin *on purpose*
  rather than by accident — because this test is NOT the primary quadratic
  guard. The near-cap test above is: an O(n²) rescan of 47k cells across a
  3.6k-deep chain needs tens of seconds to minutes and blows the 10 s absolute
  bound by orders of magnitude, on every run, on any runner. The ratio test is
  the corroborating shape signal. A corroborating signal that reds main on
  unrelated PRs is worth less than one that fires only when the primary guard
  does too, so it is tuned to be quiet under contention rather than maximally
  sensitive. If you are tempted to lower it back toward the noise floor, lower
  the *variance* first (a dedicated perf runner), not the ceiling.

  ## The range-index lock

  A third test guards the specific defect the two above could not see. Both
  measure WALL CLOCK, so both must carry enough margin to survive a loaded
  runner — and that margin is exactly the room a quadratic GRAPH-BUILD hid in.
  The linearity ratio permits 8x for a 3x row growth, i.e. anything up to
  ~n^1.9; the near-cap bound is absolute and clears by 10x. Neither reds on an
  O(ranges x formulas) graph build, and neither did: a log-log sweep of
  `mix barkpark.sheets.bench --shapes window --sizes 250,500,1000,2000`
  measured a local exponent rising 1.57 -> 1.72 -> **1.84** on a shape whose
  real work is exactly linear, while this file stayed green. The same sweep
  after the formula-position index landed reads 1.00 -> 1.00 -> 1.03, and the
  2000-row rung costs 3.9M reductions instead of 32.1M.

  The lock measures REDUCTIONS instead. A reduction count is a deterministic
  function of the work performed — immune to CPU speed, contention, and GC —
  so its ceiling can sit at 1.5x the linear expectation and still never flake.
  On the row-local-SUM shape, 4x the rows must cost ~4x the reductions; a
  per-range scan of the formula set costs ~16x. Measured on this exact
  fixture: **11.8x before the fix (2_720_690 -> 32_102_563) and 4.00x after
  (965_307 -> 3_862_230)** — 8.3x fewer reductions at the 2000-row rung.

  The wall-clock columns in that same sweep are the control that proves this
  choice was necessary, not fastidious: on the LINEAR `independent` shape the
  pre-fix run printed wall exponents of 1.79, 0.37 and 1.26 for an engine
  whose reduction exponents were 0.98, 0.97 and 1.01. The wall clock could not
  see the defect and could not see its absence either.

  This test is intentionally UN-tagged: it runs in the default suite. An
  excluded guard is a vacuous guard.
  """
  # async: false — this file asserts WALL CLOCK. Running it concurrently with
  # up to max_cases other test files adds scheduler contention that only ever
  # pushes the measured time UP, spending the flake headroom on noise instead
  # of regressions. Serial costs ~2 s of suite time; a flaky perf guard costs
  # trust.
  use ExUnit.Case, async: false

  alias Barkpark.Plugins.Sheets.Core
  alias Barkpark.Plugins.Sheets.Engine

  # Generous wall-clock ceiling. See @moduledoc — ~8× the worst / ~10× the
  # typical measured local baseline (~0.8–1.3 s). A linear recompute clears
  # this with room to spare; an O(n²) rescan on ~47k cells cannot.
  @bound_ms 10_000

  # Grid geometry for the near-cap sheet. 10 value columns + 3 formula columns
  # per row → 13 cells/row; 3_600 rows ≈ 46_800 cells on the Data tab, plus the
  # Summary tab's cross-tab formulas, staying just under @cell_cap (50_000).
  @value_cols 10
  @rows 3_600
  @cross_tab_refs 200

  # Linearity probe geometry (small grids on the fast path — kept far below the
  # cap so this second test adds only a fraction of a second).
  @lin_small_rows 700
  @lin_factor 3

  # Range-index lock geometry. Rows carrying one row-local SUM each; the ratio
  # is measured in REDUCTIONS, not wall clock, so these can be large enough to
  # separate n from n^2 without buying any flake. See @moduledoc
  # §The range-index lock.
  @rr_rows 500
  @rr_factor 4
  @rr_window_cols 10
  @rr_ceiling 6.0

  describe "recompute/1 complexity floor (near @cell_cap)" do
    test "a near-cap unified recompute finishes inside the generous bound" do
      content = near_cap_content(@rows)

      {cells, formula_cells} = cell_census(content)
      # Guard the guard: if this ever drifts far from the cap the bound would
      # stop meaning "near-cap", so pin the shape we actually measured.
      assert cells >= 45_000,
             "expected a near-cap sheet (>=45k cells) but built #{cells}"

      assert cells < 50_000,
             "must stay under @cell_cap (50_000) but built #{cells}"

      assert formula_cells >= 10_000,
             "expected thousands of formula cells but built #{formula_cells}"

      {micros, out} = :timer.tc(fn -> Engine.recompute(content) end)
      ms = micros / 1_000

      # Prove the recompute actually did the work — a no-op that returned the
      # input untouched would clear any time bound (distrust vacuous green).
      assert computed?(out), "recompute did not write back computed values"

      assert ms < @bound_ms,
             """
             near-cap recompute took #{Float.round(ms, 1)}ms for #{cells} cells \
             (#{formula_cells} formulas), over the #{@bound_ms}ms complexity \
             floor. This is the O(cells+edges) → O(n^2) tripwire: a linear \
             pass clears this bound ~10x over. Investigate the toposort / range \
             evaluation before raising the bound.
             """
    end

    # Optional linearity sanity: growing the row count @lin_factor× must NOT
    # super-linearly blow up the time. Both grids use the per-tab fast path (no
    # cross-tab refs) so they share one code path, and both stay far below the
    # cap so this probe is cheap. The ceiling is deliberately loose — it flags a
    # quadratic CLIFF, not constant-factor or GC noise. Best-of-3 (min) per grid
    # absorbs first-run alloc noise and GC spikes, and the small time is floored
    # to avoid divide-by-noise at millisecond scale. Best-of-3 does NOT absorb
    # correlated runner contention — see @moduledoc §The linearity ratio, which
    # is why the ceiling carries the margin instead.
    test "recompute scales roughly linearly, not quadratically, with cell count" do
      small = fast_path_content(@lin_small_rows)
      big = fast_path_content(@lin_small_rows * @lin_factor)

      # Best-of-N (min wall time) rejects GC/scheduler spikes — the standard
      # microbenchmark denoiser. A quadratic regression shows in every run, so
      # taking the minimum cannot hide it; it only removes upward noise that
      # would otherwise flake the ratio.
      small_ms = max(best_ms(fn -> Engine.recompute(small) end, 3), 1.0)
      big_ms = best_ms(fn -> Engine.recompute(big) end, 3)

      ratio = big_ms / small_ms
      # big has @lin_factor× (3×) the rows of small. Linear ≈ 3×; quadratic
      # ≈ 9×. The 8× ceiling clears the worst HEALTHY sample measured (6.2 on a
      # loaded machine; 6.1 on the CI runner that red-flagged #4686) with ~1.3×
      # to spare, and still trips below a quadratic's ~9×. Full measured
      # distribution and the rejected denoising alternative: @moduledoc
      # §The linearity ratio. Do not lower this without new measurements.
      assert ratio < 8.0,
             """
             recompute time grew #{Float.round(ratio, 1)}x when rows grew \
             #{@lin_factor}x (small #{Float.round(small_ms, 1)}ms -> \
             big #{Float.round(big_ms, 1)}ms). Super-linear growth toward \
             #{@lin_factor * @lin_factor}x points at an O(n^2) rescan.
             """
    end

    # The range-index lock (task spd-b33). Growing the row count @rr_factor x
    # multiplies the WORK by @rr_factor and nothing else: every formula is a
    # `SUM` over its OWN row's fixed 10-column literal block, so ranges grow
    # with n while each range's answer stays constant-size. If graph
    # construction resolves a range by filtering the whole formula set, this
    # document costs O(ranges x formulas) = O(n^2) to merely BUILD — which is
    # what it did until the formula-position index landed, and what a log-log
    # sweep measured at k ~ 2.0 on exactly this shape.
    #
    # Measured in REDUCTIONS, deliberately, not wall clock. A reduction count is
    # a deterministic property of the work performed: it does not move with CPU
    # speed, scheduler contention, GC timing, or how many other test files are
    # running. That is the whole reason the two tests above need essays about
    # margin and this one does not — the ceiling can sit at 1.5x the linear
    # expectation instead of 2x, and still never flake.
    test "row-local range dependencies do not rescan the formula set per range" do
      small = row_local_sum_content(@rr_rows)
      big = row_local_sum_content(@rr_rows * @rr_factor)

      small_reds = reductions(fn -> Engine.recompute(small) end)
      big_reds = reductions(fn -> Engine.recompute(big) end)

      ratio = big_reds / small_reds

      assert ratio < @rr_ceiling,
             """
             #{@rr_factor}x the rows cost #{Float.round(ratio, 2)}x the reductions \
             (#{small_reds} -> #{big_reds}) on a shape whose real work is exactly \
             #{@rr_factor}x. Linear is ~#{@rr_factor}.0x; a per-range scan of the \
             formula set is ~#{@rr_factor * @rr_factor}.0x. Look at \
             range_node_deps/2 and the formula-position index it queries \
             (engine.ex §Complexity) before touching this ceiling.
             """
    end
  end

  # ── content builders ────────────────────────────────────────────────────────

  # A near-cap, two-tab document that exercises the UNIFIED cross-tab recompute
  # path (the heavier one): the Summary tab references Data, so the whole doc
  # recomputes as one {tab, col, row} graph.
  defp near_cap_content(rows) do
    %{"tabs" => [data_tab("Data", rows), summary_tab("Summary")]}
  end

  # A single-tab document with NO cross-tab refs → the per-tab fast path.
  defp fast_path_content(rows) do
    %{"tabs" => [data_tab("Data", rows)]}
  end

  # One "Data" tab:
  #   * value columns A..J (1..@value_cols): plain numbers over the occupied
  #     region that the SUM ranges cover.
  #   * column K: a long arithmetic dependency CHAIN (K_r = K_{r-1} + A_r). A
  #     naive per-formula rescan degrades hardest on a deep chain.
  #   * column L: per-row SUM over the row's value block (range dependency that
  #     must intersect the occupied set, not expand the rectangle).
  #   * column M: L_r * 2 + K_r — mixes a range result with the chain.
  defp data_tab(name, rows) do
    value_cols = 1..@value_cols

    values =
      for row <- 1..rows, col <- value_cols, into: %{} do
        {a1(col, row), %{"v" => rem(row * 7 + col, 97) + 1}}
      end

    chain_col = @value_cols + 1
    sum_col = @value_cols + 2
    combo_col = @value_cols + 3

    cells =
      Enum.reduce(1..rows, values, fn row, acc ->
        chain_col_ref = a1(chain_col, row)
        sum_col_ref = a1(sum_col, row)
        combo_col_ref = a1(combo_col, row)

        acc
        |> Map.put(chain_col_ref, chain_formula(chain_col, row))
        |> Map.put(sum_col_ref, %{"f" => "SUM(#{a1(1, row)}:#{a1(@value_cols, row)})"})
        |> Map.put(combo_col_ref, %{"f" => "#{sum_col_ref}*2+#{chain_col_ref}"})
      end)

    %{"name" => name, "cells" => cells}
  end

  # K1 seeds the chain from A1; K_r extends it. Long chain ⇒ deep dependency
  # path, the pathological case for an O(n^2) rescan.
  defp chain_formula(_chain_col, 1), do: %{"f" => "#{a1(1, 1)}+1"}

  defp chain_formula(chain_col, row),
    do: %{"f" => "#{a1(chain_col, row - 1)}+#{a1(1, row)}"}

  # Summary tab: @cross_tab_refs direct cross-tab cell refs plus one heavy
  # cross-tab aggregate. ANY cross-tab ref forces the unified graph for the
  # whole document.
  defp summary_tab(name) do
    refs =
      for i <- 1..@cross_tab_refs, into: %{} do
        {a1(1, i), %{"f" => "Data!#{a1(@value_cols + 3, i)}"}}
      end

    cells =
      Map.put(refs, a1(2, 1), %{
        "f" => "SUM(Data!#{a1(@value_cols + 2, 1)}:#{a1(@value_cols + 2, @rows)})"
      })

    %{"name" => name, "cells" => cells}
  end

  # ── measurement + assertions helpers ────────────────────────────────────────

  # n rows, each: 10 literal columns plus ONE formula `SUM(A_r:J_r)` over them.
  # n ranges, each covering a constant 10 cells and containing NO formula cell,
  # so total evaluation work is exactly linear in n. Single tab -> fast path.
  defp row_local_sum_content(rows) do
    cells =
      Enum.flat_map(1..rows, fn row ->
        literals =
          for col <- 1..@rr_window_cols, do: {a1(col, row), %{"v" => rem(row + col, 97) + 1}}

        [
          {a1(@rr_window_cols + 1, row),
           %{"f" => "SUM(#{a1(1, row)}:#{a1(@rr_window_cols, row)})"}}
          | literals
        ]
      end)
      |> Map.new()

    %{"tabs" => [%{"name" => "Data", "cells" => cells}]}
  end

  # Reductions consumed by `fun`, measured in a dedicated process so nothing the
  # test framework does is charged to the number. Deterministic for a given
  # input: unlike wall clock it cannot be moved by load.
  defp reductions(fun) do
    parent = self()

    pid =
      spawn(fn ->
        fun.()
        {:reductions, r} = Process.info(self(), :reductions)
        send(parent, {:reductions, self(), r})
      end)

    ref = Process.monitor(pid)

    receive do
      {:reductions, ^pid, r} ->
        Process.demonitor(ref, [:flush])
        r

      {:DOWN, ^ref, :process, ^pid, reason} ->
        flunk("reduction probe died: #{inspect(reason)}")
    after
      120_000 -> flunk("reduction probe timed out")
    end
  end

  # Minimum wall time over `n` runs, in ms — best-of-N microbenchmark denoiser.
  defp best_ms(fun, n) do
    1..n
    |> Enum.map(fn _ ->
      {micros, _} = :timer.tc(fun)
      micros / 1_000
    end)
    |> Enum.min()
  end

  defp a1(col, row), do: Core.format_ref({col, row})

  defp cell_census(%{"tabs" => tabs}) do
    Enum.reduce(tabs, {0, 0}, fn %{"cells" => cells}, {total, formulas} ->
      f = Enum.count(cells, fn {_k, c} -> is_map(c) and is_binary(c["f"]) end)
      {total + map_size(cells), formulas + f}
    end)
  end

  # At least one formula cell has a written-back numeric "v" (a "t" of "n") —
  # proof the engine actually computed rather than passing content through.
  defp computed?(%{"tabs" => tabs}) do
    Enum.any?(tabs, fn %{"cells" => cells} ->
      Enum.any?(cells, fn {_k, c} ->
        is_map(c) and is_binary(c["f"]) and Map.has_key?(c, "v") and c["t"] == "n"
      end)
    end)
  end
end
