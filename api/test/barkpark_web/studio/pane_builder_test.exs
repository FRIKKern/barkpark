defmodule BarkparkWeb.Studio.PaneBuilderTest do
  @moduledoc """
  Unit tests for `BarkparkWeb.Studio.PaneBuilder` — the pure pane-tree
  builder extracted from `StudioLive` in Task #11 WI3.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.SchemaDefinition
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
end
