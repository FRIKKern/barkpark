defmodule BarkparkWeb.Studio.PaperEditor.StageAuthoringTest do
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.StudioLive.Blocks

  test "scalar no-ops preserve every accepted carrier without backfilling" do
    for carrier <- [%{}, %{"title" => nil}, %{"title" => ""}, %{"title" => 7}],
        source <- [nil, false, true, "", "true", "queue.ex:42"] do
      block = Map.merge(%{"id" => "s", "type" => "stage", "source" => source}, carrier)
      assert {:ok, state} = Blocks.stage_form_state(block)

      assert {:ok, %{}} =
               Blocks.validate_block_patch(block, %{
                 "stage-title" => state.title,
                 "stage-source-mode" => state.source_mode,
                 "stage-source-text" => state.source_text
               })
    end
  end

  test "slot edit preserves wrappers, unknown slots and divergent scalar shadows" do
    block = slotted()
    assert {:ok, state} = Blocks.stage_form_state(block)
    assert state.title == "Original"
    assert {:ok, patch} = Blocks.validate_block_patch(block, %{"stage-title" => "Changed"})

    expected =
      put_in(
        block,
        [
          "slots",
          "title",
          Access.at(0),
          "content",
          Access.at(0),
          "children",
          Access.at(0),
          "value"
        ],
        "Changed"
      )

    assert Map.merge(block, patch) == expected
    assert {:ok, %{}} = Blocks.validate_block_patch(block, %{"stage-title" => "Original"})
  end

  test "synchronized scalar twins follow edits but absent twins stay absent" do
    for scalar <- [:absent, "Original", "divergent", 7, nil] do
      block =
        if scalar == :absent,
          do: Map.delete(slotted(), "title"),
          else: Map.put(slotted(), "title", scalar)

      assert {:ok, patch} = Blocks.validate_block_patch(block, %{"stage-title" => ""})
      updated = Map.merge(block, patch)

      assert get_in(updated, [
               "slots",
               "title",
               Access.at(0),
               "content",
               Access.at(0),
               "children",
               Access.at(0),
               "value"
             ]) == ""

      assert Map.fetch(updated, "title") ==
               if(scalar == "Original", do: {:ok, ""}, else: Map.fetch(block, "title"))
    end
  end

  test "source origin and provenance are distinct and unrelated edits retain raw values" do
    block = %{"id" => "s", "type" => "stage", "source" => "queue.ex:42", "title" => "Old"}

    assert {:ok, %{"title" => "New"}} =
             Blocks.validate_block_patch(block, %{"stage-title" => "New"})

    assert {:ok, %{"source" => true}} =
             Blocks.validate_block_patch(block, %{
               "stage-source-mode" => "origin",
               "stage-source-text" => "queue.ex:42"
             })

    assert {:ok, %{"source" => nil}} =
             Blocks.validate_block_patch(block, %{
               "stage-source-mode" => "none",
               "stage-source-text" => ""
             })

    assert {:error, _} =
             Blocks.validate_block_patch(block, %{
               "stage-source-mode" => "provenance",
               "stage-source-text" => ""
             })
  end

  test "empty optional slots and nil slot maps preserve their representation on no-op" do
    for slots <- [nil, %{}, %{"kind" => [], "detail" => []}] do
      block = %{"id" => "s", "type" => "stage", "slots" => slots}

      assert {:ok, %{}} =
               Blocks.validate_block_patch(block, %{"stage-kind" => "", "stage-detail" => ""})

      assert {:ok, patch} =
               Blocks.validate_block_patch(block, %{
                 "stage-kind" => "Check",
                 "stage-detail" => "Run tests"
               })

      updated = Map.merge(block, patch)
      assert Barkpark.PortableDoc.Slots.stage_field_text(updated, "kind") == "Check"
      assert Barkpark.PortableDoc.Slots.stage_field_text(updated, "detail") == "Run tests"
      assert Map.get(updated, "slots") == slots or slots == %{"kind" => [], "detail" => []}
      refute Map.has_key?(updated, "title")
    end
  end

  test "an empty singleton title retains paragraph metadata when first authored" do
    for content <- [nil, []] do
      title = %{"type" => "paragraph", "id" => "title", "qa" => [1, 2], "content" => content}
      block = %{"id" => "s", "type" => "stage", "slots" => %{"title" => [title]}}
      assert {:ok, %{}} = Blocks.validate_block_patch(block, %{"stage-title" => ""})
      assert {:ok, patch} = Blocks.validate_block_patch(block, %{"stage-title" => "First title"})

      assert patch == %{
               "slots" => %{
                 "title" => [
                   Map.put(title, "content", [%{"type" => "text", "value" => "First title"}])
                 ]
               }
             }
    end
  end

  test "ambiguous slots and invalid forms fail closed" do
    for extra <- [
          %{"slots" => []},
          %{"slots" => %{"title" => []}},
          %{"source" => 1},
          %{"title" => %{}},
          %{
            "slots" => %{
              "title" => [
                %{
                  "type" => "paragraph",
                  "content" => [
                    %{"type" => "text", "value" => "a"},
                    %{"type" => "text", "value" => "b"}
                  ]
                }
              ]
            }
          }
        ] do
      block = Map.merge(%{"id" => "s", "type" => "stage"}, extra)
      assert {:error, _} = Blocks.stage_form_state(block)
      assert {:error, _} = Blocks.validate_block_patch(block, %{"stage-title" => "Forged"})
    end

    assert {:error, _} = Blocks.validate_block_patch(slotted(), %{"stage-title" => 1})
    assert {:error, _} = Blocks.validate_block_patch(slotted(), %{"stage-unknown" => "x"})
  end

  defp slotted do
    %{
      "id" => "s",
      "type" => "stage",
      "title" => "divergent",
      "source" => "queue.ex:42",
      "qa" => [1, 2],
      "slots" => %{
        "unknown" => %{"opaque" => true},
        "title" => [
          %{
            "id" => "title",
            "type" => "paragraph",
            "qa" => "paragraph",
            "content" => [
              %{
                "id" => "mark",
                "type" => "strong",
                "qa" => "wrapper",
                "children" => [
                  %{"id" => "leaf", "type" => "text", "value" => "Original", "qa" => "leaf"}
                ]
              }
            ]
          }
        ]
      }
    }
  end
end
