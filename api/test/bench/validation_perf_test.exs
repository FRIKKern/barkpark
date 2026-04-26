defmodule Barkpark.Bench.ValidationPerfTest do
  @moduledoc """
  Phase 3 WI4 — sanity test for the validation perf bench.

  Asserts only the SHAPE of the synthetic doc + schema produced by
  `Barkpark.Bench.SyntheticDoc.build/1`. Timing is deliberately NOT
  asserted here — the regression gate runs in CI (perf.yml) where the
  runner profile is reproducible. Asserting timing in unit tests would
  produce false positives on shared dev machines.
  """

  use ExUnit.Case, async: true

  # The bench support modules live outside `lib/` so they aren't loaded by
  # the regular compile path. Load explicitly for the test.
  Code.require_file("../../bench/support/synthetic_doc.ex", __DIR__)

  alias Barkpark.Bench.SyntheticDoc

  describe "build/1 — defaults" do
    setup do
      {doc, schema} = SyntheticDoc.build()
      {:ok, doc: doc, schema: schema}
    end

    test "produces 200 top-level scalar fields", %{doc: doc} do
      scalar_keys = doc |> Map.keys() |> Enum.filter(&String.starts_with?(&1, "f_"))
      assert length(scalar_keys) == 200
    end

    test "produces 30 contributors", %{doc: doc} do
      contributors = Map.fetch!(doc, "contributors")
      assert length(contributors) == 30

      assert Enum.all?(contributors, fn c ->
               is_map(c) and
                 Map.has_key?(c, "name") and
                 Map.has_key?(c, "role") and
                 Map.has_key?(c, "isbn")
             end)
    end

    test "produces 100 cross-field validation rules", %{schema: schema} do
      rules = Map.fetch!(schema, "validations")
      assert length(rules) == 100

      kinds = rules |> Enum.map(& &1["kind"]) |> Enum.uniq() |> Enum.sort()
      # All 5 rule kinds should be represented (eq | in | nonempty | matches | codelist_ref).
      assert kinds == ~w(codelist_ref eq in matches nonempty)
    end

    test "schema declares an arrayOf(composite) contributors field", %{schema: schema} do
      contrib_field =
        schema
        |> Map.fetch!("fields")
        |> Enum.find(&(&1["name"] == "contributors"))

      assert contrib_field["type"] == "arrayOf"
      assert contrib_field["of"]["type"] == "composite"
    end
  end

  describe "build/1 — parameterized scales" do
    test "honors :field_count, :contributor_count, :rule_count" do
      {doc, schema} = SyntheticDoc.build(field_count: 5, contributor_count: 2, rule_count: 7)

      assert doc |> Map.keys() |> Enum.count(&String.starts_with?(&1, "f_")) == 5
      assert length(Map.fetch!(doc, "contributors")) == 2
      assert length(Map.fetch!(schema, "validations")) == 7
    end
  end
end
