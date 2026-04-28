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
# `Barkpark.Content.Validation.Evaluator.run_rules/3` 5 times and prints
# min / median / max / mean wall-clock time in milliseconds.
#
# CI regression alarm: exits with status 1 if the median run exceeds
# `@regression_alarm_ms` (100ms — the Phase 3 target itself, no headroom).
# CI runs this on `ubuntu-latest-4-core` so the runner profile is stable.
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
  @iterations 5
  @target_ms 100
  # Phase 3 WI4 dispatch tightened the alarm: CI fails the job when the
  # median run exceeds the target. No headroom — the goal is to catch any
  # drift the moment it happens.
  @regression_alarm_ms 100
  @tag :mutate

  def run do
    doc = build_doc(@field_count, @contributor_count)
    rules = build_rules(@rule_count, @field_count)

    # Warm-up: load atoms / compile call sites / settle the BEAM JIT before
    # we start timing. Discarded.
    _ = Evaluator.run_rules(doc, rules, @tag)

    times_us =
      for _ <- 1..@iterations do
        {micros, _result} =
          :timer.tc(fn ->
            Evaluator.run_rules(doc, rules, @tag)
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
    :io_lib.format("~.2fms", [ms]) |> List.to_string()
  end
end

Barkpark.Bench.ValidationPerf.run()
