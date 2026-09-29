defmodule BarkparkWeb.Studio.PaperEditor.NoteAuthoringTest do
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Slots
  alias BarkparkWeb.Studio.StudioLive.Blocks

  test "default is a typed flat note" do
    assert Blocks.default_block("note", "n") ==
             %{"id" => "n", "type" => "note", "label" => "note", "text" => ""}
  end

  test "no-op matrix retains missing nil empty integer and empty optional slots exactly" do
    for value <- [:absent, nil, "", 7], slots <- [:absent, nil, %{}, %{"lead" => []}] do
      block = %{"id" => "n", "type" => "note"}
      block = Enum.reduce(~w(label lead text), block, &put_optional(&2, &1, value))
      block = put_optional(block, "slots", slots)
      assert {:ok, state} = Blocks.note_form_state(block)
      assert {:ok, %{}} = Blocks.validate_block_patch(block, params(state))
    end
  end

  test "each slot takes precedence and edits retain every key and divergent shadow" do
    for {field, flat} <- [{"label", "label"}, {"lead", "lead"}, {"body", "text"}] do
      block = slotted(field) |> Map.put(flat, "shadow")
      assert {:ok, state} = Blocks.note_form_state(block)
      assert Map.fetch!(state, String.to_existing_atom(field)) == "Original"
      assert {:ok, %{}} = Blocks.validate_block_patch(block, %{("note-" <> field) => "Original"})
      assert {:ok, patch} = Blocks.validate_block_patch(block, %{("note-" <> field) => "Edited"})
      assert Map.merge(block, patch) == put_in(block, path(field), "Edited")
    end
  end

  test "slot clear syncs only a matching binary twin" do
    for {field, flat} <- [{"label", "label"}, {"lead", "lead"}, {"body", "text"}],
        value <- [:absent, nil, 7, "", "shadow", "Original"] do
      block = put_optional(slotted(field), flat, value)
      assert {:ok, patch} = Blocks.validate_block_patch(block, %{("note-" <> field) => ""})
      expected = put_in(block, path(field), "")
      expected = if value == "Original", do: Map.put(expected, flat, ""), else: expected
      assert Map.merge(block, patch) == expected
    end
  end

  test "flat clear uses nil for label and lead, empty string for body" do
    block = %{"id" => "n", "type" => "note", "label" => "L", "lead" => "D", "text" => "B"}

    assert {:ok, %{"label" => nil, "lead" => nil, "text" => ""}} =
             Blocks.validate_block_patch(block, %{
               "note-label" => "",
               "note-lead" => "",
               "note-body" => ""
             })
  end

  test "empty paragraph content gets a leaf without losing metadata; no-op never adds it" do
    for field <- ~w(label lead body), content <- [:absent, nil, []] do
      paragraph =
        put_optional(%{"id" => "p", "type" => "paragraph", "vendor" => [1]}, "content", content)

      block = %{
        "id" => "n",
        "type" => "note",
        "slots" => %{field => [paragraph], "unknown" => [2]}
      }

      assert {:ok, %{}} = Blocks.validate_block_patch(block, %{("note-" <> field) => ""})
      assert {:ok, patch} = Blocks.validate_block_patch(block, %{("note-" <> field) => "First"})

      assert patch == %{
               "slots" => %{
                 field => [
                   Map.put(paragraph, "content", [%{"type" => "text", "value" => "First"}])
                 ],
                 "unknown" => [2]
               }
             }
    end
  end

  test "optional empty lead falls back to flat while required empty slots fail closed" do
    block = %{"id" => "n", "type" => "note", "lead" => "Lead", "slots" => %{"lead" => []}}

    assert {:ok, %{"lead" => "Edited"}} =
             Blocks.validate_block_patch(block, %{"note-lead" => "Edited"})

    for field <- ~w(label body) do
      assert {:error, _} = Blocks.note_form_state(put_in(block, ["slots", field], []))
    end
  end

  test "effective content fallback edits and clears its terminal without backfilling text" do
    for text <- [:absent, nil, ""] do
      block = %{"id" => "n", "type" => "note", "content" => inline("Body"), "vendor" => [1]}
      block = put_optional(block, "text", text)
      assert {:ok, state} = Blocks.note_form_state(block)
      assert state.body == Slots.note_body_text(block)
      assert {:ok, %{}} = Blocks.validate_block_patch(block, %{"note-body" => "Body"})

      for changed <- ["Changed", ""] do
        assert {:ok, patch} = Blocks.validate_block_patch(block, %{"note-body" => changed})
        assert patch == %{"content" => inline(changed)}
        assert Map.fetch(Map.merge(block, patch), "text") == Map.fetch(block, "text")
        assert Slots.note_body_text(Map.merge(block, patch)) == changed
      end
    end
  end

  test "unread scalar content is not coerced and dormant nonempty arrays are guarded" do
    block = %{"id" => "n", "type" => "note", "content" => "unread"}
    assert {:ok, %{body: ""}} = Blocks.note_form_state(block)

    assert {:ok, %{"text" => "Body"}} =
             Blocks.validate_block_patch(block, %{"note-body" => "Body"})

    for content <- [
          inline("Hidden"),
          inline("Primary"),
          [%{"type" => "text", "value" => "a"}, %{"type" => "text", "value" => "b"}]
        ] do
      guarded = Map.merge(block, %{"text" => "Primary", "content" => content})
      assert {:error, _} = Blocks.note_form_state(guarded)
      assert {:error, _} = Blocks.validate_block_patch(guarded, %{"note-body" => ""})
    end
  end

  test "malformed source and forged fields fail closed" do
    for extra <- [
          %{"slots" => []},
          %{"label" => %{}},
          %{"lead" => false},
          %{"text" => 1.5},
          %{"slots" => %{"body" => [%{"type" => "heading"}]}},
          %{"slots" => %{"label" => [%{"type" => "paragraph", "content" => "opaque"}]}},
          %{
            "content" => [
              %{"type" => "text", "value" => "a"},
              %{"type" => "text", "value" => "b"}
            ]
          },
          %{
            "content" => [
              %{
                "type" => "text",
                "value" => "a",
                "children" => [%{"type" => "text", "value" => "hidden"}]
              }
            ]
          }
        ] do
      block = Map.merge(%{"id" => "n", "type" => "note"}, extra)
      assert {:error, _} = Blocks.note_form_state(block)
      assert {:error, _} = Blocks.validate_block_patch(block, %{"note-label" => "Forged"})
    end

    for params <- [%{"note-unknown" => "x"}, %{"note-label" => 1}, %{"note-body" => nil}, %{}] do
      assert {:error, _} = Blocks.validate_block_patch(Blocks.default_block("note", "n"), params)
    end
  end

  defp params(state),
    do: %{"note-label" => state.label, "note-lead" => state.lead, "note-body" => state.body}

  defp put_optional(map, key, :absent), do: Map.delete(map, key)
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp inline(value),
    do: [
      %{
        "type" => "strong",
        "vendor" => [1],
        "children" => [%{"type" => "code", "value" => value, "vendor" => %{"keep" => true}}]
      }
    ]

  defp slotted(field),
    do: %{
      "id" => "n",
      "type" => "note",
      "vendor" => [1],
      "slots" => %{
        field => [
          %{"id" => "p", "type" => "paragraph", "vendor" => [2], "content" => inline("Original")}
        ],
        "unknown" => %{"opaque" => true}
      }
    }

  defp path(field),
    do: ["slots", field, Access.at(0), "content", Access.at(0), "children", Access.at(0), "value"]
end
