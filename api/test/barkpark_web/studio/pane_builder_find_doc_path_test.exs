defmodule BarkparkWeb.Studio.PaneBuilderFindDocPathTest do
  @moduledoc """
  Covers `PaneBuilder.find_doc_path/3` — the (type, doc_id) → nav-path
  resolver behind the `jump-to-user` presence handler.

  Regression guard for the jump-to-user dead-end: the pre-fix resolver only
  matched `:document_type_list` children, so settings singletons
  (`:document` children) and plugin-contributed lists
  (`:plugin_document_list`, possibly nested) fell through to a
  `[type, doc_id]` fallback that `walk_path/7` cannot resolve — the jump
  silently landed on the root pane with no editor.

  Pure struct trees (mirroring `Structure.build/2` output shapes) — no DB.
  """

  use ExUnit.Case, async: true

  alias Barkpark.Structure.Node
  alias BarkparkWeb.Studio.PaneBuilder

  # A tree with every desk shape find_doc_path must resolve: a simple doc
  # list, a filtered group (All + status sub-views), settings singletons, a
  # nested plugin group, and a root-level plugin list.
  defp tree do
    %Node{
      id: "root",
      title: "Structure",
      type: :list,
      items: [
        %Node{id: "page", title: "Pages", type: :document_type_list, type_name: "page"},
        %Node{
          id: "post",
          title: "Posts",
          type: :list,
          type_name: "post",
          items: [
            %Node{
              id: "post-all",
              title: "All Posts",
              type: :document_type_list,
              type_name: "post"
            },
            %Node{type: :divider, id: "post-div"},
            %Node{
              id: "post-draft",
              title: "Draft",
              type: :document_type_list,
              type_name: "post",
              filter: "status=draft"
            }
          ]
        },
        %Node{
          id: "settings",
          title: "Settings",
          type: :list,
          items: [
            %Node{
              id: "siteSettings",
              title: "Site Settings",
              type: :document,
              type_name: "siteSettings"
            }
          ]
        },
        %Node{
          id: "plugin-nest-1",
          title: "Games",
          type: :list,
          items: [
            %Node{
              id: "plugin-doclist-77",
              title: "Rounds",
              type: :plugin_document_list,
              type_name: "round",
              filter: %{}
            }
          ]
        },
        %Node{
          id: "plugin-doclist-42",
          title: "Tasks",
          type: :plugin_document_list,
          type_name: "task",
          filter: %{}
        }
      ]
    }
  end

  test "direct root doc list → [type, doc_id]" do
    assert PaneBuilder.find_doc_path(tree(), "page", "d1") == ["page", "d1"]
  end

  test "filtered group resolves through the unfiltered All view" do
    assert PaneBuilder.find_doc_path(tree(), "post", "p9") == ["post", "post-all", "p9"]
  end

  test "settings singleton → [parent, type] with NO doc id (singletons resolve by type)" do
    assert PaneBuilder.find_doc_path(tree(), "siteSettings", "siteSettings") ==
             ["settings", "siteSettings"]
  end

  test "plugin doc list nested in a plugin group resolves through the group" do
    assert PaneBuilder.find_doc_path(tree(), "round", "r1") ==
             ["plugin-nest-1", "plugin-doclist-77", "r1"]
  end

  test "root-level plugin doc list resolves by type_name to the node's real id" do
    assert PaneBuilder.find_doc_path(tree(), "task", "t1") == ["plugin-doclist-42", "t1"]
  end

  test "unknown type falls back to [type, doc_id]" do
    assert PaneBuilder.find_doc_path(tree(), "ghost", "g1") == ["ghost", "g1"]
  end
end
