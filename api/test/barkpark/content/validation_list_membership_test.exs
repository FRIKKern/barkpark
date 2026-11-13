defmodule Barkpark.Content.ValidationListMembershipTest do
  @moduledoc """
  task-400a66c6ebd31026: a value outside its list is a warning finding.

  Before, a select value outside `options.list` and a codelist code the
  registered codelist does not hold were stored with no finding, and they
  published. Validation checked `options.list` only inside Paper object
  blocks, and codelists for shape only.

  A WARNING, never an error (owner ruling via main, 2026-11-13): documents
  already in production may hold out-of-list values, so it shows under the
  field and refuses neither a save, a publish, nor a write to an enforcing
  dataset. Paper object blocks keep their own error. A codelist costs one
  read per warning pass. A flat (v1) schema is left as it is: its validator
  is frozen.
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
    %{warnings: warnings} = Validation.check_findings(content, "T", schema)
    Enum.map(warnings, &{&1.path, &1.code})
  end

  test "a select value outside options.list is a warning; strings and {title, value} lists", c do
    assert codes(%{"stage" => "NOPE"}, c.schema) == [{"/stage", :not_in_list}]
    assert codes(%{"form" => "XX"}, c.schema) == [{"/form", :not_in_list}]
    assert codes(%{"stage" => "review", "form" => "BB"}, c.schema) == []
  end

  test "an unset select is not a choice: no finding", c do
    assert codes(%{"stage" => ""}, c.schema) == []
    assert codes(%{}, c.schema) == []
  end

  test "a flat codelist code the codelist does not hold is a warning", c do
    assert codes(%{"flat" => "NOPE"}, c.schema) == [{"/flat", :not_in_codelist}]
    assert codes(%{"flat" => "B2"}, c.schema) == []
  end

  test "a tree codelist: a child or a parent code is a member, any other is a warning", c do
    assert codes(%{"subject" => "FB002"}, c.schema) == []
    assert codes(%{"subject" => "FB"}, c.schema) == []
    assert codes(%{"subject" => "NOPE"}, c.schema) == [{"/subject", :not_in_codelist}]
  end

  test "an empty code and an unregistered codelist behave as before", c do
    %{errors: errors} = Validation.check_findings(%{"flat" => ""}, "T", c.schema)
    assert Enum.map(errors, &{&1.path, &1.code}) == [{"/flat", :codelist_empty}]
    assert codes(%{"flat" => ""}, c.schema) == []
    assert codes(%{"gone" => "ANY"}, c.schema) == []
  end

  test "the finding names the value and the codelist", c do
    %{warnings: [finding]} = Validation.check_findings(%{"flat" => "NOPE"}, "T", c.schema)
    assert finding.message == ~s("NOPE" is not a code in #{c.flat})
    assert finding.params == %{codelist: c.flat, value: "NOPE"}
    assert :not_in_codelist in Validation.known_codes()
  end

  test "a value out of its list is not an error: validate/3 passes it", c do
    content = %{"stage" => "NOPE", "form" => "XX", "flat" => "NOPE", "subject" => "NOPE"}
    %{errors: errors} = Validation.check_findings(content, "T", c.schema)

    assert errors == []
    assert Validation.validate(content, "T", c.schema) == {:ok, content}
  end

  test "an enforcing dataset takes the write (no 422)", c do
    dataset = "lm-enforce-#{System.unique_integer([:positive])}"

    {:ok, _} =
      c.schema
      |> Map.merge(%{"title" => "LM", "visibility" => "public"})
      |> Barkpark.Content.upsert_schema(dataset)

    previous = Application.get_env(:barkpark, Validation, [])
    Application.put_env(:barkpark, Validation, enforce_datasets: [dataset])
    on_exit(fn -> Application.put_env(:barkpark, Validation, previous) end)

    attrs = %{"title" => "T", "content" => %{"stage" => "NOPE", "flat" => "NOPE"}}

    assert Barkpark.Content.Writer.check_document_schema("lm_book", attrs, dataset) == :ok
  end

  test "one codelist read per warning pass, however many codelist values", c do
    content = %{"flat" => "NOPE", "subject" => "FB002", "gone" => "ANY"}
    ref = make_ref()
    me = self()

    :telemetry.attach(
      inspect(ref),
      [:barkpark, :repo, :query],
      fn _, _, meta, _ ->
        if meta.query =~ "codelist", do: send(me, {ref, :codelist_read})
      end,
      nil
    )

    try do
      Validation.check_findings(content, "T", c.schema)
    after
      :telemetry.detach(inspect(ref))
    end

    assert reads(ref, 0) == 1
  end

  test "a document with no codelist value reads no codelist", c do
    ref = make_ref()
    me = self()

    :telemetry.attach(
      inspect(ref),
      [:barkpark, :repo, :query],
      fn _, _, meta, _ ->
        if meta.query =~ "codelist", do: send(me, {ref, :codelist_read})
      end,
      nil
    )

    try do
      Validation.check_findings(%{"stage" => "NOPE"}, "T", c.schema)
    after
      :telemetry.detach(inspect(ref))
    end

    assert reads(ref, 0) == 0
  end

  defp reads(ref, n) do
    receive do
      {^ref, :codelist_read} -> reads(ref, n + 1)
    after
      0 -> n
    end
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
