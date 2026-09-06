defmodule BarkparkWeb.Studio.PaperEditor.FormBlockPatchTest do
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.StudioLive.Blocks

  test "fresh form and questionnaire defaults preserve their type aliases" do
    assert Blocks.default_block("form", "survey") == %{
             "id" => "survey",
             "type" => "form",
             "kind" => "grill",
             "questions" => [
               %{
                 "id" => "survey-question-0",
                 "prompt" => "Question 1",
                 "type" => "text"
               }
             ]
           }

    questionnaire = Blocks.default_block("questionnaire", "survey")
    assert questionnaire["type"] == "questionnaire"
    assert questionnaire["kind"] == "questionnaire"
  end

  test "edits authored fields while preserving question, block, and inactive metadata" do
    first =
      question("answer:name", "Old", "single")
      |> Map.merge(%{
        "rationale" => "Why",
        "recommendation" => nil,
        "options" => ["A", "B"],
        "scale" => %{"min" => 2, "max" => 8, "inactive" => true},
        "unknown" => %{"keep" => true}
      })

    second = question("other", "Other", "text")
    block = form([first, second]) |> Map.put("unknown", [1, 2])

    params =
      wire(block)
      |> Map.put("kind", "questionnaire")
      |> Map.put("question-0-id", "answer:renamed")
      |> Map.put("question-0-prompt", "New")
      |> Map.put("question-0-rationale", "Because")
      |> Map.put("question-0-recommendation", "Choose A")
      |> Map.put("question-0-option-1", "Bee")

    assert {:ok, patch} = Blocks.validate_block_patch(block, params)
    assert patch["kind"] == "questionnaire"
    [updated, ^second] = patch["questions"]
    assert updated["id"] == "answer:renamed"
    assert updated["prompt"] == "New"
    assert updated["rationale"] == "Because"
    assert updated["recommendation"] == "Choose A"
    assert updated["options"] == ["A", "Bee"]
    assert updated["scale"] == first["scale"]
    assert updated["unknown"] == %{"keep" => true}
  end

  test "unchanged effective defaults and unknown kinds/types preserve absent and nil shapes" do
    for block <- [
          %{
            "id" => "survey",
            "type" => "form",
            "questions" => [%{"id" => "q", "prompt" => nil, "type" => nil}]
          },
          %{
            "id" => "survey",
            "type" => "questionnaire",
            "kind" => "legacy-kind",
            "questions" => [
              %{
                "id" => "q",
                "prompt" => "Prompt",
                "type" => "legacy-type",
                "options" => %{"inactive" => true},
                "scale" => "inactive"
              }
            ]
          }
        ] do
      assert {:ok, %{}} = Blocks.validate_block_patch(block, wire(block))
    end

    questionnaire = %{
      "id" => "survey",
      "type" => "questionnaire",
      "questions" => [%{"id" => "q", "prompt" => "Prompt", "type" => "text"}]
    }

    assert {:ok, %{}} = Blocks.validate_block_patch(questionnaire, wire(questionnaire))

    nil_kind = Map.put(questionnaire, "kind", nil)
    assert wire(nil_kind)["kind"] == "grill"
    assert {:ok, %{}} = Blocks.validate_block_patch(nil_kind, wire(nil_kind))
  end

  test "rejects stale vectors, missing fields, blank or duplicate ids, and malformed stored identity" do
    block = form([question("q:a"), question("q:b")])
    base = wire(block)

    invalid = [
      Map.put(base, "question-0-original-id", "q:b"),
      Map.delete(base, "question-1-prompt"),
      Map.put(base, "question-0-prompt", %{"bad" => true}),
      Map.put(base, "question-0-id", "   "),
      base |> Map.put("question-0-id", "same") |> Map.put("question-1-id", "same"),
      Map.put(base, "question-count", "1"),
      Map.put(base, "question-2-id", "extra"),
      Map.put(base, "question-action", "sideways:q:a")
    ]

    for params <- invalid do
      assert {:error, {:malformed_collection, "questions"}} =
               Blocks.validate_block_patch(block, params)
    end

    for rows <- [
          [%{"prompt" => "Missing id", "type" => "text"}],
          [question("   ")],
          [question("same"), question("same")],
          ["legacy"]
        ] do
      assert {:error, {:malformed_collection, "questions"}} =
               Blocks.validate_block_patch(form(rows), wire_for_rows(rows))
    end
  end

  test "adds, removes, and reorders questions by original ids containing colons" do
    first = Map.put(question("group:a"), "unknown", "keep-a")
    second = Map.put(question("group:a:b"), "unknown", "keep-b")
    block = form([first, second])
    base = wire(block)

    assert {:ok, %{"questions" => [^second, ^first]}} =
             Blocks.validate_block_patch(block, Map.put(base, "question-action", "up:group:a:b"))

    assert {:ok, %{"questions" => [^second, ^first]}} =
             Blocks.validate_block_patch(block, Map.put(base, "question-action", "down:group:a"))

    assert {:ok, %{}} =
             Blocks.validate_block_patch(block, Map.put(base, "question-action", "up:group:a"))

    assert {:ok, %{"questions" => [^second]}} =
             Blocks.validate_block_patch(
               block,
               Map.put(base, "question-action", "remove:group:a")
             )

    assert {:ok, %{"questions" => [^first, ^second, added]}} =
             Blocks.validate_block_patch(
               block,
               base
               |> Map.put("question-action", "add")
               |> Map.put("question-new-id", "new:answer")
             )

    assert added == %{"id" => "new:answer", "prompt" => "", "type" => "text"}
  end

  test "missing and nil question collections are editable empty while scalar collections fail closed" do
    add = %{
      "kind" => "grill",
      "question-count" => "0",
      "question-action" => "add",
      "question-new-id" => "answer"
    }

    for block <- [Map.delete(form([]), "questions"), Map.put(form([]), "questions", nil)] do
      assert {:ok, %{"questions" => [%{"id" => "answer", "prompt" => "", "type" => "text"}]}} =
               Blocks.validate_block_patch(block, add)
    end

    for malformed <- [%{}, "legacy", true] do
      assert {:error, {:malformed_collection, "questions"}} =
               Blocks.validate_block_patch(Map.put(form([]), "questions", malformed), add)
    end
  end

  test "edits and mutates ordered choice options with exact counts and colon ids" do
    row = question("choice:primary", "Pick", "single") |> Map.put("options", ["A", "B"])
    block = form([row])
    base = wire(block)

    assert {:ok, %{"questions" => [%{"options" => ["A", "Bee"]}]}} =
             Blocks.validate_block_patch(block, Map.put(base, "question-0-option-1", "Bee"))

    for {action, expected} <- [
          {"add:choice:primary", ["A", "B", ""]},
          {"remove:choice:primary:0", ["B"]},
          {"up:choice:primary:1", ["B", "A"]},
          {"down:choice:primary:0", ["B", "A"]}
        ] do
      assert {:ok, %{"questions" => [%{"options" => ^expected}]}} =
               Blocks.validate_block_patch(block, Map.put(base, "option-action", action))
    end

    for params <- [
          Map.put(base, "question-0-option-count", "1"),
          Map.put(base, "question-0-option-2", "extra"),
          Map.put(base, "question-0-option-0", %{"bad" => true}),
          Map.put(base, "option-action", "remove:choice:primary:9")
        ] do
      assert {:error, {:malformed_collection, "questions"}} =
               Blocks.validate_block_patch(block, params)
    end

    prefix = question("group:a", "First", "single") |> Map.put("options", ["A", "B"])
    longer = question("group:a:b", "Second", "single") |> Map.put("options", ["X", "Y"])
    prefixed_block = form([prefix, longer])
    prefixed_wire = wire(prefixed_block)

    assert {:ok, %{"questions" => [^prefix, %{"options" => ["Y"]}]}} =
             Blocks.validate_block_patch(
               prefixed_block,
               Map.put(prefixed_wire, "option-action", "remove:group:a:b:0")
             )

    assert {:ok, %{"questions" => [%{"options" => ["B"]}, ^longer]}} =
             Blocks.validate_block_patch(
               prefixed_block,
               Map.put(prefixed_wire, "option-action", "remove:group:a:0")
             )
  end

  test "edits scale bounds as integers and rejects malformed active scale fields" do
    row = question("score", "Score", "scale") |> Map.put("scale", %{"min" => "1", "max" => 5})
    block = form([row])
    base = wire(block)

    assert {:ok, %{"questions" => [updated]}} =
             Blocks.validate_block_patch(
               block,
               base
               |> Map.put("question-0-scale-min", "2")
               |> Map.put("question-0-scale-max", "8")
             )

    assert updated["scale"] == %{"min" => 2, "max" => 8}

    for params <- [
          Map.put(base, "question-0-scale-min", "2.5"),
          Map.put(base, "question-0-scale-max", %{"bad" => true}),
          Map.delete(base, "question-0-scale-min")
        ] do
      assert {:error, {:malformed_collection, "questions"}} =
               Blocks.validate_block_patch(block, params)
    end
  end

  test "active structured fields fail closed while inactive malformed metadata survives a type change" do
    malformed_choice = question("choice", "Pick", "single") |> Map.put("options", %{})
    malformed_scale = question("scale", "Score", "scale") |> Map.put("scale", [])

    for block <- [form([malformed_choice]), form([malformed_scale])] do
      assert {:error, {:malformed_collection, "questions"}} =
               Blocks.validate_block_patch(block, wire_for_rows(block["questions"]))
    end

    unknown =
      question("legacy", "Legacy", "legacy-type")
      |> Map.put("options", %{"opaque" => true})
      |> Map.put("scale", ["opaque"])

    block = form([unknown])
    params = wire(block) |> Map.put("question-0-type", "text")

    assert {:ok, %{"questions" => [updated]}} = Blocks.validate_block_patch(block, params)
    assert updated["type"] == "text"
    assert updated["options"] == unknown["options"]
    assert updated["scale"] == unknown["scale"]
  end

  test "strict validation rejects absent form wire while the permissive builder remains a no-op" do
    block = form([question("answer")])

    for params <- [%{}, %{"unrelated" => "value"}] do
      assert {:error, {:malformed_collection, "questions"}} =
               Blocks.validate_block_patch(block, params)

      assert Blocks.build_block_patch(block, params) == %{}
    end
  end

  test "type changes reject malformed data that would become the active branch" do
    for options <- [%{"legacy" => true}, "legacy", 7] do
      block = form([question("answer") |> Map.put("options", options)])
      params = wire(block) |> Map.put("question-0-type", "single")

      assert {:error, {:malformed_collection, "questions"}} =
               Blocks.validate_block_patch(block, params)
    end

    for scale <- [nil, "legacy", [], 7] do
      block = form([question("answer") |> Map.put("scale", scale)])
      params = wire(block) |> Map.put("question-0-type", "scale")

      assert {:error, {:malformed_collection, "questions"}} =
               Blocks.validate_block_patch(block, params)
    end

    missing_scale = form([question("answer")])

    assert {:ok, %{"questions" => [%{"type" => "scale"} = updated]}} =
             Blocks.validate_block_patch(
               missing_scale,
               wire(missing_scale) |> Map.put("question-0-type", "scale")
             )

    refute Map.has_key?(updated, "scale")
  end

  test "active scale rejects explicit nil and scalar shapes without normalizing raw numeric wires" do
    for scale <- [nil, "legacy", [], 7] do
      block = form([question("score", "Score", "scale") |> Map.put("scale", scale)])

      assert {:error, {:malformed_collection, "questions"}} =
               Blocks.validate_block_patch(block, wire(block))
    end

    row =
      question("score", "Score", "scale")
      |> Map.put("scale", %{"min" => "01", "max" => "+5"})

    block = form([row])
    assert {:ok, %{}} = Blocks.validate_block_patch(block, wire(block))
  end

  test "changed and newly activated scale bounds must be ordered while legacy reversed no-ops survive" do
    ordered =
      form([
        question("score", "Score", "scale")
        |> Map.put("scale", %{"min" => 1, "max" => 5})
      ])

    assert {:error, {:malformed_collection, "questions"}} =
             Blocks.validate_block_patch(
               ordered,
               wire(ordered) |> Map.put("question-0-scale-min", "9")
             )

    legacy_row =
      question("legacy", "Legacy", "scale")
      |> Map.put("scale", %{"min" => "09", "max" => "+5", "keep" => true})

    legacy = form([legacy_row])
    assert {:ok, %{}} = Blocks.validate_block_patch(legacy, wire(legacy))

    assert {:ok, %{"questions" => [prompt_only]}} =
             Blocks.validate_block_patch(
               legacy,
               wire(legacy) |> Map.put("question-0-prompt", "Updated")
             )

    assert prompt_only["scale"] == legacy_row["scale"]

    assert {:ok, %{"questions" => [%{"scale" => %{"max" => 10}}]}} =
             Blocks.validate_block_patch(
               legacy,
               wire(legacy) |> Map.put("question-0-scale-max", "10")
             )

    inactive_reversed =
      form([
        question("future")
        |> Map.put("scale", %{"min" => 9, "max" => 5, "keep" => true})
      ])

    assert {:error, {:malformed_collection, "questions"}} =
             Blocks.validate_block_patch(
               inactive_reversed,
               wire(inactive_reversed) |> Map.put("question-0-type", "scale")
             )
  end

  defp form(rows),
    do: %{"id" => "survey", "type" => "form", "kind" => "grill", "questions" => rows}

  defp question(id, prompt \\ "Prompt", type \\ "text"),
    do: %{"id" => id, "prompt" => prompt, "type" => type}

  defp wire(block) do
    kind = kind_wire(block)

    block
    |> Map.get("questions", [])
    |> then(&wire_for_rows(&1, kind))
  end

  defp wire_for_rows(rows, kind \\ "grill")

  defp wire_for_rows(rows, kind) when is_list(rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce(%{"kind" => kind, "question-count" => Integer.to_string(length(rows))}, fn
      {row, index}, acc when is_map(row) ->
        type = effective(row["type"], "text")

        acc
        |> Map.put("question-#{index}-original-id", row["id"])
        |> Map.put("question-#{index}-id", row["id"])
        |> Map.put("question-#{index}-prompt", text_wire(row["prompt"]))
        |> Map.put("question-#{index}-type", type)
        |> Map.put("question-#{index}-rationale", text_wire(row["rationale"]))
        |> Map.put("question-#{index}-recommendation", text_wire(row["recommendation"]))
        |> put_branch(row, index, type)

      {_row, _index}, acc ->
        acc
    end)
  end

  defp wire_for_rows(_rows, kind), do: %{"kind" => kind, "question-count" => "0"}

  defp put_branch(params, row, index, type) when type in ["single", "multi"] do
    options = if is_list(row["options"]), do: row["options"], else: []

    options
    |> Enum.with_index()
    |> Enum.reduce(
      Map.put(params, "question-#{index}-option-count", Integer.to_string(length(options))),
      fn {option, option_index}, acc ->
        Map.put(acc, "question-#{index}-option-#{option_index}", option)
      end
    )
  end

  defp put_branch(params, row, index, "scale") do
    scale = if is_map(row["scale"]), do: row["scale"], else: %{}

    params
    |> Map.put("question-#{index}-scale-min", number_wire(Map.get(scale, "min", 1)))
    |> Map.put("question-#{index}-scale-max", number_wire(Map.get(scale, "max", 5)))
  end

  defp put_branch(params, _row, _index, _type), do: params

  defp effective(value, _default) when is_binary(value), do: value
  defp effective(_value, default), do: default

  defp kind_wire(block) do
    case Map.fetch(block, "kind") do
      :error -> if(block["type"] == "questionnaire", do: "questionnaire", else: "grill")
      {:ok, kind} when is_binary(kind) -> kind
      {:ok, nil} -> "grill"
    end
  end

  defp text_wire(value) when is_binary(value), do: value
  defp text_wire(_value), do: ""
  defp number_wire(value) when is_integer(value), do: Integer.to_string(value)
  defp number_wire(value) when is_binary(value), do: value
  defp number_wire(_value), do: ""
end
