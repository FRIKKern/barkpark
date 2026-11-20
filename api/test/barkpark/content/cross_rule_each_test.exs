defmodule Barkpark.Content.CrossRuleEachTest do
  # task-5bb338ffd4621865: a cross rule scoped to each list item (`each`, with
  # an optional member `type`). HSO's Sanity rules as data: a menu item (and a
  # sub-item) links a page or an area, exactly one; a sakerFraKnagg block has a
  # tag or a pilot.
  use ExUnit.Case, async: true

  alias Barkpark.Content.CrossValidator

  @fields Enum.map(~w(meny innhold tittel innstillinger), &%{"name" => &1})

  defp schema(rules), do: %{"fields" => @fields, "cross_validations" => List.wrap(rules)}
  defp paths(rules, doc), do: for(f <- errors(rules, doc), do: f.path)
  defp errors(rules, doc), do: CrossValidator.findings(schema(rules), doc).errors
  defp skipped?(rule), do: elem(CrossValidator.partition(schema(rule)), 1) != []

  defp side_or_omrade(each, extra \\ %{}) do
    Map.merge(
      %{
        "name" => "side_eller_omrade",
        "title" => "Velg en side eller et område",
        "each" => each,
        "fields" => ["side"],
        "rule" => %{
          "one" => [
            %{"field" => "side", "operator" => "non_empty"},
            %{"field" => "omrade", "operator" => "non_empty"}
          ]
        }
      },
      extra
    )
  end

  @tag_or_pilot %{
    "name" => "knagg_eller_pilot",
    "title" => "Velg en emneknagg eller en pilot",
    "each" => "innhold",
    "type" => "sakerFraKnagg",
    "rule" => %{
      "any" => [
        %{"field" => "emneknagg", "operator" => "non_empty"},
        %{"field" => "pilot", "operator" => "non_empty"}
      ]
    }
  }

  test "a meny item with neither side nor omrade reports meny[1]" do
    doc = %{
      "meny" => [
        %{"_key" => "a", "side" => %{"_ref" => "om-oss"}},
        %{"_key" => "b", "tittel" => "Tom"},
        %{"_key" => "c", "omrade" => %{"_ref" => "omrade-1"}}
      ]
    }

    assert [%{path: "/meny/1/side", message: "Velg en side eller et område"} = f] =
             errors(side_or_omrade("meny"), doc)

    assert f.code == :cross_validation

    assert paths(side_or_omrade("meny"), put_in(doc, ["meny"], tl(doc["meny"]))) == [
             "/meny/0/side"
           ]
  end

  test "both side and omrade is violated too; each broken item is its own finding" do
    doc = %{"meny" => [%{"side" => "s", "omrade" => "o"}, %{"side" => "s"}, %{}]}
    assert paths(side_or_omrade("meny"), doc) == ["/meny/0/side", "/meny/2/side"]
  end

  test "each walks through lists on the way: meny.under items are checked one by one" do
    doc = %{
      "meny" => [
        %{"side" => "s", "under" => [%{"side" => "s"}, %{}]},
        %{"omrade" => "o", "under" => [%{"side" => "s", "omrade" => "o"}]},
        %{"side" => "s"}
      ]
    }

    assert paths(side_or_omrade("meny.under"), doc) == [
             "/meny/0/under/1/side",
             "/meny/1/under/0/side"
           ]
  end

  test "a rule with each + type skips items of other member types" do
    doc = %{
      "innhold" => [
        %{"_type" => "tekst"},
        %{"_type" => "sakerFraKnagg", "emneknagg" => %{"_ref" => "k"}},
        %{"_type" => "sakerFraKnagg"},
        %{"_type" => "sakerFraKnagg", "pilot" => %{"_ref" => "p"}},
        %{}
      ]
    }

    assert paths(@tag_or_pilot, doc) == ["/innhold/2"]
    assert paths(Map.put(@tag_or_pilot, "type", "ingenting"), doc) == []
  end

  test "a leaf reads the item; scope parent is the item too; scope document reads the root" do
    rule = fn leaf -> %{"name" => "r", "each" => "meny", "rule" => leaf} end
    doc = %{"tittel" => "Rot", "meny" => [%{"tittel" => "Element"}]}
    item = %{"field" => "tittel", "operator" => "eq", "value" => "Element"}
    root = %{"field" => "tittel", "operator" => "eq", "value" => "Rot"}

    assert paths(rule.(item), doc) == []
    assert paths(rule.(Map.put(item, "scope", "parent")), doc) == []
    assert paths(rule.(Map.put(root, "scope", "document")), doc) == []
    assert paths(rule.(root), doc) == ["/meny/0"]
    assert paths(rule.(%{"all" => [item, Map.put(root, "scope", "document")]}), doc) == []
  end

  test "odd lists hold: missing, not a list, scalars, lists of lists, no _key" do
    rule = side_or_omrade("meny")

    for doc <- [
          %{},
          %{"meny" => nil},
          %{"meny" => "tekst"},
          %{"meny" => %{"side" => nil}},
          %{"meny" => ["a", 1, nil]},
          %{"meny" => [[%{}]]}
        ] do
      assert paths(rule, doc) == [], inspect(doc)
    end

    assert paths(rule, %{"meny" => [%{"tittel" => "uten nøkkel"}]}) == ["/meny/0/side"]
  end

  test "each through an object: innstillinger.meny" do
    doc = %{"innstillinger" => %{"meny" => [%{"side" => "s"}, %{}]}}
    assert paths(side_or_omrade("innstillinger.meny"), doc) == ["/innstillinger/meny/1/side"]
  end

  test "malformed item rules are unevaluable, never a finding" do
    assert skipped?(side_or_omrade("nope"))
    assert skipped?(side_or_omrade(""))
    assert skipped?(side_or_omrade(3))
    assert skipped?(side_or_omrade("meny", %{"type" => ""}))
    assert skipped?(side_or_omrade("meny", %{"type" => 7}))
    assert skipped?(Map.delete(@tag_or_pilot, "each"))
    assert skipped?(side_or_omrade("meny", %{"rule" => %{"one" => "side"}}))

    assert skipped?(
             side_or_omrade("meny", %{"rule" => %{"field" => "tittel", "operator" => "nope"}})
           )

    assert skipped?(
             side_or_omrade("meny", %{
               "rule" => %{"field" => "nope", "operator" => "empty", "scope" => "document"}
             })
           )

    refute skipped?(side_or_omrade("meny"))
    refute skipped?(@tag_or_pilot)
    assert errors(side_or_omrade("nope"), %{"nope" => [%{}]}) == []
  end

  test "a rule with no fields reports the item itself, and a warning-level item rule is a warning" do
    rule = Map.put(Map.delete(side_or_omrade("meny"), "fields"), "level", "warning")
    %{errors: [], warnings: [w]} = CrossValidator.findings(schema(rule), %{"meny" => [%{}]})
    assert w.path == "/meny/0"
  end

  test "plain rules are as before: one violation, no item" do
    plain = %{
      "name" => "p",
      "fields" => ["tittel"],
      "rule" => %{"field" => "tittel", "operator" => "non_empty"}
    }

    assert [v] = CrossValidator.violations(schema(plain), %{})
    refute Map.has_key?(v, "item")
    assert paths(plain, %{}) == ["/tittel"]
    assert [%{"satisfied" => true}] = CrossValidator.validate(schema(plain), %{"tittel" => "t"})

    assert [%{"satisfied" => false}] =
             CrossValidator.validate(schema(side_or_omrade("meny")), %{"meny" => [%{}]})
  end
end
