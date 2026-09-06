defmodule BarkparkWeb.Studio.PaperEditor.ActionContextualFormTest do
  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.StudioLive.Blocks

  test "action form state preserves authored strings and projects only nil defaults" do
    assert Blocks.action_form_state(action(%{})) ==
             {:ok, %{label: "", href: "", priority: "secondary"}}

    assert Blocks.action_form_state(action(%{"label" => nil, "href" => nil, "priority" => nil})) ==
             {:ok, %{label: "", href: "", priority: "secondary"}}

    assert Blocks.action_form_state(
             action(%{"label" => "Read", "href" => "/read", "priority" => "legacy"})
           ) == {:ok, %{label: "Read", href: "/read", priority: "legacy"}}
  end

  test "action form rejects malformed authored fields and non-actions" do
    for block <-
          [
            action(%{"label" => %{}}),
            action(%{"href" => []}),
            action(%{"priority" => true})
          ] do
      assert Blocks.action_form_state(block) == {:error, :malformed_action}
      assert Blocks.validate_block_patch(block, full_wire()) == {:error, :malformed_action}
      assert Blocks.build_block_patch(block, full_wire()) == %{}
    end

    assert Blocks.action_form_state(%{"id" => "paragraph", "type" => "paragraph"}) ==
             {:error, :malformed_action}
  end

  test "action patch is presence-aware and preserves legacy no-op shapes" do
    for block <- [
          action(%{}),
          action(%{"label" => nil, "href" => nil, "priority" => nil})
        ] do
      assert Blocks.validate_block_patch(block, %{"action-label" => ""}) == {:ok, %{}}
      assert Blocks.validate_block_patch(block, %{"action-href" => ""}) == {:ok, %{}}

      assert Blocks.validate_block_patch(block, %{"action-priority" => "secondary"}) ==
               {:ok, %{}}
    end

    legacy =
      action(%{
        "label" => "Old",
        "href" => "/old",
        "priority" => "legacy",
        "unknown" => %{"keep" => true}
      })

    assert Blocks.validate_block_patch(legacy, %{"action-priority" => "legacy"}) == {:ok, %{}}

    assert Blocks.validate_block_patch(legacy, %{
             "action-label" => "Old",
             "action-href" => "/old"
           }) == {:ok, %{}}

    assert Blocks.validate_block_patch(legacy, %{"action-label" => ""}) ==
             {:ok, %{"label" => ""}}

    assert legacy["unknown"] == %{"keep" => true}
  end

  test "action patch changes only submitted fields and accepts the closed priority vocabulary" do
    block =
      action(%{
        "label" => "Old label",
        "href" => "/old",
        "priority" => "primary",
        "unknown" => %{"keep" => true}
      })

    assert Blocks.validate_block_patch(block, %{
             "action-label" => "New label",
             "action-priority" => "secondary"
           }) == {:ok, %{"label" => "New label", "priority" => "secondary"}}

    assert Blocks.validate_block_patch(block, %{"action-href" => "/new"}) ==
             {:ok, %{"href" => "/new"}}

    assert Blocks.validate_block_patch(action(%{}), %{"action-priority" => "primary"}) ==
             {:ok, %{"priority" => "primary"}}
  end

  test "action form wire fails closed as a whole" do
    block = action(%{"label" => "Old", "href" => "/old", "priority" => "legacy"})

    for params <- [
          %{},
          %{"block_id" => "action"},
          %{"action-label" => "New", "action-extra" => "bad"},
          %{"action-label" => %{}},
          %{"action-href" => []},
          %{"action-priority" => "invented"},
          %{"action-priority" => nil}
        ] do
      assert Blocks.validate_block_patch(block, params) == {:error, :invalid_action_form}
      assert Blocks.build_block_patch(block, params) == %{}
    end
  end

  test "authoritative form resolver targets the current Action and emits a shallow patch" do
    blocks = [
      action(%{"label" => "Old", "href" => "/old", "meta" => %{"keep" => true}}),
      %{"id" => "sibling", "type" => "paragraph", "text" => "Keep"}
    ]

    source = %{
      "block_id" => "action",
      "action-label" => "New",
      "action-href" => "/new",
      "action-priority" => "primary"
    }

    assert Blocks.resolve_block_form(blocks, source) ==
             {:ok,
              %{
                "op" => "patch-block",
                "id" => "action",
                "patch" => %{
                  "label" => "New",
                  "href" => "/new",
                  "priority" => "primary"
                }
              }}

    assert Blocks.resolve_block_form(blocks, Map.put(source, "block_id", "missing")) ==
             {:error, :block_not_found}

    assert hd(blocks)["meta"] == %{"keep" => true}
    assert List.last(blocks)["text"] == "Keep"
  end

  test "Action and Card defaults are canonical editable shapes with the requested identity" do
    action = Blocks.default_block("action", "new-action")
    card = Blocks.default_block("card", "new-card")

    assert action == %{
             "id" => "new-action",
             "type" => "action",
             "href" => "",
             "label" => ""
           }

    assert Blocks.action_form_state(action) ==
             {:ok, %{label: "", href: "", priority: "secondary"}}

    assert card == %{
             "id" => "new-card",
             "type" => "card",
             "slots" => %{
               "title" => [%{"type" => "heading", "text" => "New card"}],
               "body" => [
                 %{
                   "type" => "paragraph",
                   "content" => [%{"type" => "text", "value" => ""}]
                 }
               ]
             }
           }

    assert Blocks.card_form_state(card) ==
             {:ok,
              %{
                tone: "",
                title: "New card",
                media_src: "",
                media_alt: "",
                action_label: "",
                action_href: "",
                action_priority: "secondary"
              }}
  end

  defp action(extra), do: Map.merge(%{"id" => "action", "type" => "action"}, extra)

  defp full_wire do
    %{
      "action-label" => "New",
      "action-href" => "/new",
      "action-priority" => "primary"
    }
  end
end
