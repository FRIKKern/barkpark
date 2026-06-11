defmodule BarkparkWeb.Components.Fields.VisibilityTest do
  use ExUnit.Case, async: true

  alias BarkparkWeb.Components.Fields.Visibility
  alias Barkpark.Content.SchemaDefinition.Field

  describe "visible?/2 — back-compat" do
    test "missing visibleWhen → visible" do
      assert Visibility.visible?(%{"name" => "title"}, %{}) == true
    end

    test "nil visibleWhen → visible" do
      assert Visibility.visible?(%{"name" => "title", "visibleWhen" => nil}, %{}) == true
    end

    test "non-map doc → visible (defensive default)" do
      assert Visibility.visible?(
               %{"visibleWhen" => %{"field" => "x", "operator" => "eq", "value" => 1}},
               nil
             ) ==
               true
    end

    test "unknown operator → defaults to visible" do
      field = %{"visibleWhen" => %{"field" => "x", "operator" => "wat", "value" => 1}}
      assert Visibility.visible?(field, %{"x" => 1}) == true
      assert Visibility.visible?(field, %{"x" => 99}) == true
    end
  end

  describe "operator: eq / neq" do
    test "eq matches" do
      field = %{"visibleWhen" => %{"field" => "kind", "operator" => "eq", "value" => "REL"}}
      assert Visibility.visible?(field, %{"kind" => "REL"}) == true
      assert Visibility.visible?(field, %{"kind" => "FIC"}) == false
    end

    test "neq inverse" do
      field = %{"visibleWhen" => %{"field" => "kind", "operator" => "neq", "value" => "REL"}}
      assert Visibility.visible?(field, %{"kind" => "FIC"}) == true
      assert Visibility.visible?(field, %{"kind" => "REL"}) == false
    end
  end

  describe "operator: in" do
    test "value is in list" do
      field = %{"visibleWhen" => %{"field" => "kind", "operator" => "in", "value" => ["A", "B"]}}
      assert Visibility.visible?(field, %{"kind" => "A"}) == true
      assert Visibility.visible?(field, %{"kind" => "C"}) == false
    end

    test "value param not a list → not visible (no semantic)" do
      field = %{"visibleWhen" => %{"field" => "kind", "operator" => "in", "value" => "A"}}
      assert Visibility.visible?(field, %{"kind" => "A"}) == false
    end
  end

  describe "operator: empty / non_empty" do
    test "empty handles nil, \"\", [], %{}" do
      f = %{"visibleWhen" => %{"field" => "x", "operator" => "empty"}}
      assert Visibility.visible?(f, %{}) == true
      assert Visibility.visible?(f, %{"x" => nil}) == true
      assert Visibility.visible?(f, %{"x" => ""}) == true
      assert Visibility.visible?(f, %{"x" => []}) == true
      assert Visibility.visible?(f, %{"x" => %{}}) == true
      assert Visibility.visible?(f, %{"x" => "hi"}) == false
      assert Visibility.visible?(f, %{"x" => [1]}) == false
      assert Visibility.visible?(f, %{"x" => %{"k" => "v"}}) == false
    end

    test "non_empty is the inverse" do
      f = %{"visibleWhen" => %{"field" => "x", "operator" => "non_empty"}}
      assert Visibility.visible?(f, %{}) == false
      assert Visibility.visible?(f, %{"x" => ""}) == false
      assert Visibility.visible?(f, %{"x" => []}) == false
      assert Visibility.visible?(f, %{"x" => "hi"}) == true
      assert Visibility.visible?(f, %{"x" => [1]}) == true
    end
  end

  describe "operator: starts_with" do
    test "string prefix match" do
      f = %{"visibleWhen" => %{"field" => "code", "operator" => "starts_with", "value" => "REL"}}
      assert Visibility.visible?(f, %{"code" => "REL123"}) == true
      assert Visibility.visible?(f, %{"code" => "FIC123"}) == false
    end

    test "non-string value → false" do
      f = %{"visibleWhen" => %{"field" => "code", "operator" => "starts_with", "value" => "REL"}}
      assert Visibility.visible?(f, %{"code" => 123}) == false
      assert Visibility.visible?(f, %{"code" => nil}) == false
    end
  end

  describe "dotted-path walking" do
    test "walks through nested maps" do
      f = %{"visibleWhen" => %{"field" => "audience.code", "operator" => "eq", "value" => "11"}}
      assert Visibility.visible?(f, %{"audience" => %{"code" => "11"}}) == true
      assert Visibility.visible?(f, %{"audience" => %{"code" => "22"}}) == false
      assert Visibility.visible?(f, %{"audience" => %{}}) == false
      assert Visibility.visible?(f, %{}) == false
    end

    test "walks through array → flat list of leaf values" do
      f = %{
        "visibleWhen" => %{
          "field" => "subjects.subject.subjectCode",
          "operator" => "in",
          "value" => ["REL"]
        }
      }

      doc = %{
        "subjects" => [
          %{"subject" => %{"subjectCode" => "FIC"}},
          %{"subject" => %{"subjectCode" => "REL"}}
        ]
      }

      # `in` against a list value won't match — list isn't in ["REL"].
      # But `non_empty` proves the walk found values.
      assert Visibility.visible?(f, doc) == false

      f2 = %{
        "visibleWhen" => %{"field" => "subjects.subject.subjectCode", "operator" => "non_empty"}
      }

      assert Visibility.visible?(f2, doc) == true

      f3 = %{
        "visibleWhen" => %{
          "field" => "subjects.subject.subjectCode",
          "operator" => "non_empty"
        }
      }

      assert Visibility.visible?(f3, %{"subjects" => []}) == false
    end
  end

  describe "field shape handling" do
    test "%Field{} struct → reads visibleWhen off field.raw" do
      field = %Field{
        name: "audienceRanges",
        type: "arrayOf",
        raw: %{
          "name" => "audienceRanges",
          "visibleWhen" => %{"field" => "audienceCodes", "operator" => "non_empty"}
        }
      }

      assert Visibility.visible?(field, %{"audienceCodes" => [%{"audienceCodeValue" => "01"}]}) ==
               true

      assert Visibility.visible?(field, %{"audienceCodes" => []}) == false
      assert Visibility.visible?(field, %{}) == false
    end

    test "atom-keyed top-level visibleWhen" do
      field = %{visibleWhen: %{"field" => "x", "operator" => "eq", "value" => 1}}
      assert Visibility.visible?(field, %{"x" => 1}) == true
      assert Visibility.visible?(field, %{"x" => 2}) == false
    end

    test "atom-keyed predicate body" do
      field = %{"visibleWhen" => %{field: "x", operator: "eq", value: 1}}
      assert Visibility.visible?(field, %{"x" => 1}) == true
      assert Visibility.visible?(field, %{"x" => 2}) == false
    end
  end
end
