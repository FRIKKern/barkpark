defmodule Barkpark.Content.PaperTaskResolverTest do
  @moduledoc """
  task-9c59aa555e1e015e (Barkspark phase 1, slice H): `Barkpark.Content.Papers`
  reads a task chip's criteria and a task query block's rows / aggregates
  through the content-owned `Barkpark.Content.PaperTaskResolver` seam, which
  the Tasks plugin fills via `paper_task_resolver/0`.

  Pins both paths of the seam against ONE paper:

    * TASKS ON — the Registry resolves `Barkpark.Tasks.PaperResolver`, the chip
      shows its `met/total` count, and the query blocks render real rows and a
      real aggregate — no placeholder anywhere.
    * TASKS OFF (the Tasks plugin out of the load order) — the seam answers
      `nil`, and the same paper renders an explicit "unavailable" placeholder
      for the chip's criteria segment and for each task query block, while the
      rest of the paper (heading, prose, an author-pinned snapshot) renders
      normally. No crash, and no silently empty board.

  The true kill switch (`BARKPARK_PLUGINS=""`, nothing registered, Registry
  init publishes `[]`) is proven by the release eval in the PR.
  """
  use Barkpark.DataCase, async: false
  use Barkpark.RegistryCase, async: false

  alias Barkpark.{Content, Tasks, TenancyFixtures}
  alias Barkpark.Content.{PaperTaskResolver, Papers}
  alias Barkpark.PortableDoc.Render

  @dataset "production"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    epic = "ptr-epic-#{System.unique_integer([:positive])}"
    title = "Seam chip #{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.create_document(
        "task",
        %{
          "doc_id" => "ptr-#{System.unique_integer([:positive])}",
          "title" => title,
          "content" => %{
            "kind" => "task",
            "lifecycle_status" => "in_progress",
            "priority" => 1,
            "parent_id" => epic,
            "acceptance_criteria" => [
              %{"criterion" => "a", "met" => true},
              %{"criterion" => "b", "met" => false}
            ]
          }
        },
        @dataset,
        scope
      )

    blocks = [
      %{"type" => "heading", "level" => 2, "text" => "Plan heading"},
      %{
        "type" => "paragraph",
        "content" => [
          %{"type" => "text", "value" => "Prose before the chip "},
          %{"type" => "wikilink", "target" => title, "children" => []}
        ]
      },
      %{"type" => "task-list", "query" => %{"parent_id" => epic}},
      %{"type" => "stat", "label" => "Open", "query" => %{"source" => "tasks"}},
      %{"type" => "task-list", "snapshot" => [%{"title" => "Pinned row", "status" => "done"}]}
    ]

    %{scope: scope, blocks: blocks, title: title}
  end

  defp render(blocks, scope, style) do
    wikilinks = Papers.resolve_wikilinks_in_blocks(blocks, @dataset, scope)
    resolved = Papers.resolve_tasks_in_blocks(blocks, scope, @dataset)
    {resolved, Render.render_blocks(resolved, %{style: style, wikilinks: wikilinks})}
  end

  defp tasks_off!, do: Barkpark.PluginEnv.with_plugins(["media"], %{test: __MODULE__})

  describe "the seam" do
    test "the Tasks plugin's resolver is published under the default load order" do
      assert Barkpark.Plugins.Tasks.paper_task_resolver() == Barkpark.Tasks.PaperResolver
      assert PaperTaskResolver.get() == Barkpark.Tasks.PaperResolver
    end

    test "a load order without tasks resolves no resolver" do
      :ok = tasks_off!()
      assert PaperTaskResolver.get() == nil
    end
  end

  describe "tasks ON (control)" do
    test "the chip count, the rows and the aggregate render; no placeholder", ctx do
      {resolved, html} = render(ctx.blocks, ctx.scope, :article)

      [_h, _p, list, stat, _pinned] = resolved
      refute Map.has_key?(list, "unavailable")
      assert [%{"title" => title}] = list["snapshot"]
      assert title == ctx.title
      refute Map.has_key?(stat, "query")
      assert is_integer(stat["value"]) or is_binary(stat["value"])

      assert html =~ "1/2"
      assert html =~ "Plan heading"
      assert html =~ "Pinned row"
      refute html =~ "unavailable"
    end
  end

  describe "tasks OFF" do
    test "the chip criteria and each query block render an explicit placeholder; the rest renders",
         ctx do
      :ok = tasks_off!()

      {resolved, html} = render(ctx.blocks, ctx.scope, :article)

      [_h, _p, list, stat, pinned] = resolved
      assert list["unavailable"] == true
      assert stat["unavailable"] == true
      refute Map.has_key?(list, "snapshot")
      refute Map.has_key?(pinned, "unavailable")

      # The chip: still a chip (title, status), its criteria segment NAMED
      # unavailable — never omitted, which would read as "no criteria".
      assert html =~ ~s(data-unavailable="tasks" class="bp-task-chip")
      assert html =~ "criteria unavailable"
      refute html =~ "1/2"

      # Each query block: the named placeholder, once per block.
      placeholders = Regex.scan(~r/class="bp-dataviz--empty bp-task-unavailable"/, html)
      assert length(placeholders) == 2
      assert html =~ "task-list — tasks unavailable — the Tasks plugin is not loaded"
      assert html =~ "stat — tasks unavailable — the Tasks plugin is not loaded"

      # The rest of the paper renders normally.
      assert html =~ "Plan heading"
      assert html =~ "Prose before the chip"
      assert html =~ "Pinned row"
    end

    test "the email style names the placeholder too", ctx do
      :ok = tasks_off!()

      {_resolved, html} = render(ctx.blocks, ctx.scope, :email)

      assert html =~ "task-list — tasks unavailable — the Tasks plugin is not loaded"
      assert html =~ "stat — tasks unavailable — the Tasks plugin is not loaded"
      assert html =~ "criteria unavailable"
      assert html =~ "Pinned row"
    end

    test "nested query blocks (section / columns / children) are marked too" do
      :ok = tasks_off!()
      q = %{"parent_id" => "x"}

      blocks = [
        %{"type" => "section", "blocks" => [%{"type" => "task-board", "query" => q}]},
        %{"type" => "columns", "columns" => [[%{"type" => "roadmap", "query" => q}], "junk"]},
        %{"type" => "terminal", "children" => [%{"type" => "task-detail", "query" => q}]}
      ]

      [s, c, t] = Papers.resolve_tasks_in_blocks(blocks, [], @dataset)
      assert [%{"unavailable" => true}] = s["blocks"]
      assert [[%{"unavailable" => true}], "junk"] = c["columns"]
      assert [%{"unavailable" => true}] = t["children"]
    end
  end
end
