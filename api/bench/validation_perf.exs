# Phase 3 WI4 — validation engine perf benchmark.
#
# Run from the api/ working directory:
#
#     mix run --no-start bench/validation_perf.exs
#
# `--no-start` skips Application boot — the bench is pure-compute and does
# not need the Repo / Endpoint, so we avoid spinning up Postgres just to
# measure validation throughput. CI runs with `--no-start` for the same
# reason (see .github/workflows/perf.yml).
#
# Generates a synthetic 200-field / 30-contributor doc with a 100-rule
# schema, runs `Barkpark.Content.Validation.Evaluator.run/3` 5 times, and
# prints min / median / max / mean wall-clock time in milliseconds.
#
# CI regression alarm: exits with status 1 if the median run exceeds
# `@regression_alarm_ms` (100ms — the Phase 3 target itself, no headroom).
# CI runs this on `ubuntu-latest-4-core` so the runner profile is stable.
#
# WI1 owns the Evaluator. Until WI1 lands the stub at
# lib/barkpark/content/validation/evaluator.ex returns an empty
# diagnostics envelope after walking the rule list, so the bench
# measures rule-list traversal proportional to rule_count rather than
# a no-op return. When WI1 lands the bench will measure the real
# evaluator with no source change.

Code.require_file("support/synthetic_doc.ex", __DIR__)

defmodule Barkpark.Bench.ValidationPerf do
  @field_count 200
  @contributor_count 30
  @rule_count 100
  @iterations 5
  @target_ms 100
  # Phase 3 WI4 dispatch tightened the alarm: CI fails the job when the
  # median run exceeds the target. No headroom — the goal is to catch any
  # drift the moment it happens.
  @regression_alarm_ms 100

  def run do
    {doc, schema} =
      Barkpark.Bench.SyntheticDoc.build(
        field_count: @field_count,
        contributor_count: @contributor_count,
        rule_count: @rule_count
      )

    # Warm-up: load atoms / compile call sites / settle the BEAM JIT before
    # we start timing. Discarded.
    _ = Barkpark.Content.Validation.Evaluator.run(doc, schema, :prepublish)

    times_us =
      for _ <- 1..@iterations do
        {micros, _result} =
          :timer.tc(fn ->
            Barkpark.Content.Validation.Evaluator.run(doc, schema, :prepublish)
          end)

        micros
      end

    times_ms = Enum.map(times_us, &(&1 / 1000.0))
    sorted = Enum.sort(times_ms)
    min = List.first(sorted)
    max = List.last(sorted)
    median = Enum.at(sorted, div(@iterations, 2))
    mean = Enum.sum(times_ms) / @iterations

    IO.puts("""

    === Validation perf bench (Phase 3 WI4) ============================
      doc:           #{@field_count} scalars + #{@contributor_count} contributors
      rules:         #{@rule_count}
      iterations:    #{@iterations}

      min:           #{format_ms(min)}
      median:        #{format_ms(median)}
      mean:          #{format_ms(mean)}
      max:           #{format_ms(max)}

      target:        <#{@target_ms}ms (Phase 3 plan)
      alarm:         >#{@regression_alarm_ms}ms (CI gate — fails the job)
    =====================================================================
    """)

    if median > @regression_alarm_ms do
      IO.puts(:stderr, """
      REGRESSION: median #{format_ms(median)} exceeds alarm threshold \
      #{@regression_alarm_ms}ms.
      """)

      System.halt(1)
    end
  end

  defp format_ms(ms) when is_float(ms) do
    :io_lib.format("~.2fms", [ms]) |> List.to_string()
  end
end

Barkpark.Bench.ValidationPerf.run()
