defmodule Barkpark.Content.CrossValidatorTest do
  use ExUnit.Case, async: true

  alias Barkpark.Content.CrossValidator

  # ─── helpers ────────────────────────────────────────────────────────────────

  defp rule(name, predicate, opts \\ []) do
    %{
      "name" => name,
      "title" => Keyword.get(opts, :title, name),
      "rule" => predicate,
      "level" => Keyword.get(opts, :level, "error"),
      "fields" => Keyword.get(opts, :fields, [])
    }
  end

  defp schema_with(rules), do: %{"cross_validations" => rules}

  # ─── empty / shape ──────────────────────────────────────────────────────────

  describe "validate/2 — no rules" do
    test "no cross_validations key → []" do
      assert CrossValidator.validate(%{}, %{}) == []
    end

    test "empty list of rules → []" do
      assert CrossValidator.validate(schema_with([]), %{}) == []
    end

    test "nil schema → []" do
      assert CrossValidator.validate(nil, %{}) == []
    end

    test "raw list of rules accepted (bypasses schema wrapper)" do
      r = [rule("r1", %{"field" => "x", "operator" => "non_empty"})]
      [out] = CrossValidator.validate(r, %{"x" => "v"})
      assert out["satisfied"]
    end

    test "atom-keyed cross_validations works too" do
      r = [rule("r1", %{"field" => "x", "operator" => "non_empty"})]
      [out] = CrossValidator.validate(%{cross_validations: r}, %{"x" => "v"})
      assert out["satisfied"]
    end
  end

  # ─── single-predicate rules ────────────────────────────────────────────────

  describe "single-field predicates" do
    test "non_empty on populated field → satisfied" do
      r = [rule("r", %{"field" => "title", "operator" => "non_empty"})]
      [out] = CrossValidator.validate(schema_with(r), %{"title" => "Hello"})
      assert out["satisfied"]
    end

    test "non_empty on empty/missing field → violation; banner sees fields" do
      r =
        [
          rule("r", %{"field" => "title", "operator" => "non_empty"},
            fields: ["title"],
            title: "Title required"
          )
        ]

      [out] = CrossValidator.validate(schema_with(r), %{})
      refute out["satisfied"]

      [v] = CrossValidator.violations(schema_with(r), %{})
      assert v["fields"] == ["title"]
      assert v["title"] == "Title required"
      assert v["level"] == "error"
    end

    test "eq with matching value → satisfied" do
      r = [rule("r", %{"field" => "kind", "operator" => "eq", "value" => "REL"})]
      [out] = CrossValidator.validate(schema_with(r), %{"kind" => "REL"})
      assert out["satisfied"]
    end
  end

  # ─── combinators ───────────────────────────────────────────────────────────

  describe "all combinator" do
    test "all true → satisfied" do
      r =
        [
          rule("r", %{
            "all" => [
              %{"field" => "a", "operator" => "non_empty"},
              %{"field" => "b", "operator" => "non_empty"}
            ]
          })
        ]

      [out] = CrossValidator.validate(schema_with(r), %{"a" => 1, "b" => 2})
      assert out["satisfied"]
    end

    test "one false → violation" do
      r =
        [
          rule("r", %{
            "all" => [
              %{"field" => "a", "operator" => "non_empty"},
              %{"field" => "b", "operator" => "non_empty"}
            ]
          })
        ]

      refute hd(CrossValidator.validate(schema_with(r), %{"a" => 1}))["satisfied"]
    end
  end

  describe "any combinator" do
    test "any one true → satisfied" do
      r =
        [
          rule("r", %{
            "any" => [
              %{"field" => "isbn", "operator" => "non_empty"},
              %{"field" => "gtin", "operator" => "non_empty"}
            ]
          })
        ]

      [out] = CrossValidator.validate(schema_with(r), %{"isbn" => "978…"})
      assert out["satisfied"]
    end

    test "all false → violation" do
      r =
        [
          rule("r", %{
            "any" => [
              %{"field" => "isbn", "operator" => "non_empty"},
              %{"field" => "gtin", "operator" => "non_empty"}
            ]
          })
        ]

      refute hd(CrossValidator.validate(schema_with(r), %{}))["satisfied"]
    end
  end

  # ─── nested-path predicates ────────────────────────────────────────────────

  describe "nested-path predicates" do
    test "dotted path resolves through nested map" do
      r = [rule("r", %{"field" => "publishingDetail.imprint", "operator" => "non_empty"})]

      [out] =
        CrossValidator.validate(
          schema_with(r),
          %{"publishingDetail" => %{"imprint" => "Aschehoug"}}
        )

      assert out["satisfied"]
    end

    test "list-traversal flat-maps inner path (productIdentifiers.idValue)" do
      r = [rule("r", %{"field" => "productIdentifiers.idValue", "operator" => "non_empty"})]

      [out] =
        CrossValidator.validate(
          schema_with(r),
          %{
            "productIdentifiers" => [
              %{"productIdType" => "15", "idValue" => "9788234710987"}
            ]
          }
        )

      assert out["satisfied"]
    end
  end

  # ─── violations/2 sugar ────────────────────────────────────────────────────

  describe "violations/2" do
    test "returns only unsatisfied rules; banner-ready shape" do
      rules = [
        rule("good", %{"field" => "a", "operator" => "non_empty"}, fields: ["a"]),
        rule("bad", %{"field" => "b", "operator" => "non_empty"},
          fields: ["b"],
          level: "warning",
          title: "B is empty"
        )
      ]

      doc = %{"a" => 1, "b" => nil}
      out = CrossValidator.violations(schema_with(rules), doc)

      assert length(out) == 1
      v = hd(out)
      assert v["name"] == "bad"
      assert v["level"] == "warning"
      assert v["title"] == "B is empty"
      assert v["fields"] == ["b"]
      refute v["satisfied"]
    end

    test "satisfied annotation is always present (true OR false)" do
      r = [rule("r", %{"field" => "x", "operator" => "non_empty"})]
      [out] = CrossValidator.validate(schema_with(r), %{"x" => 1})
      assert is_boolean(out["satisfied"])
    end
  end
end
