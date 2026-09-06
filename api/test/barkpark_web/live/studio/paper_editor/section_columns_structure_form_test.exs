defmodule BarkparkWeb.Studio.PaperEditor.SectionColumnsStructureFormTest do
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Patch
  alias BarkparkWeb.Studio.StudioLive.Blocks

  test "Section adds its first identified paragraph from a fully fenced empty form" do
    block = %{"id" => "section", "type" => "section", "blocks" => [], "unknown" => "keep"}

    assert Blocks.validate_block_patch(block, section_params(block, "new-child", "add")) ==
             {:ok,
              %{
                "blocks" => [
                  %{
                    "id" => "new-child",
                    "type" => "paragraph",
                    "content" => [%{"type" => "text", "value" => ""}]
                  }
                ]
              }}
  end

  test "Section repeatedly appends identified paragraphs without rewriting existing children" do
    existing = paragraph("existing", "Keep", %{"span" => 2, "order" => -1, "unknown" => true})
    block = %{"id" => "section", "type" => "section", "blocks" => [existing]}

    assert {:ok, %{"blocks" => [^existing, first_new]}} =
             Blocks.validate_block_patch(block, section_params(block, "new-one", "add"))

    assert first_new["id"] == "new-one"
    after_first = Map.put(block, "blocks", [existing, first_new])

    assert {:ok, %{"blocks" => [^existing, ^first_new, second_new]}} =
             Blocks.validate_block_patch(
               after_first,
               section_params(after_first, "new-two", "add")
             )

    assert second_new["id"] == "new-two"
  end

  test "Section reorders and removes exact children without rewriting their metadata" do
    first = paragraph("first", "First", %{"span" => 2, "order" => 7, "unknown" => [1]})
    second = paragraph("second:part", "Second", %{"unknown" => %{"keep" => true}})
    block = %{"id" => "section", "type" => "section", "blocks" => [first, second]}

    assert {:ok, %{"blocks" => [^second, ^first]}} =
             Blocks.validate_block_patch(
               block,
               section_params(block, "unused", "up:second:part")
             )

    assert {:ok, %{"blocks" => [^first]}} =
             Blocks.validate_block_patch(
               block,
               section_params(block, "unused", "remove:second:part")
             )

    assert Blocks.validate_block_patch(
             block,
             section_params(block, "unused", "up:first")
           ) == {:ok, %{}}
  end

  test "Section rejects stale vectors, incomplete wire, malformed bodies, and locked removal" do
    locked =
      %{
        "id" => "locked-parent",
        "type" => "section",
        "blocks" => [paragraph("locked-child", "Locked", %{"locked" => true})]
      }

    block = %{
      "id" => "section",
      "type" => "section",
      "blocks" => [paragraph("first", "First"), locked]
    }

    malformed = {:error, {:malformed_collection, "section"}}

    assert Blocks.validate_block_patch(
             block,
             section_params(block, "new") |> Map.put("section-child-0-id", "stale")
           ) == malformed

    assert Blocks.validate_block_patch(
             block,
             section_params(block, "new") |> Map.delete("section-new-child-id")
           ) == malformed

    assert Blocks.validate_block_patch(
             block,
             section_params(block, "new") |> Map.put("section-extra", "forged")
           ) == malformed

    assert Blocks.validate_block_patch(
             block,
             section_params(block, "new", "remove:locked-parent")
           ) == {:error, {:locked_block, "locked-child", "remove-block"}}

    assert Blocks.validate_block_patch(block, section_params(block, "   ", "add")) == malformed

    assert Blocks.structure_child_locked?(locked)
    refute Blocks.structure_child_locked?(paragraph("unlocked", "Unlocked"))

    for malformed_block <- [
          %{"id" => "section", "type" => "section"},
          %{"id" => "section", "type" => "section", "blocks" => nil},
          %{"id" => "section", "type" => "section", "blocks" => ["opaque"]}
        ] do
      assert Blocks.validate_block_patch(
               malformed_block,
               %{
                 "section-child-count" => "0",
                 "section-new-child-id" => "new",
                 "section-action" => "add"
               }
             ) == malformed
    end
  end

  test "Columns adds a first paragraph only to the exact empty canonical column" do
    right = paragraph("right", "Right", %{"span" => 3, "order" => -1})

    block = %{
      "id" => "columns",
      "type" => "columns",
      "columns" => [[], [right]],
      "gap" => "wide"
    }

    params = columns_params(block, "new:left", "add:0")

    assert {:ok,
            %{
              "columns" => [
                [
                  %{
                    "id" => "new:left",
                    "type" => "paragraph",
                    "content" => [%{"type" => "text", "value" => ""}]
                  }
                ],
                [^right]
              ]
            }} = Blocks.validate_block_patch(block, params)

    assert {:ok, %{"columns" => [[], [^right, appended]]}} =
             Blocks.validate_block_patch(
               block,
               columns_params(block, "new:right", "add:1")
             )

    assert appended["id"] == "new:right"
  end

  test "Columns reorders and removes exact children while preserving every other column" do
    first = paragraph("first", "First", %{"span" => 2, "order" => 4})
    second = paragraph("child:with:colons", "Second", %{"unknown" => true})
    other = paragraph("other", "Other", %{"unknown" => [1, 2]})

    block = %{
      "id" => "columns",
      "type" => "columns",
      "columns" => [[first, second], [other]]
    }

    assert {:ok, %{"columns" => [[^second, ^first], [^other]]}} =
             Blocks.validate_block_patch(
               block,
               columns_params(block, "unused", "up:0:child:with:colons")
             )

    assert {:ok, %{"columns" => [[^first], [^other]]}} =
             Blocks.validate_block_patch(
               block,
               columns_params(block, "unused", "remove:0:child:with:colons")
             )

    assert Blocks.validate_block_patch(
             block,
             columns_params(block, "unused", "down:1:other")
           ) == {:ok, %{}}
  end

  test "Columns rejects stale indexes and vectors, malformed shapes, and locked removal" do
    locked = paragraph("locked", "Locked", %{"locked" => true})

    block = %{
      "id" => "columns",
      "type" => "columns",
      "columns" => [[paragraph("left", "Left")], [locked], []]
    }

    malformed = {:error, {:malformed_collection, "columns"}}

    assert Blocks.validate_block_patch(block, columns_params(block, "new", "add:3")) == malformed

    assert Blocks.validate_block_patch(
             block,
             columns_params(block, "new") |> Map.put("column-1-child-0-id", "left")
           ) == malformed

    assert Blocks.validate_block_patch(
             block,
             columns_params(block, "new") |> Map.delete("column-0-child-count")
           ) == malformed

    assert Blocks.validate_block_patch(
             block,
             columns_params(block, "new") |> Map.put("column-3-child-count", "0")
           ) == malformed

    assert Blocks.validate_block_patch(
             block,
             columns_params(block, "new", "remove:1:locked")
           ) == {:error, {:locked_block, "locked", "remove-block"}}

    assert Blocks.validate_block_patch(block, columns_params(block, "\t", "add:2")) == malformed

    for malformed_block <- [
          %{"id" => "columns", "type" => "columns"},
          %{"id" => "columns", "type" => "columns", "columns" => nil},
          %{"id" => "columns", "type" => "columns", "columns" => [[], "opaque"]},
          %{"id" => "columns", "type" => "columns", "columns" => [["opaque"]]}
        ] do
      assert Blocks.validate_block_patch(
               malformed_block,
               %{
                 "column-count" => "1",
                 "column-0-child-count" => "0",
                 "column-new-child-id" => "new",
                 "column-action" => "add:0"
               }
             ) == malformed
    end
  end

  test "the document Patch ratchet rejects new structural IDs colliding inside, outside, and in hidden aliases" do
    existing = paragraph("taken", "Existing")
    section = %{"id" => "section", "type" => "section", "blocks" => [existing]}

    assert_duplicate_after_form(
      [section],
      section_params(section, "taken", "add"),
      "taken"
    )

    empty_section = %{"id" => "empty-section", "type" => "section", "blocks" => []}

    assert_duplicate_after_form(
      [empty_section, paragraph("outside", "Outside")],
      section_params(empty_section, "outside", "add"),
      "outside"
    )

    columns = %{"id" => "columns", "type" => "columns", "columns" => [[]]}

    hidden_alias = %{
      "id" => "steps",
      "type" => "steps",
      "steps" => [
        %{
          "id" => "step-row",
          "children" => [],
          "blocks" => [paragraph("hidden-shadow", "Hidden")]
        }
      ]
    }

    assert_duplicate_after_form(
      [columns, hidden_alias],
      columns_params(columns, "hidden-shadow", "add:0"),
      "hidden-shadow"
    )
  end

  defp section_params(block, new_id, action \\ nil) do
    children = block["blocks"]

    %{
      "block_id" => block["id"],
      "section-child-count" => Integer.to_string(length(children)),
      "section-new-child-id" => new_id
    }
    |> put_indexed_ids("section-child", children)
    |> put_action("section-action", action)
  end

  defp columns_params(block, new_id, action \\ nil) do
    columns = block["columns"]

    Enum.with_index(columns)
    |> Enum.reduce(
      %{
        "block_id" => block["id"],
        "column-count" => Integer.to_string(length(columns)),
        "column-new-child-id" => new_id
      },
      fn {children, column_index}, params ->
        params
        |> Map.put("column-#{column_index}-child-count", Integer.to_string(length(children)))
        |> put_indexed_ids("column-#{column_index}-child", children)
      end
    )
    |> put_action("column-action", action)
  end

  defp put_indexed_ids(params, prefix, children) do
    children
    |> Enum.with_index()
    |> Enum.reduce(params, fn {child, index}, acc ->
      Map.put(acc, "#{prefix}-#{index}-id", child["id"])
    end)
  end

  defp put_action(params, _key, nil), do: params
  defp put_action(params, key, action), do: Map.put(params, key, action)

  defp assert_duplicate_after_form(blocks, source, duplicate_id) do
    assert {:ok, op} = Blocks.resolve_block_form(blocks, source)
    assert Patch.apply_patch(blocks, op) == {:error, {:duplicate_id, duplicate_id, "patch-block"}}
  end

  defp paragraph(id, text, extra \\ %{}) do
    Map.merge(%{"id" => id, "type" => "paragraph", "content" => inline(text)}, extra)
  end

  defp inline(text), do: [%{"type" => "text", "value" => text}]
end
