defmodule BarkparkWeb.Studio.PaneBuilderPluginItemsTest do
  @moduledoc """
  Covers PaneBuilder's handling of plugin-contributed desk items — the
  `:plugin_link` and labelled `:divider` shapes that Structure
  translates from `Barkpark.Plugin.desk_item()` maps. Verified via
  `BarkparkWeb.Studio.PaneBuilder.list_items/1`, which is the seam
  between Structure nodes and pane render maps.
  """

  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.PaneBuilder
  alias Barkpark.Structure.Node

  describe "list_items/1 — :divider with optional label" do
    test "unlabelled divider renders with label nil" do
      node = %Node{
        type: :list,
        items: [
          %Node{type: :divider, id: "div-1"}
        ]
      }

      assert [item] = PaneBuilder.list_items(node)
      assert item.type == :divider
      assert item.id == "div-1"
      assert item.label == nil
    end

    test "labelled divider carries the label through" do
      node = %Node{
        type: :list,
        items: [
          %Node{type: :divider, id: "div-2", title: "Bokbasen"}
        ]
      }

      assert [item] = PaneBuilder.list_items(node)
      assert item.type == :divider
      assert item.label == "Bokbasen"
    end
  end

  describe "list_items/1 — :plugin_link" do
    test "translates a Structure :plugin_link node into a render map" do
      node = %Node{
        type: :list,
        items: [
          %Node{
            id: "plugin-link-abc",
            title: "Pending submissions",
            icon: "clock",
            type: :plugin_link,
            filter: "/admin/onixedit/staleness"
          }
        ]
      }

      assert [item] = PaneBuilder.list_items(node)
      assert item.type == :plugin_link
      assert item.id == "plugin-link-abc"
      assert item.title == "Pending submissions"
      assert item.icon == "clock"
      # The destination path is carried under :href (PaneBuilder renames
      # Structure's `filter` field to the more descriptive key for the
      # render layer).
      assert item.href == "/admin/onixedit/staleness"
    end
  end

  describe "list_items/1 — :plugin_document_list drillability" do
    test "renders as a drillable item (same as :document_type_list)" do
      node = %Node{
        type: :list,
        items: [
          %Node{
            id: "plugin-doclist-xyz",
            title: "Synced books",
            type: :plugin_document_list,
            type_name: "book",
            filter: %{"content.state" => %{"in" => ["staged"]}}
          }
        ]
      }

      assert [item] = PaneBuilder.list_items(node)
      assert item.type == :item
      assert item.drillable == true
      assert item.title == "Synced books"
    end
  end
end
