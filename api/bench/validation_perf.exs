# Phase 3 WI4 — validation engine perf benchmark.
#
# Run from the api/ working directory:
#
#     mix run --no-start bench/validation_perf.exs
#
# `--no-start` skips Application boot — the bench is pure-compute and does
# not need the Repo / Endpoint, so we avoid spinning up Postgres just to
# measure validation throughput. CI runs with `--no-start` for the same
# reason (see .github/workflows/elixir.yml).
#
# Generates a synthetic 200-field / 30-contributor doc with a 100-rule
# rule list, compiles the rules through `Rules.compile_all/1`, then runs
# `Barkpark.Content.Validation.Evaluator.run_rules/3` @iterations times and
# prints min / median / p95 / max / mean wall-clock time in milliseconds.
#
# ── THE ALARM IS RELATIVE, NOT A FIXED MILLISECOND NUMBER ──────────────────
#
# It used to be `median of 5 > 100ms`. Measured 2026-09-06 over 24 sampled CI
# runs of this job (task-578619eaf4824adb), the medians printed were
# 0.41-1.41 ms: the alarm sat ~70x above the quantity it measured, so a 50x
# validation regression merged green through a REQUIRED context. A fixed
# number cannot simply be lowered either — a slow or noisy shared runner would
# then red honest code, which is how a gate stops being believed.
#
# So the job now measures the RUNNER ITSELF in the same process, on the same
# core, seconds apart: `baseline/1` is a fixed-work pure-BEAM loop (binary
# construction, map lookup, integer arithmetic — the primitives the evaluator's
# hot path is made of) run @baseline_iterations times, median taken. Both
# numbers are printed side by side and the verdict is their RATIO. A runner
# twice as slow moves the baseline and the sample together and the ratio does
# not move; a validation regression moves only the sample.
#
# Two independent arms, either one fails the job:
#
#   * RATIO  p95(validation) / median(baseline), expressed as a MULTIPLE of
#     the nominal ratio this bench records for honest code, > @alarm_multiple.
#     This is the arm that actually catches regressions. The nominal ratio is
#     a constant, but a runner-INDEPENDENT one: it is a ratio of two timings
#     taken on the same core seconds apart, so a slower runner scales both
#     numerator and denominator and leaves it where it was. That is exactly
#     what a fixed millisecond threshold could not do.
#   * CEILING p95(validation) > @absolute_ceiling_ms.
#     The Phase 3 plan target, kept as a backstop so a pathology that slows
#     the baseline and the sample equally (and therefore hides from the ratio)
#     still reds.
#
# p95 over @iterations samples, not median-of-5: a percentile is only as stable
# as the sample behind it, and 5 points have no 95th.
#
# CI runs this on `ubuntu-latest` (see the `runs-on:` of the validation-perf
# job in .github/workflows/elixir.yml). It used to say `ubuntu-latest-4-core`
# here; that label is a PAID larger runner this account never gets, the job was
# moved to the standard runner, and this sentence was not updated — which is
# precisely why the threshold can no longer be a constant tuned to "a stable
# runner profile".
#
# Phase 3 WI1 (commit d902ffa, PR #48) introduced the canonical evaluator
# API: `Evaluator.run/3` takes a `schema_id` (cache lookup) and
# `Evaluator.run_rules/3` takes an explicit pre-compiled rule list. The
# bench uses the latter so it never touches the GenServer-backed cache.
#
# The doc + rule fixtures are intentionally inlined here so the bench is
# self-contained — the diff stays in one file when the canonical API or
# fixture format drifts.

defmodule Barkpark.Bench.ValidationPerf do
  alias Barkpark.Content.Validation.Evaluator
  alias Barkpark.Content.Validation.Rules

  @field_count 200
  @contributor_count 30
  @rule_count 100
  # >= 50 is the floor a p95 needs to mean anything; 60 is that floor plus a
  # round margin, and at the medians this bench prints it costs well under a
  # second. Read the header for why the verdict moved off median-of-5.
  @iterations 60
  @warmups 3

  # ── the runner baseline ───────────────────────────────────────────────────
  # @baseline_units is tuned so the baseline lands in the SAME ORDER as the
  # validation sample — a baseline 100x smaller would be dominated by timer
  # resolution and a baseline 100x larger would drown the signal. Measured
  # 2026-09-13, `MIX_ENV=test mix run --no-start bench/validation_perf.exs` on
  # an Apple M-series laptop: 20_000 units gave a baseline median of 1.710 ms
  # against a validation median of 0.402 ms and a p95 of 0.836 ms — the same
  # order. Re-tune only if the two numbers in the printed block drift more
  # than ~10x apart.
  @baseline_units 20_000
  @baseline_iterations 21

  # THE NOMINAL RATIO — what honest code costs in units of this runner's own
  # speed, so the verdict can be stated as a MULTIPLE of it. Both numbers
  # below carry their date and the command that produced them; replace them
  # only by re-running the bench and quoting the new run.
  #
  #   2026-09-13, local (Apple M-series, `mix run --no-start`), two runs on a
  #   BUSY machine — which is the point of the ratio, not an apology for it:
  #     run 1: baseline 1.710 ms, p95 0.836 ms -> ratio 0.49x
  #     run 2: baseline 1.148 ms, p95 0.615 ms -> ratio 0.54x
  #     run 3: baseline 1.879 ms, p95 0.827 ms -> ratio 0.44x
  #   The baseline spans 1.148-1.879 ms, a 64% spread; the ratio spans
  #   0.44-0.54x, a 23% one. A fixed millisecond threshold absorbs the whole
  #   64% and calls it signal.
  #   2026-09-13, CI (ubuntu-latest, run 34746159133, this bench's own
  #   validation-perf job): baseline 1.351 ms, p95 0.479 ms -> ratio 0.35x.
  #
  # PINNED TO THE CI VENUE, rounded up, because CI is the only venue where
  # this gate DECIDES anything — a local run prints, it does not block a
  # merge. Pinning to the slowest venue instead would spend the alarm's
  # headroom on a machine that cannot red a PR: at nominal 0.60 the 5x
  # mutation below lands at 2.95x against a 2.50x alarm, an 18% margin; at
  # 0.40 it lands at 4.4x, and the busiest local ratio observed (0.54x) still
  # only indexes 1.35x, less than half the alarm.
  @nominal_ratio 0.40

  # A 5x validation slowdown — the mutation this change was proved with —
  # lands at 5.0x nominal and reds with 2x margin. Honest code may drift to
  # 2.5x nominal before the job reds, which covers the residual venue-to-venue
  # variance the baseline does not cancel. Today's shipped gate (fixed
  # >100 ms on a median of 5) does not red that mutation at all: 5 x 0.402 ms
  # is 2.0 ms, twenty-fold under the threshold.
  @alarm_multiple 2.5

  # The Phase 3 plan target, kept as an absolute backstop (header, CEILING arm).
  @target_ms 100
  @absolute_ceiling_ms 100
  @tag :mutate

  def run do
    doc = build_doc(@field_count, @contributor_count)
    rules = build_rules(@rule_count, @field_count)
    baseline_map = build_baseline_map(@field_count)

    # Warm-up: load atoms / compile call sites / settle the BEAM JIT before
    # we start timing. Discarded.
    for _ <- 1..@warmups do
      _ = Evaluator.run_rules(doc, rules, @tag)
      _ = baseline(baseline_map)
    end

    # THE BASELINE IS MEASURED FIRST AND ON THIS SAME PROCESS, so the two
    # samples see the same core, the same scheduler and the same neighbours.
    baseline_ms =
      for _ <- 1..@baseline_iterations do
        {micros, _} = :timer.tc(fn -> baseline(baseline_map) end)
        micros / 1000.0
      end

    times_ms =
      for _ <- 1..@iterations do
        {micros, _result} =
          :timer.tc(fn ->
            Evaluator.run_rules(doc, rules, @tag)
          end)

        micros / 1000.0
      end

    sorted = Enum.sort(times_ms)
    min = List.first(sorted)
    max = List.last(sorted)
    median = percentile(sorted, 0.50)
    p95 = percentile(sorted, 0.95)
    mean = Enum.sum(times_ms) / @iterations

    baseline_sorted = Enum.sort(baseline_ms)
    baseline_median = percentile(baseline_sorted, 0.50)

    # A baseline that measured nothing must never be allowed to divide: a
    # zero or negative median would make every ratio infinite or negative and
    # the gate would be loud-but-meaningless in one direction and vacuous in
    # the other. Name it and refuse, rather than print a verdict.
    if baseline_median <= 0.0 do
      IO.puts(:stderr, """
      CANNOT READ: the runner baseline measured #{format_ms(baseline_median)} \
      over #{@baseline_iterations} iterations, which cannot be a divisor. \
      Refusing to emit a ratio verdict from a baseline that measured nothing.
      """)

      System.halt(1)
    end

    ratio = p95 / baseline_median
    index = ratio / @nominal_ratio

    IO.puts("""

    === Validation perf bench (relative alarm) =========================
      doc:             #{@field_count} scalars + #{@contributor_count} contributors
      rules:           #{@rule_count}
      iterations:      #{@iterations} (warmups: #{@warmups})

      RUNNER BASELINE  (#{@baseline_units} units x #{@baseline_iterations} iterations)
      baseline median: #{format_ms(baseline_median)}

      VALIDATION SAMPLE
      min:             #{format_ms(min)}
      median:          #{format_ms(median)}
      p95:             #{format_ms(p95)}
      mean:            #{format_ms(mean)}
      max:             #{format_ms(max)}

      VERDICT
      ratio:           #{format_ratio(ratio)}  (p95 #{format_ms(p95)} / baseline #{format_ms(baseline_median)})
      nominal ratio:   #{format_ratio(@nominal_ratio)} (recorded for honest code — see the attribute)
      index:           #{format_ratio(index)} of nominal
      alarm:           >#{format_ratio(@alarm_multiple)} of nominal (relative gate — fails the job)
      ceiling:         >#{@absolute_ceiling_ms}ms on p95 (absolute backstop — fails the job)
      target:          <#{@target_ms}ms (Phase 3 plan)
    =====================================================================
    """)

    failures =
      []
      |> then(fn acc ->
        if index > @alarm_multiple do
          ["RATIO #{format_ratio(ratio)} is #{format_ratio(index)} of the nominal " <>
             "#{format_ratio(@nominal_ratio)}, over the #{format_ratio(@alarm_multiple)} alarm " <>
             "(p95 #{format_ms(p95)} against a runner baseline of #{format_ms(baseline_median)})"
           | acc]
        else
          acc
        end
      end)
      |> then(fn acc ->
        if p95 > @absolute_ceiling_ms do
          ["CEILING p95 #{format_ms(p95)} exceeds the absolute ceiling #{@absolute_ceiling_ms}ms"
           | acc]
        else
          acc
        end
      end)
      |> Enum.reverse()

    case failures do
      [] ->
        IO.puts(
          "OK: validation perf is #{format_ratio(index)} of nominal against the measured " <>
            "runner baseline, under the #{format_ratio(@alarm_multiple)} alarm."
        )

      reasons ->
        IO.puts(:stderr, "REGRESSION:\n" <> Enum.map_join(reasons, "\n", &("  - " <> &1)))
        System.halt(1)
    end
  end

  # Nearest-rank percentile on an ALREADY SORTED list. Nearest-rank, not
  # interpolated, so the value printed is one the bench actually observed.
  defp percentile(sorted, q) when is_list(sorted) and q > 0 and q <= 1 do
    n = length(sorted)
    rank = max(1, min(n, ceil(q * n)))
    Enum.at(sorted, rank - 1)
  end

  # ── the runner baseline workload ──────────────────────────────────────────
  # Fixed work, no I/O, no processes, no ETS: binary construction, map lookup
  # and integer arithmetic, which is what the evaluator's hot path is made of.
  # Its only job is to cost a reproducible amount of BEAM time on whatever
  # hardware the job landed on.

  defp build_baseline_map(field_count) do
    for i <- 1..field_count, into: %{}, do: {"f_#{i}", "value-#{i}"}
  end

  defp baseline(map) do
    Enum.reduce(1..@baseline_units, 0, fn i, acc ->
      key = "f_" <> Integer.to_string(rem(i, @field_count) + 1)
      value = Map.get(map, key, "")
      acc + byte_size(value) + rem(i * 7, 13)
    end)
  end

  # ── doc fixture (inlined) ─────────────────────────────────────────────────

  defp build_doc(field_count, contributor_count) do
    scalars =
      for i <- 1..field_count, into: %{} do
        {"f_#{i}", scalar_value(i)}
      end

    contributors =
      for i <- 1..contributor_count do
        %{
          "name" => "Contributor #{i}",
          "role" => contributor_role(i),
          "isbn" => "9780000000" <> pad3(i)
        }
      end

    Map.merge(scalars, %{
      "_id" => "bench-doc",
      "_type" => "bench_book",
      "title" => "Synthetic Bench Book",
      "contributors" => contributors
    })
  end

  defp scalar_value(i) do
    case rem(i, 4) do
      0 -> "value-#{i}"
      1 -> rem(i, 2) == 0
      2 -> "2026-04-#{pad2(rem(i, 28) + 1)}T00:00:00Z"
      3 -> i
    end
  end

  defp contributor_role(i) do
    case rem(i, 5) do
      0 -> "A01"
      1 -> "A02"
      2 -> "A12"
      3 -> "B01"
      _ -> "Z99"
    end
  end

  defp pad2(n) when n < 10, do: "0#{n}"
  defp pad2(n), do: "#{n}"

  defp pad3(n) when n < 10, do: "00#{n}"
  defp pad3(n) when n < 100, do: "0#{n}"
  defp pad3(n), do: "#{n}"

  # ── rule fixture (inlined, compiled via Rules.compile_all/1) ──────────────

  # Rotate through every built-in op so the evaluator's hot-path branches
  # are exercised in proportion. `:matches` is intentionally excluded — it
  # would hit `Barkpark.Validation.Registry`, an ETS-backed GenServer that
  # is not started under `mix run --no-start`.
  @rule_kinds [:eq, :in, :nonempty, :starts_with, :contains_all]

  defp build_rules(rule_count, field_count) do
    raw =
      for i <- 1..rule_count do
        kind = Enum.at(@rule_kinds, rem(i, length(@rule_kinds)))
        build_rule(kind, i, field_count)
      end

    case Rules.compile_all(raw) do
      {:ok, list} -> list
      {:error, reason} -> raise "rule compile failed: #{inspect(reason)}"
    end
  end

  defp build_rule(:eq, i, field_count) do
    field = "f_#{rem(i, field_count) + 1}"

    %{
      "name" => "rule_eq_#{i}",
      "severity" => "error",
      "tags" => ["mutate"],
      "when" => %{"path" => "/" <> field, "op" => "nonempty"},
      "then" => %{
        "path" => "/" <> field,
        "op" => "eq",
        "value" => "value-#{rem(i, field_count) + 1}"
      }
    }
  end

  defp build_rule(:in, i, field_count) do
    field = "f_#{rem(i, field_count) + 1}"

    %{
      "name" => "rule_in_#{i}",
      "severity" => "warning",
      "tags" => ["mutate"],
      "when" => %{"path" => "/" <> field, "op" => "nonempty"},
      "then" => %{"path" => "/" <> field, "op" => "in", "value" => ["a", "b", "c"]}
    }
  end

  defp build_rule(:nonempty, i, _field_count) do
    %{
      "name" => "rule_nonempty_#{i}",
      "severity" => "error",
      "tags" => ["mutate"],
      "when" => %{"path" => "/_id", "op" => "nonempty"},
      "then" => %{"path" => "/contributors", "op" => "nonempty"}
    }
  end

  defp build_rule(:starts_with, i, _field_count) do
    %{
      "name" => "rule_starts_with_#{i}",
      "severity" => "warning",
      "tags" => ["mutate"],
      "when" => %{"path" => "/_id", "op" => "nonempty"},
      "then" => %{"path" => "/contributors/*/isbn", "op" => "startsWith", "value" => "978"}
    }
  end

  defp build_rule(:contains_all, i, _field_count) do
    %{
      "name" => "rule_contains_all_#{i}",
      "severity" => "info",
      "tags" => ["mutate"],
      "when" => %{"path" => "/_id", "op" => "nonempty"},
      "then" => %{"path" => "/contributors", "op" => "containsAll", "value" => []}
    }
  end

  defp format_ms(ms) when is_float(ms) do
    :io_lib.format("~.3fms", [ms]) |> List.to_string()
  end

  defp format_ratio(r) when is_number(r) do
    :io_lib.format("~.2fx", [r / 1]) |> List.to_string()
  end
end

Barkpark.Bench.ValidationPerf.run()
