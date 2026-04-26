defmodule Barkpark.Bench.SyntheticDoc do
  @moduledoc """
  Synthetic document + schema generator for the validation perf bench.

  Phase 3 WI4 — produces a realistic stress workload:

    * `field_count` (default 200) flat scalar fields (mixed string / boolean /
      datetime / number) at the top level of the document.
    * `contributor_count` (default 30) elements in an `arrayOf(composite)`
      array under `"contributors"`, each carrying name + role + optional ISBN.
    * `rule_count` (default 100) cross-field validation rules in the schema's
      top-level `validations: [...]` slot. Rules are a mix of
      `eq | in | nonempty | matches | codelist_ref` so the evaluator's
      hot-path branches are exercised in proportion.

  The generator is intentionally deterministic (no `:rand`) so bench runs are
  reproducible across the 5-iteration timing loop.

  Returned shape: `{doc :: map(), schema :: map()}`. Both are plain maps in
  the same shape consumed by `Barkpark.Content.Validation.Evaluator.run/3`.

  WI3 owns the `codelist_ref` checker. While WI3 is unmerged the synthetic
  schema still references `:codelist_ref` rules — the stubbed Evaluator
  short-circuits, so the bench remains runnable. When WI3 lands the bench
  measures real registry lookups; no source change required.
  """

  @default_field_count 200
  @default_contributor_count 30
  @default_rule_count 100

  @rule_kinds ~w(eq in nonempty matches codelist_ref)a

  @doc """
  Build `{doc, schema}` with the given size knobs.

  Options:

    * `:field_count` — top-level scalar fields. Default 200.
    * `:contributor_count` — `contributors` array length. Default 30.
    * `:rule_count` — top-level validation rules. Default 100.
  """
  def build(opts \\ []) do
    field_count = Keyword.get(opts, :field_count, @default_field_count)
    contributor_count = Keyword.get(opts, :contributor_count, @default_contributor_count)
    rule_count = Keyword.get(opts, :rule_count, @default_rule_count)

    doc = build_doc(field_count, contributor_count)
    schema = build_schema(field_count, contributor_count, rule_count)

    {doc, schema}
  end

  # ── doc ────────────────────────────────────────────────────────────────────

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

  defp pad2(n) when n < 10, do: "0#{n}"
  defp pad2(n), do: "#{n}"

  defp pad3(n) when n < 10, do: "00#{n}"
  defp pad3(n) when n < 100, do: "0#{n}"
  defp pad3(n), do: "#{n}"

  # `contributor_role/1` — pick a plausible Thema/ONIX role code so codelist
  # rules have something realistic to match against.
  defp contributor_role(i) do
    case rem(i, 5) do
      0 -> "A01"
      1 -> "A02"
      2 -> "A12"
      3 -> "B01"
      _ -> "Z99"
    end
  end

  # ── schema ─────────────────────────────────────────────────────────────────

  defp build_schema(field_count, contributor_count, rule_count) do
    fields =
      for i <- 1..field_count do
        %{
          "name" => "f_#{i}",
          "type" => scalar_type(i),
          "title" => "Field #{i}"
        }
      end

    contributors_field = %{
      "name" => "contributors",
      "type" => "arrayOf",
      "of" => %{
        "type" => "composite",
        "fields" => [
          %{"name" => "name", "type" => "string"},
          %{"name" => "role", "type" => "string"},
          %{"name" => "isbn", "type" => "string"}
        ]
      },
      "ordered" => true
    }

    %{
      "name" => "bench_book",
      "title" => "Bench Book",
      "fields" => fields ++ [contributors_field],
      "validations" => build_rules(rule_count, field_count, contributor_count)
    }
  end

  defp scalar_type(i) do
    case rem(i, 4) do
      0 -> "string"
      1 -> "boolean"
      2 -> "datetime"
      3 -> "number"
    end
  end

  defp build_rules(rule_count, field_count, _contributor_count) do
    for i <- 1..rule_count do
      kind = Enum.at(@rule_kinds, rem(i, length(@rule_kinds)))
      build_rule(kind, i, field_count)
    end
  end

  defp build_rule(:eq, i, field_count) do
    %{
      "id" => "rule_eq_#{i}",
      "kind" => "eq",
      "field" => "f_#{rem(i, field_count) + 1}",
      "expected" => "value-#{rem(i, field_count) + 1}",
      "severity" => "error"
    }
  end

  defp build_rule(:in, i, field_count) do
    %{
      "id" => "rule_in_#{i}",
      "kind" => "in",
      "field" => "f_#{rem(i, field_count) + 1}",
      "values" => ["a", "b", "c"],
      "severity" => "warning"
    }
  end

  defp build_rule(:nonempty, i, _field_count) do
    %{
      "id" => "rule_nonempty_#{i}",
      "kind" => "nonempty",
      "field" => "contributors",
      "severity" => "error"
    }
  end

  defp build_rule(:matches, i, _field_count) do
    %{
      "id" => "rule_matches_#{i}",
      "kind" => "matches",
      "field" => "contributors.#{rem(i, 30)}.isbn",
      "checker" => "isbn13Checksum",
      "severity" => "error"
    }
  end

  defp build_rule(:codelist_ref, i, _field_count) do
    %{
      "id" => "rule_codelist_#{i}",
      "kind" => "codelist_ref",
      "field" => "contributors.#{rem(i, 30)}.role",
      "codelist" => "onix.contributorRole",
      "version" => 73,
      "severity" => "error"
    }
  end
end
