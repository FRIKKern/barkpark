defmodule BarkparkWeb.Studio.PaneBuilderTest do
  @moduledoc """
  Unit tests for `BarkparkWeb.Studio.PaneBuilder` — the pure pane-tree
  builder extracted from `StudioLive` in Task #11 WI3.
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Content
  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Tenancy
  alias BarkparkWeb.Studio.PaneBuilder

  defp insert_schema!(attrs) do
    %SchemaDefinition{}
    |> SchemaDefinition.changeset(attrs)
    |> Repo.insert!()
  end

  defp seed_basic(dataset) do
    insert_schema!(%{
      name: "post",
      title: "Posts",
      icon: "file-text",
      visibility: "public",
      dataset: dataset,
      fields: [
        %{"name" => "title", "type" => "string"},
        %{"name" => "body", "type" => "text"}
      ]
    })

    {:ok, _} = Content.create_document("post", %{"_id" => "p1", "title" => "Post 1"}, dataset)

    {:ok, _} = Content.create_document("post", %{"_id" => "p2", "title" => "Post 2"}, dataset)
  end

  describe "build/2" do
    test "empty path → root pane only" do
      seed_basic("pb_empty")
      {panes, editor} = PaneBuilder.build("pb_empty", [])

      assert is_list(panes)
      assert length(panes) == 1
      # has a title
      assert hd(panes).title
      assert editor == nil
    end

    test "nav into a doc list adds a pane" do
      seed_basic("pb_list")
      {panes, editor} = PaneBuilder.build("pb_list", ["post"])

      assert length(panes) == 2
      assert editor == nil
      [_, post_pane] = panes
      assert post_pane.type_name == "post"
    end

    test "nav into a specific doc resolves an editor" do
      seed_basic("pb_doc")
      {panes, editor} = PaneBuilder.build("pb_doc", ["post", "p1"])

      assert length(panes) == 2
      assert is_map(editor)
      assert editor.type == "post"
      assert editor.doc.title == "Post 1"
      assert editor.is_draft == true
      assert is_map(editor.form)
    end

    test "missing doc returns no editor" do
      seed_basic("pb_missing")
      {panes, editor} = PaneBuilder.build("pb_missing", ["post", "missing-doc"])

      assert length(panes) == 2
      assert editor == nil
    end
  end

  # Goal ges/graph-edge-seam, FIX 2 — the `graph/<doc_id>` nav segment must
  # resolve into a `view: :graph` editor for ANY content doc. Before the fix
  # walk_path/7 only descended a node whose id/type_name matched the segment,
  # and NO structure node has type_name "graph", so this returned nil — the
  # entire Studio GraphView pane was unreachable.
  describe "graph blast-radius pane (FIX 2)" do
    test "build(dataset, [\"graph\", doc_id]) returns an editor with view: :graph" do
      seed_basic("pb_graph")
      {_panes, editor} = PaneBuilder.build("pb_graph", ["graph", "p1"])

      assert is_map(editor), "expected a graph editor, got nil (the dead-seam regression)"
      assert editor.view == :graph
      assert editor.doc.doc_id =~ "p1"
      # The payload slice GraphView renders — present even when empty.
      assert is_map(editor.graph)
      assert Map.has_key?(editor.graph, :nodes)
      assert Map.has_key?(editor.graph, :edges)
    end

    test "graph pane roots on a doc REGARDLESS of its schema type (gap #4)" do
      seed_basic("pb_graph_any")
      # `post` is an ordinary content type — proving the pane is NOT gated on a
      # non-existent "graph" schema/type.
      {_panes, editor} = PaneBuilder.build("pb_graph_any", ["graph", "p2"])

      assert editor.view == :graph
      assert editor.type == "post"
    end

    test "graph pane with an unknown doc_id returns no editor" do
      seed_basic("pb_graph_missing")
      {_panes, editor} = PaneBuilder.build("pb_graph_missing", ["graph", "nope"])

      assert editor == nil
    end
  end

  describe "collapse?/3" do
    test "no collapse with 1 or 2 panes (no editor)" do
      refute PaneBuilder.collapse?(0, 1, false)
      refute PaneBuilder.collapse?(0, 2, false)
      refute PaneBuilder.collapse?(1, 2, false)
    end

    test "no editor, 3+ panes — collapse all except last 2" do
      assert PaneBuilder.collapse?(0, 4, false)
      assert PaneBuilder.collapse?(1, 4, false)
      refute PaneBuilder.collapse?(2, 4, false)
      refute PaneBuilder.collapse?(3, 4, false)
    end

    test "editor open, 3+ panes — collapse all except last 1" do
      assert PaneBuilder.collapse?(0, 3, true)
      assert PaneBuilder.collapse?(1, 3, true)
      refute PaneBuilder.collapse?(2, 3, true)
    end
  end

  describe "update_title/3" do
    test "updates only matching doc id" do
      panes = [
        %{
          title: "Posts",
          items: [
            %{type: :doc, id: "p1", title: "Old"},
            %{type: :doc, id: "p2", title: "Other"}
          ]
        }
      ]

      result = PaneBuilder.update_title(panes, "p1", "New")
      assert hd(hd(result).items).title == "New"
      assert Enum.at(hd(result).items, 1).title == "Other"
    end

    test "preserves non-doc items unchanged" do
      panes = [
        %{
          title: "Mix",
          items: [
            %{type: :divider, id: "d"},
            %{type: :doc, id: "p1", title: "Old"}
          ]
        }
      ]

      result = PaneBuilder.update_title(panes, "p1", "New")
      assert Enum.at(hd(result).items, 0) == %{type: :divider, id: "d"}
    end
  end

  describe "list_preview row badge + meta" do
    # Insert the REAL plugin-declared task schema (incl. its
    # `list_preview` declaration) so this pins the shipped shape, the
    # same way structure_tasks_desk_test derives from task_schema/1.
    defp insert_task_schema!(dataset) do
      schema = Barkpark.Tasks.task_schema(dataset)

      insert_schema!(%{
        name: schema.name,
        title: schema.title,
        icon: schema.icon,
        visibility: schema.visibility,
        dataset: schema.dataset,
        fields: schema.fields,
        list_preview: schema.list_preview
      })
    end

    defp create_task!(dataset, doc_id, content) do
      {:ok, doc} =
        Content.create_document(
          "task",
          %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
          dataset
        )

      doc
    end

    test "task rows carry the lifecycle badge and P-prefixed priority meta" do
      dataset = "pb_preview_task"
      insert_task_schema!(dataset)

      create_task!(dataset, "t1", %{
        "kind" => "task",
        "lifecycle_status" => "in_progress",
        "priority" => 1
      })

      create_task!(dataset, "t2", %{"kind" => "task", "lifecycle_status" => "open"})

      # The Tasks plugin contributes the list via the desk-item highway —
      # nav by type_name resolves the :plugin_document_list node.
      {panes, _editor} = PaneBuilder.build(dataset, ["task"])

      task_pane = List.last(panes)
      assert task_pane.type_name == "task"

      t1 = Enum.find(task_pane.items, &(&1.id == "t1"))
      assert t1.badge == "in_progress"
      assert t1.meta == "P1"

      # Declared meta field absent on the doc → nil, never a crash.
      t2 = Enum.find(task_pane.items, &(&1.id == "t2"))
      assert t2.badge == "open"
      assert t2.meta == nil
    end

    test "a schema without list_preview renders rows unchanged (regression pin)" do
      seed_basic("pb_preview_none")
      {panes, _editor} = PaneBuilder.build("pb_preview_none", ["post"])

      [_, post_pane] = panes
      assert post_pane.items != []

      for item <- post_pane.items do
        assert item.badge == nil
        assert item.meta == nil
        # Pre-existing row keys are intact.
        assert Map.has_key?(item, :title)
        assert Map.has_key?(item, :status)
        assert Map.has_key?(item, :is_draft)
      end
    end
  end

  describe "preview manifest row meta (Preview Contract D17)" do
    # A block doc (paper/sheet/form) carries a write-time OG manifest at
    # content["preview"]; its description becomes the row meta a doc-list row
    # never had. The manifest's PRESENCE is the switch — PaneBuilder never
    # branches on the document type — so a `post` here stands in for any
    # block doc whose write stamped a manifest.
    test "a doc with a stamped manifest surfaces the description as row meta" do
      dataset = "pb_preview_manifest"
      seed_basic(dataset)

      {:ok, _} =
        Content.create_document(
          "post",
          %{
            "_id" => "pm1",
            "title" => "Stamped",
            "content" => %{
              "preview" => %{
                "title" => "Stamped",
                "type" => "post",
                "description" => "A calm intro to the theme system.",
                "url" => "/papers/stamped",
                "image" => nil,
                "extensions" => %{}
              }
            }
          },
          dataset
        )

      {panes, _editor} = PaneBuilder.build(dataset, ["post"])
      [_, post_pane] = panes

      pm1 = Enum.find(post_pane.items, &(&1.id == "pm1"))
      assert pm1.meta == "A calm intro to the theme system."
      # The sparse share manifest carries no badge vocabulary.
      assert pm1.badge == nil

      # A sibling post with NO manifest and no list_preview stays blank — the
      # manifest is per-doc, not per-schema.
      p1 = Enum.find(post_pane.items, &(&1.id == "p1"))
      assert p1.meta == nil
      assert p1.badge == nil
    end

    test "a manifest with a blank description falls through to a blank row" do
      dataset = "pb_preview_blank_desc"
      seed_basic(dataset)

      {:ok, _} =
        Content.create_document(
          "post",
          %{
            "_id" => "pb1",
            "title" => "No prose",
            "content" => %{"preview" => %{"description" => nil}}
          },
          dataset
        )

      {panes, _editor} = PaneBuilder.build(dataset, ["post"])
      [_, post_pane] = panes

      pb1 = Enum.find(post_pane.items, &(&1.id == "pb1"))
      assert pb1.meta == nil
      assert pb1.badge == nil
    end
  end

  describe "mediaAsset explorer view" do
    test "browsing mediaAsset list without a doc opens the media explorer editor" do
      dataset = "pb_media_explorer"

      insert_schema!(%{
        name: "mediaAsset",
        title: "Media Asset",
        icon: "image",
        visibility: "private",
        dataset: dataset,
        fields: [%{"name" => "title", "type" => "string"}],
        desk_groups: [
          %{
            "name" => "images",
            "title" => "Images",
            "filter" => %{"content.bp_asset_kind" => %{"eq" => "image"}}
          },
          %{"name" => "all", "title" => "All", "filter" => %{}}
        ]
      })

      {panes, editor} = PaneBuilder.build(dataset, ["mediaAsset"], desk: "images")

      assert length(panes) == 2
      assert editor[:view] == :media_explorer
      assert editor[:kind_filter] == "image"
    end
  end

  # ssp-w2-studio-honest-desk — the displayed desk (panes[0]) now reflects
  # enablement: the gated tree renders, so disabled plugins / top-menu Media are
  # NOT root items. Resolution stays honest: a stale deep link to a DEMOTED type
  # (now nested under Plugins / …Rest) is normalized and drilled; a type ABSENT
  # from the gated display (top-menu Media, a disabled plugin's bookmark) falls
  # back to the ungated tree so its panes/editor still open (#1851 guarantee).
  describe "honest gated desk + demoted-type resolution (ssp-w2)" do
    test "the root pane is the gated desk — a top-menu type is not a root item" do
      dataset = "pb_gated_root"

      insert_schema!(%{
        name: "mediaAsset",
        title: "Media Asset",
        icon: "image",
        visibility: "private",
        dataset: dataset,
        fields: [%{"name" => "title", "type" => "string"}]
      })

      {panes, _editor} = PaneBuilder.build(dataset, [])
      root = hd(panes)

      # Media is :top_menu by default → hidden from the tree. The desk tells the
      # truth: no mediaAsset / media-library rows at the root.
      refute Enum.any?(root.items, &(Map.get(&1, :id) in ["mediaAsset", "media-library"])),
             "top-menu Media must not appear in the gated root desk"
    end

    test "a top-menu type absent from the gated desk still opens via the ungated fallback" do
      dataset = "pb_media_fallback"

      insert_schema!(%{
        name: "mediaAsset",
        title: "Media Asset",
        icon: "image",
        visibility: "private",
        dataset: dataset,
        fields: [%{"name" => "title", "type" => "string"}]
      })

      # mediaAsset is absent from the gated desk (top-menu placement), yet the
      # pane + media-explorer editor still resolve — the never-unreachable rule.
      {panes, editor} = PaneBuilder.build(dataset, ["mediaAsset"])

      assert length(panes) == 2
      assert editor[:view] == :media_explorer

      refute Enum.any?(hd(panes).items, &(Map.get(&1, :id) == "mediaAsset")),
             "the root pane stays gated even though resolution used the ungated tree"
    end

    test "a stale deep link to a demoted type drills the Plugins column and reveals it" do
      ws = create_workspace!()
      proj = create_project!(ws)
      dataset = "pb_demoted_book"
      scope = [workspace_id: ws.id, project_id: proj.id]

      # Global book schema (visible under scope via include_global) so both the
      # tree and the editor's get_schema/2 resolve it.
      insert_schema!(%{
        name: "book",
        title: "Books",
        icon: "book",
        visibility: "private",
        dataset: dataset,
        fields: [%{"name" => "title", "type" => "string"}]
      })

      {:ok, _} =
        Content.create_document(
          "book",
          %{"_id" => "b1", "title" => "Book 1"},
          dataset,
          source: :studio,
          workspace_id: ws.id,
          project_id: proj.id
        )

      # Enable OnixEdit but keep its default :plugins placement → book nests
      # under the Plugins node, so the legacy ["book", id] path misses the root.
      {:ok, _} =
        Tenancy.set_workspace_plugin_settings(ws.id, %{"onixedit" => %{"enabled" => true}})

      {panes, editor} = PaneBuilder.build(dataset, ["book", "b1"], scope: scope)

      root = hd(panes)

      # The gated root shows a Plugins column, never a top-level book.
      assert Enum.any?(root.items, &(Map.get(&1, :id) == "plugins")),
             "an enabled :plugins plugin surfaces a Plugins column at the root"

      refute Enum.any?(root.items, &(Map.get(&1, :id) == "book")),
             "book is demoted under Plugins — never a top-level root item"

      # The reveal: the root highlights the Plugins column and the walk drilled
      # into it down to the book doc.
      assert root.selected == "plugins",
             "the stale path is normalized so the Plugins column is the selected reveal"

      assert length(panes) == 3, "root → Plugins → book: the demoted column is drilled open"
      assert List.last(panes).type_name == "book"

      assert is_map(editor), "the demoted book doc still opens its editor"
      assert editor.type == "book"
      assert editor.doc.doc_id =~ "b1"
    end
  end
end
