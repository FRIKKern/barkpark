defmodule Barkpark.Content.ValidationListMembershipTest do
  @moduledoc """
  task-400a66c6ebd31026: a value outside its list is an error finding.

  Before, a select value outside `options.list` and a codelist code the
  registered codelist does not hold were stored with no finding, and they
  published. Validation checked `options.list` only inside Paper object
  blocks, and codelists for shape only.

  Findings stay advisory on save (the draft is stored, the error shows under
  the field); the Studio publish and an enforcing dataset refuse errors. A
  flat (v1) schema is left as it is: its validator is frozen.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Content.Codelists
  alias Barkpark.Content.Validation

  setup do
    n = System.unique_integer([:positive])
    flat = "onixedit:lm-flat-#{n}"
    tree = "onixedit:lm-tree-#{n}"

    {:ok, _} =
      Codelists.register("onixedit", flat, %{
        issue: "1",
        name: "Flat",
        values: [
          %{code: "A1", translations: [%{language: "eng", label: "A one"}]},
          %{code: "B2", translations: [%{language: "eng", label: "B two"}]}
        ]
      })

    children =
      for i <- 1..3,
          do: %{code: "FB00#{i}", translations: [%{language: "eng", label: "F#{i}"}]}

    {:ok, _} =
      Codelists.register("onixedit", tree, %{
        issue: "1",
        name: "Tree",
        values: [
          %{code: "FB", translations: [%{language: "eng", label: "Fiction"}], children: children}
        ]
      })

    schema = %{
      "name" => "lm_book",
      "fields" => [
        %{"name" => "title", "type" => "string"},
        %{"name" => "stage", "type" => "string", "options" => %{"list" => ["draft", "review"]}},
        %{
          "name" => "form",
          "type" => "string",
          "options" => %{"list" => [%{"title" => "Hard", "value" => "BB"}]}
        },
        %{"name" => "flat", "type" => "codelist", "codelistId" => flat},
        %{"name" => "subject", "type" => "codelist", "codelistId" => tree},
        %{"name" => "gone", "type" => "codelist", "codelistId" => "onixedit:lm-none-#{n}"}
      ]
    }

    %{schema: schema, flat: flat, tree: tree}
  end

  defp codes(content, schema) do
    %{errors: errors} = Validation.check_findings(content, "T", schema)
    Enum.map(errors, &{&1.path, &1.code})
  end

  test "a select value outside options.list is an error; strings and {title, value} lists", c do
    assert codes(%{"stage" => "NOPE"}, c.schema) == [{"/stage", :not_in_list}]
    assert codes(%{"form" => "XX"}, c.schema) == [{"/form", :not_in_list}]
    assert codes(%{"stage" => "review", "form" => "BB"}, c.schema) == []
  end

  test "an unset select is not a choice: no finding", c do
    assert codes(%{"stage" => ""}, c.schema) == []
    assert codes(%{}, c.schema) == []
  end

  test "a flat codelist code the codelist does not hold is an error", c do
    assert codes(%{"flat" => "NOPE"}, c.schema) == [{"/flat", :not_in_codelist}]
    assert codes(%{"flat" => "B2"}, c.schema) == []
  end

  test "a tree codelist: a child or a parent code is a member, any other is an error", c do
    assert codes(%{"subject" => "FB002"}, c.schema) == []
    assert codes(%{"subject" => "FB"}, c.schema) == []
    assert codes(%{"subject" => "NOPE"}, c.schema) == [{"/subject", :not_in_codelist}]
  end

  test "an empty code and an unregistered codelist behave as before", c do
    assert codes(%{"flat" => ""}, c.schema) == [{"/flat", :codelist_empty}]
    assert codes(%{"gone" => "ANY"}, c.schema) == []
  end

  test "the finding names the value and the codelist", c do
    %{errors: [finding]} = Validation.check_findings(%{"flat" => "NOPE"}, "T", c.schema)
    assert finding.message == ~s("NOPE" is not a code in #{c.flat})
    assert finding.params == %{codelist: c.flat, value: "NOPE"}
    assert :not_in_codelist in Validation.known_codes()
  end

  test "a value out of its list is not a warning", c do
    %{warnings: warnings} =
      Validation.check_findings(%{"stage" => "NOPE", "flat" => "NOPE"}, "T", c.schema)

    assert warnings == []
  end

  test "a flat (v1) schema is left as it is" do
    v1 = %{
      "name" => "lm_v1",
      "fields" => [
        %{"name" => "title", "type" => "string"},
        %{"name" => "stage", "type" => "string", "options" => %{"list" => ["draft"]}}
      ]
    }

    assert codes(%{"stage" => "NOPE"}, v1) == []
  end
end
