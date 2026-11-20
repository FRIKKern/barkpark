defmodule Barkpark.Content.CrossRuleCompareTest do
  # task-606283a5dedc2403: a cross rule can compare two fields (`valueField` with
  # gt/gte/lt/lte) and say "exactly one" (`one`). HSO's Sanity rules, as data:
  # an event's end is not before its start; a menu item is a page or an area.
  use ExUnit.Case, async: true

  alias Barkpark.Content.{CrossValidator, FieldVisibility}

  @fields Enum.map(~w(startdato sluttdato side omrade n m), &%{"name" => &1})

  defp schema(rule),
    do: %{"fields" => @fields, "cross_validations" => [Map.put(rule, "name", "r")]}

  defp violated?(rule, doc), do: CrossValidator.violations(schema(rule), doc) != []
  defp skipped?(rule), do: elem(CrossValidator.partition(schema(rule)), 1) != []

  @end_after_start %{
    "rule" => %{"field" => "sluttdato", "operator" => "gte", "valueField" => "startdato"},
    "fields" => ["sluttdato"]
  }

  test "sluttdato before startdato is a cross violation" do
    assert violated?(@end_after_start, %{"startdato" => "2026-11-20", "sluttdato" => "2026-11-19"})

    refute violated?(@end_after_start, %{"startdato" => "2026-11-20", "sluttdato" => "2026-11-20"})

    refute violated?(@end_after_start, %{"startdato" => "2026-11-20", "sluttdato" => "2026-11-21"})
  end

  test "a compare with either side missing, null or empty holds (an optional end date never breaks it)" do
    for doc <- [
          %{"startdato" => "2026-11-20"},
          %{"startdato" => "2026-11-20", "sluttdato" => nil},
          %{"startdato" => "2026-11-20", "sluttdato" => ""},
          %{"sluttdato" => "2026-11-19"},
          %{"startdato" => nil, "sluttdato" => "2026-11-19"},
          %{"startdato" => "", "sluttdato" => "2026-11-19"},
          %{}
        ] do
      refute violated?(@end_after_start, doc), inspect(doc)
    end
  end

  test "numbers compare as numbers, mixed kinds hold, and each operator has its own meaning" do
    cmp = fn op, n, m ->
      not violated?(%{"rule" => %{"field" => "n", "operator" => op, "valueField" => "m"}}, %{
        "n" => n,
        "m" => m
      })
    end

    assert cmp.("gt", 10, 9) and not cmp.("gt", 9, 9) and not cmp.("gt", 9, 10)
    assert cmp.("gte", 9, 9) and not cmp.("gte", 8, 9)
    assert cmp.("lt", 8, 9) and not cmp.("lt", 9, 9)
    assert cmp.("lte", 9, 9) and not cmp.("lte", 10, 9)
    assert cmp.("gt", 1.5, 1) and cmp.("lt", 2, 10)
    assert cmp.("gt", "9", 10) and cmp.("lt", [1], 2)
  end

  test "a compare with a plain value works too" do
    rule = %{"rule" => %{"field" => "n", "operator" => "gte", "value" => 3}}
    assert violated?(rule, %{"n" => 2})
    refute violated?(rule, %{"n" => 3})
  end

  @one_of %{
    "rule" => %{
      "one" => [
        %{"field" => "side", "operator" => "non_empty"},
        %{"field" => "omrade", "operator" => "non_empty"}
      ]
    },
    "fields" => ["side"]
  }

  test "exactly one: both set is violated, none is violated, one is ok" do
    assert violated?(@one_of, %{"side" => "om-oss", "omrade" => "omrade-a"})
    assert violated?(@one_of, %{})
    assert violated?(@one_of, %{"side" => "", "omrade" => nil})
    refute violated?(@one_of, %{"side" => "om-oss"})
    refute violated?(@one_of, %{"omrade" => "omrade-a"})
  end

  test "one nests inside all / any and holds the same in visibleWhen" do
    nested = %{
      "rule" => %{"all" => [%{"field" => "n", "operator" => "non_empty"}, @one_of["rule"]]}
    }

    assert violated?(nested, %{"n" => 1, "side" => "a", "omrade" => "b"})
    refute violated?(nested, %{"n" => 1, "side" => "a"})
    field = %{"name" => "x", "visibleWhen" => @one_of["rule"]}
    assert FieldVisibility.visible?(field, %{"side" => "a"})
    refute FieldVisibility.visible?(field, %{"side" => "a", "omrade" => "b"})
  end

  test "malformed new shapes are unevaluable, as other malformed rules: never a finding" do
    assert skipped?(%{
             "rule" => %{"field" => "sluttdato", "operator" => "gte", "valueField" => "nope"}
           })

    assert skipped?(%{
             "rule" => %{"field" => "sluttdato", "operator" => "gte", "valueField" => ""}
           })

    assert skipped?(%{
             "rule" => %{"field" => "sluttdato", "operator" => "gte", "valueField" => 3}
           })

    assert skipped?(%{"rule" => %{"one" => "side"}})
    assert skipped?(%{"rule" => %{"one" => []}})
    refute violated?(%{"rule" => %{"one" => "side"}}, %{"side" => "a", "omrade" => "b"})
    refute skipped?(@end_after_start)
    refute skipped?(@one_of)
  end

  test "a compare in visibleWhen reads valueField from the same root" do
    field = %{
      "name" => "x",
      "visibleWhen" => %{"field" => "n", "operator" => "gt", "valueField" => "m"}
    }

    assert FieldVisibility.visible?(field, %{"n" => 2, "m" => 1})
    refute FieldVisibility.visible?(field, %{"n" => 1, "m" => 2})
    assert FieldVisibility.visible?(field, %{"n" => 1})
  end
end
