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

  # session-handoff Task 3 review fix: both blocks-type-whitelist gate sites
  # (`walk_path(["open", type, id | _], ...)` and `build_editor/6`'s dispatch
  # cond) were changed from a hardcoded `type == "paper"` equality to
  # `Content.blocks_type?/1`, but only PAPER coverage existed anywhere in this
  # suite (none, in fact — `walk_path` for "paper"/"open" had zero prior
  # tests either). These pin that a "session" — the second, non-paper member
  # of the whitelist — resolves through BOTH gate sites into the same
  # `view: :paper` pane shape a paper gets.
  describe "session blocks-doc pane dispatch (blocks-type whitelist, session-handoff Task 3)" do
    defp register_session_schema!(dataset) do
      for schema_def <- Barkpark.Plugins.Bulldocs.register_schemas([]),
          schema_def.name == "session" do
        attrs =
          schema_def
          |> Map.from_struct()
          |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
          |> Map.new(fn {k, v} -> {to_string(k), v} end)

        {:ok, _} = Content.upsert_schema(attrs, dataset, [])
      end

      :ok
    end

    defp seed_session!(dataset, slug) do
      register_session_schema!(dataset)

      {:ok, doc} =
        Content.upsert_blocks_doc("session", %{
          "slug" => slug,
          "title" => "Pane session",
          "status" => "open",
          "blocks" => [%{"id" => "s1", "type" => "paragraph", "content" => ["hi"]}],
          "dataset" => dataset
        })

      doc
    end

    test "walk_path/build via the [\"open\", \"session\", id] literal segment resolves a paper-view editor" do
      dataset = "pb_session_open"
      seed_session!(dataset, "sess-open-1")

      {_panes, editor} = PaneBuilder.build(dataset, ["open", "session", "sess-open-1"])

      assert is_map(editor), "expected a session editor via the open-segment gate, got nil"
      assert editor.view == :paper
      assert editor.type == "session"
      assert editor.doc.doc_id == "sess-open-1"
    end

    test "walk_path/build via the [\"open\", \"session\", id] literal segment is nil for an unknown slug" do
      dataset = "pb_session_open_missing"
      register_session_schema!(dataset)

      {_panes, editor} = PaneBuilder.build(dataset, ["open", "session", "nope"])

      assert editor == nil
    end

    test "ordinary structure nav [\"session\", id] resolves a paper-view editor via build_editor/6's dispatch cond" do
      dataset = "pb_session_nav"
      seed_session!(dataset, "sess-nav-1")

      {_panes, editor} = PaneBuilder.build(dataset, ["session", "sess-nav-1"])

      assert is_map(editor),
             "expected a session editor via the build_editor dispatch cond, got nil"

      assert editor.view == :paper
      assert editor.type == "session"
      assert editor.doc.doc_id == "sess-nav-1"
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

    test "a declared list_preview meta spec WINS over a stamped manifest" do
      # Defensive cross-surface pin, mirror of the Go TUI's
      # TestRowMetaListPreviewWinsWhenBothPresent: a doc carrying BOTH a
      # schema list_preview meta spec and a manifest keeps the declared
      # spec — fieldful task/ticket rows never regress to the sparse OG
      # description. No such doc exists today (fieldful docs never enter
      # Projection.project); this pins the priority so the two surfaces
      # can never silently diverge.
      dataset = "pb_preview_lp_wins"
      insert_task_schema!(dataset)

      create_task!(dataset, "t9", %{
        "kind" => "task",
        "lifecycle_status" => "open",
        "priority" => 1,
        "preview" => %{"description" => "should not win"}
      })

      {panes, _editor} = PaneBuilder.build(dataset, ["task"])
      task_pane = List.last(panes)

      t9 = Enum.find(task_pane.items, &(&1.id == "t9"))
      assert t9.meta == "P1"
      assert t9.badge == "open"
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

    # Charter Decision 20 residual — the DISABLED-plugin deep-link case. OnixEdit
    # is off by declaration default, so its owned `book` type is dropped from the
    # placed nodes (structure.ex place_host_group → {[], []}) and instead surfaces
    # in the …Rest census (id `rest-book`, a `:document_type_list` because the
    # schema still resolves in scope). A stale top-level `["book", id]` deep link
    # therefore misses the gated root; `find_type_node` recurses the `…Rest`
    # `:list` and normalizes the path to `["rest", "rest-book", id]`, drilling and
    # revealing the doc. Sibling cases (enabled-demoted via Plugins, top-menu
    # ungated fallback) are pinned above; this pins the third, previously verified
    # only by code-trace.
    test "a disabled plugin's owned type reveals via …Rest when documents exist" do
      ws = create_workspace!()
      proj = create_project!(ws)
      dataset = "pb_disabled_rest_book"
      scope = [workspace_id: ws.id, project_id: proj.id]

      # Global book schema (visible under scope via include_global) so the …Rest
      # node is a drillable :document_type_list and the editor's get_schema/2
      # resolves it.
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

      # NO set_workspace_plugin_settings call: OnixEdit stays disabled by its
      # declaration default (default_enabled?/0 → false), so `book` is a homeless
      # type that falls to the honest census, not a Plugins-column member.

      {panes, editor} = PaneBuilder.build(dataset, ["book", "b1"], scope: scope)

      root = hd(panes)

      # Anti-vacuous guard: `book` is genuinely ABSENT from the gated root — never
      # a top-level item and (OnixEdit disabled) no Plugins column claims it. If a
      # future change re-homed it at the root, `find_type_node` would resolve it
      # without touching …Rest and this pin would be meaningless.
      refute Enum.any?(root.items, &(Map.get(&1, :id) == "book")),
             "book must not be a top-level root item — it has no enabled owner"

      refute Enum.any?(root.items, &(Map.get(&1, :id) == "plugins")),
             "OnixEdit is disabled — no Plugins column may claim book"

      # (1) The path is normalized under …Rest: the census folder surfaces at the
      # root and the stale path is drilled into it.
      assert Enum.any?(root.items, &(Map.get(&1, :id) == "rest")),
             "the …Rest folder must surface book's homeless type"

      assert root.selected == "rest",
             "the stale ['book', id] path is normalized so …Rest is the selected reveal"

      # (3) The reveal drilled root → …Rest → rest-book: the walk opened the
      # demoted-to-census column down to the book doc.
      assert length(panes) == 3, "root → …Rest → book: the census column is drilled open"
      assert List.last(panes).type_name == "book"

      # (2) The editor pane opens the document itself.
      assert is_map(editor), "the homeless book doc still opens its editor"
      assert editor.type == "book"
      assert editor.doc.doc_id =~ "b1"
    end
  end

  # spd-s3 — pane anatomy model. Every pane map returned by build/3 carries
  # DERIVED display metadata: `role:` (:nav for the root desk pane, :list for
  # every drilled pane) and `priority:` (0 on the root, the pane index on
  # intermediates, :active on the pane the nav path terminates in). Derived
  # only — never stored on Structure.Node, never serialized on the
  # /v1/structure wire (structure_controller_test pins the node allowlist).
  describe "pane anatomy — role + priority (spd-s3)" do
    test "root-only desk: the nav pane is role :nav, priority 0" do
      seed_basic("pb_anatomy_root")
      {panes, editor} = PaneBuilder.build("pb_anatomy_root", [])

      assert [%{role: :nav, priority: 0}] = panes
      assert editor == nil
    end

    test "drilled doc list: :nav root + :active :list pane" do
      seed_basic("pb_anatomy_list")
      {panes, _editor} = PaneBuilder.build("pb_anatomy_list", ["post"])

      assert [%{role: :nav, priority: 0}, %{role: :list, priority: :active}] = panes
    end

    test "an open document keeps the terminal list pane :active — the editor is NOT a pane" do
      seed_basic("pb_anatomy_doc")
      {panes, editor} = PaneBuilder.build("pb_anatomy_doc", ["post", "p1"])

      assert [%{role: :nav, priority: 0}, %{role: :list, priority: :active}] = panes

      # Content/inspector render from the editor map, outside the pane
      # anatomy — it must never grow pane keys.
      assert is_map(editor)
      refute Map.has_key?(editor, :role)
      refute Map.has_key?(editor, :priority)
    end

    test "a plugin-contributed doc list pane carries the same anatomy" do
      dataset = "pb_anatomy_task"
      insert_task_schema!(dataset)
      create_task!(dataset, "t1", %{"kind" => "task", "lifecycle_status" => "open"})

      # The Tasks plugin contributes a :plugin_document_list node — same
      # anatomy as a host :document_type_list pane.
      {panes, _editor} = PaneBuilder.build(dataset, ["task"])

      assert %{role: :list, priority: :active} = List.last(panes)
      assert %{role: :nav, priority: 0} = hd(panes)
    end

    test "intermediate :list panes take their pane index; only the leaf is :active" do
      ws = create_workspace!()
      proj = create_project!(ws)
      dataset = "pb_anatomy_depth"
      scope = [workspace_id: ws.id, project_id: proj.id]

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

      # Enabled-but-:plugins placement → book nests under the Plugins node,
      # so the walk drills root → Plugins → book (3 panes).
      {:ok, _} =
        Tenancy.set_workspace_plugin_settings(ws.id, %{"onixedit" => %{"enabled" => true}})

      {panes, _editor} = PaneBuilder.build(dataset, ["book", "b1"], scope: scope)

      assert [
               %{role: :nav, priority: 0},
               %{role: :list, priority: 1},
               %{role: :list, priority: :active}
             ] = panes

      # INVARIANT (spd-s1..s3 review pin): a non-:active pane's priority IS its
      # index in the pane list. The :list site computes `depth + 1`, which only
      # coincides with the index because the walk appends one pane per level —
      # insert a pane anywhere and the two silently desync, which would
      # mis-order any consumer that squeezes by priority (spd-s4). Assert the
      # relationship, not the literal numbers.
      panes
      |> Enum.with_index()
      |> Enum.each(fn {pane, idx} ->
        assert pane.priority == :active or pane.priority == idx,
               "pane #{idx} (#{pane.title}) carries priority #{inspect(pane.priority)} — " <>
                 "expected :active or #{idx}"
      end)

      # The same :list group opened AS the leaf segment is itself :active.
      {panes2, _editor2} = PaneBuilder.build(dataset, ["plugins"], scope: scope)
      assert [%{role: :nav, priority: 0}, %{role: :list, priority: :active}] = panes2
    end

    test "anatomy is deterministic for the same nav_path" do
      seed_basic("pb_anatomy_det")
      project = fn {panes, _editor} -> Enum.map(panes, &{&1.role, &1.priority}) end

      a = project.(PaneBuilder.build("pb_anatomy_det", ["post", "p1"]))
      b = project.(PaneBuilder.build("pb_anatomy_det", ["post", "p1"]))

      assert a == b
      assert a == [{:nav, 0}, {:list, :active}]
    end
  end

  # spd-s3 — the ONE display-state table the responsive desk reads.
  # wide/standard must be collapse?/3 verbatim (the pins above stay the
  # wide-bucket regression lock); narrow protects the last pane; phone is
  # editor-owned (all hidden) or single-column drill (last pane only).
  describe "display_state/4" do
    test "exhaustive table: 4 buckets x num_panes 1..5 x has_editor" do
      table = %{
        # wide, no editor — last 2 panes full (collapse?/3 verbatim)
        {"wide", 1, false} => [:full],
        {"wide", 2, false} => [:full, :full],
        {"wide", 3, false} => [:strip, :full, :full],
        {"wide", 4, false} => [:strip, :strip, :full, :full],
        {"wide", 5, false} => [:strip, :strip, :strip, :full, :full],
        # wide, editor open — last 1 pane full (collapse?/3 verbatim)
        {"wide", 1, true} => [:full],
        {"wide", 2, true} => [:strip, :full],
        {"wide", 3, true} => [:strip, :strip, :full],
        {"wide", 4, true} => [:strip, :strip, :strip, :full],
        {"wide", 5, true} => [:strip, :strip, :strip, :strip, :full],
        # standard — identical to wide by design
        {"standard", 1, false} => [:full],
        {"standard", 2, false} => [:full, :full],
        {"standard", 3, false} => [:strip, :full, :full],
        {"standard", 4, false} => [:strip, :strip, :full, :full],
        {"standard", 5, false} => [:strip, :strip, :strip, :full, :full],
        {"standard", 1, true} => [:full],
        {"standard", 2, true} => [:strip, :full],
        {"standard", 3, true} => [:strip, :strip, :full],
        {"standard", 4, true} => [:strip, :strip, :strip, :full],
        {"standard", 5, true} => [:strip, :strip, :strip, :strip, :full],
        # narrow, no editor — drill navigation, only the last pane full
        {"narrow", 1, false} => [:full],
        {"narrow", 2, false} => [:strip, :full],
        {"narrow", 3, false} => [:strip, :strip, :full],
        {"narrow", 4, false} => [:strip, :strip, :strip, :full],
        {"narrow", 5, false} => [:strip, :strip, :strip, :strip, :full],
        # narrow, editor open (spd-s4 / charter D35) — the nav row yields
        # entirely to the protected content pane; ONE 44px back strip
        # survives. The old rule here (last pane :full) was bit-identical
        # to collapse?/3 and closed zero pixels of the 640–1023 overflow.
        {"narrow", 1, true} => [:strip],
        {"narrow", 2, true} => [:hidden, :strip],
        {"narrow", 3, true} => [:hidden, :hidden, :strip],
        {"narrow", 4, true} => [:hidden, :hidden, :hidden, :strip],
        {"narrow", 5, true} => [:hidden, :hidden, :hidden, :hidden, :strip],
        # phone, no editor — single-column drill: last pane only
        {"phone", 1, false} => [:full],
        {"phone", 2, false} => [:hidden, :full],
        {"phone", 3, false} => [:hidden, :hidden, :full],
        {"phone", 4, false} => [:hidden, :hidden, :hidden, :full],
        {"phone", 5, false} => [:hidden, :hidden, :hidden, :hidden, :full],
        # phone, editor open — the document owns the viewport
        {"phone", 1, true} => [:hidden],
        {"phone", 2, true} => [:hidden, :hidden],
        {"phone", 3, true} => [:hidden, :hidden, :hidden],
        {"phone", 4, true} => [:hidden, :hidden, :hidden, :hidden],
        {"phone", 5, true} => [:hidden, :hidden, :hidden, :hidden, :hidden]
      }

      # Exhaustiveness guard — the table really covers 4 x 5 x 2.
      assert map_size(table) == 40

      for {{bucket, num_panes, has_editor?}, expected} <- table do
        actual =
          for idx <- 0..(num_panes - 1),
              do: PaneBuilder.display_state(idx, num_panes, has_editor?, bucket)

        assert actual == expected,
               "display_state mismatch: bucket=#{bucket} num_panes=#{num_panes} " <>
                 "has_editor=#{has_editor?} — got #{inspect(actual)}, want #{inspect(expected)}"
      end
    end

    test "wide/standard hold the deep-stack shape too (6-8 panes), as literals" do
      # CONVERTED, not deleted (spd-w6-wide-geometry-lock, charter D94). What
      # stood here derived its expectation from `collapse?/3` — the very
      # function it claimed to guard — so when `collapse?/3` was regressed by
      # deliberate fault injection (keep_full_nav_count 1 -> 2) both sides of
      # the comparison moved together and this test stayed GREEN while the
      # 40-cell literal table above went red with a readable diff. It could
      # never fail from the only thing it purported to guard.
      #
      # Deleting it outright would have lost real coverage: the table above
      # is exhaustive over num_panes 1..5, and this test reached 8. So the
      # coverage is kept and the idiom is swapped — the deep-stack rows are
      # spelled out as constants, exactly like the table above, and nothing
      # here calls `collapse?/3`.
      #
      # The shape, stated in words so a diff is readable: with a document
      # open the wide desk keeps ONE full nav pane (the last); with no
      # document open it keeps TWO. Everything to their left is a 44px strip.
      table = %{
        {6, true} => [:strip, :strip, :strip, :strip, :strip, :full],
        {7, true} => [:strip, :strip, :strip, :strip, :strip, :strip, :full],
        {8, true} => [:strip, :strip, :strip, :strip, :strip, :strip, :strip, :full],
        {6, false} => [:strip, :strip, :strip, :strip, :full, :full],
        {7, false} => [:strip, :strip, :strip, :strip, :strip, :full, :full],
        {8, false} => [:strip, :strip, :strip, :strip, :strip, :strip, :full, :full]
      }

      # Exhaustiveness guard — 3 depths x 2 editor states, and every row is
      # as long as its own pane count.
      assert map_size(table) == 6

      for {{num_panes, has_editor?}, expected} <- table do
        assert length(expected) == num_panes

        for bucket <- ["wide", "standard"] do
          actual =
            for idx <- 0..(num_panes - 1),
                do: PaneBuilder.display_state(idx, num_panes, has_editor?, bucket)

          assert actual == expected,
                 "display_state mismatch: bucket=#{bucket} num_panes=#{num_panes} " <>
                   "has_editor=#{has_editor?} — got #{inspect(actual)}, want #{inspect(expected)}"
        end
      end
    end

    test "narrow + editor leaves exactly ONE strip and no full pane (D35)" do
      for num_panes <- 1..8 do
        states =
          for idx <- 0..(num_panes - 1),
              do: PaneBuilder.display_state(idx, num_panes, true, "narrow")

        assert Enum.count(states, &(&1 == :strip)) == 1,
               "num_panes=#{num_panes} — want exactly one 44px back strip, got #{inspect(states)}"

        refute Enum.any?(states, &(&1 == :full)),
               "num_panes=#{num_panes} — no nav pane may hold full width beside the " <>
                 "protected content pane, got #{inspect(states)}"

        assert List.last(states) == :strip,
               "num_panes=#{num_panes} — the surviving strip must be the LAST pane " <>
                 "(it is the back affordance), got #{inspect(states)}"
      end
    end

    test "narrow + editor DIVERGES from collapse?/3 — the whole point of D35" do
      # Before spd-s4 the narrow rule was bit-identical to collapse?/3 whenever
      # an editor was open, so it removed zero pixels of overflow. This pins
      # that the divergence is real and cannot silently regress to a no-op.
      divergences =
        for num_panes <- 2..8,
            idx <- 0..(num_panes - 1),
            collapse_state =
              if(PaneBuilder.collapse?(idx, num_panes, true), do: :strip, else: :full),
            PaneBuilder.display_state(idx, num_panes, true, "narrow") != collapse_state,
            do: {num_panes, idx}

      refute divergences == [],
             "narrow-with-editor is a no-op again — D35 regressed"
    end

    test "narrow with NO editor is unchanged from spd-s3" do
      for num_panes <- 1..8, idx <- 0..(num_panes - 1) do
        expected = if idx == num_panes - 1, do: :full, else: :strip

        assert PaneBuilder.display_state(idx, num_panes, false, "narrow") == expected,
               "idx=#{idx} num_panes=#{num_panes} — the editor-closed narrow row has no " <>
                 "560px floor and must keep its full drill column"
      end
    end
  end

  # ── a STORED bad desk filter (gfr-w1-filter-chokepoint-strict) ─────────────
  #
  # `SchemaDefinition.changeset/2` now refuses a desk chip whose filter carries an
  # unsupported op, so no NEW one can be written. Rows written BEFORE that guard
  # existed are still out there, and the query builder no longer swallows them:
  # it raises. Rendered naively that is a Studio LiveView crash — the whole desk
  # goes down for one typo in one chip.
  #
  # PaneBuilder pre-flights instead: no items, and an explicit pane-level
  # `filter_error`. Deliberately NOT a rescue — a rescue would swallow genuine
  # builder bugs too, re-creating the silence one layer up.
  # Write the bad chip the way history did: past the changeset, straight into
  # the column. Going through the changeset would be REFUSED now (that is the
  # write-side half of this fix, pinned in schema_definition_test.exs).
  defp store_bad_desk_group!(dataset, filter) do
    insert_schema!(%{
      name: "post",
      title: "Posts",
      visibility: "public",
      dataset: dataset,
      fields: [%{"name" => "title", "type" => "string"}],
      desk_groups: [%{"name" => "ok", "title" => "OK", "filter" => %{}}]
    })

    {1, _} =
      Repo.update_all(
        from(s in SchemaDefinition, where: s.dataset == ^dataset and s.name == "post"),
        set: [desk_groups: [%{"name" => "bad", "title" => "Bad", "filter" => filter}]]
      )

    :ok
  end

  describe "a stored desk filter the query builder refuses" do
    test "renders an empty list plus a filter error instead of raising" do
      dataset = "pb_bad_desk"
      store_bad_desk_group!(dataset, %{"status" => %{"bogus" => "x"}})
      {:ok, _} = Content.create_document("post", %{"_id" => "bd1", "title" => "One"}, dataset)
      {:ok, _} = Content.create_document("post", %{"_id" => "bd2", "title" => "Two"}, dataset)

      {panes, _editor} = PaneBuilder.build(dataset, ["post"], desk: "bad")

      pane = List.last(panes)
      assert pane.type_name == "post"

      # It does NOT raise (reaching this line is the assertion), it does NOT
      # silently list everything, and it SAYS so.
      assert pane.items == []
      assert is_binary(pane.filter_error)
      assert pane.filter_error =~ "bogus"
      assert pane.filter_error =~ "status"
    end

    test "the SAME pane with no active desk is unaffected — the refusal is scoped" do
      dataset = "pb_bad_desk_inactive"
      store_bad_desk_group!(dataset, %{"status" => %{"bogus" => "x"}})
      {:ok, _} = Content.create_document("post", %{"_id" => "bd3", "title" => "One"}, dataset)

      {panes, _editor} = PaneBuilder.build(dataset, ["post"])

      pane = List.last(panes)
      assert pane.filter_error == nil
      assert length(pane.items) == 1
    end

    test "a healthy desk chip still filters and carries no error" do
      dataset = "pb_good_desk"

      insert_schema!(%{
        name: "post",
        title: "Posts",
        visibility: "public",
        dataset: dataset,
        fields: [%{"name" => "title", "type" => "string"}],
        desk_groups: [
          %{
            "name" => "drafts",
            "title" => "Drafts",
            "filter" => %{"status" => %{"eq" => "draft"}}
          }
        ]
      })

      {:ok, _} = Content.create_document("post", %{"_id" => "gd1", "title" => "One"}, dataset)

      {panes, _editor} = PaneBuilder.build(dataset, ["post"], desk: "drafts")

      pane = List.last(panes)
      assert pane.filter_error == nil
      assert pane.active_desk == "drafts"
    end
  end
end
