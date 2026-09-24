defmodule BarkparkWeb.Studio.PaperTaskPreviewSeamTest do
  @moduledoc """
  task-f4d19b64198780b6: the Studio paper editor preview reads task rows and
  aggregates ONLY through the paper task resolver seam
  (`PaperTaskSeam.resolver/1` over `Barkpark.Content.PaperTaskResolver`), and
  honours the workspace's plugin enablement on top of the boot load order.

    * TASKS ON (control) — a query-carrying task-list previews real rows.
    * TASKS DISABLED FOR THE WORKSPACE — the same block previews the reader's
      "tasks unavailable" placeholder, in both the canvas fleet paint and the
      classic boundary widget. No crash, no empty board, no rows.
    * TASKS OUT OF THE LOAD ORDER — the seam answers nil; same placeholder.
    * SOURCE — no file under studio_live names the Tasks plugin's substrate.

  A mutation that calls the substrate directly (bypassing the seam) keeps
  showing rows with Tasks disabled, which reds the two placeholder tests.
  """
  use Barkpark.DataCase, async: false
  use Barkpark.RegistryCase, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]
  import Barkpark.TenancyFixtures

  alias Barkpark.{Content, Tasks}
  alias BarkparkWeb.Studio.StudioLive.Components.PaperEditor
  alias BarkparkWeb.Studio.StudioLive.PaperTaskSeam
  alias BarkparkWeb.Studio.StudioLive.Shared.Paper, as: StudioPaper

  @dataset "production"

  setup do
    ws = create_workspace!()
    project = create_project!(ws)
    scope = [workspace_id: ws.id, project_id: project.id]

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    epic = "pts-epic-#{System.unique_integer([:positive])}"
    title = "Seam preview row #{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.create_document(
        "task",
        %{
          "doc_id" => "pts-#{System.unique_integer([:positive])}",
          "title" => title,
          "content" => %{"kind" => "task", "lifecycle_status" => "open", "parent_id" => epic}
        },
        @dataset,
        scope
      )

    block = %{"id" => "pts-list", "type" => "task-list", "query" => %{"parent_id" => epic}}

    socket = %Phoenix.LiveView.Socket{
      assigns: %{current_workspace: ws, current_project: project, dataset: @dataset}
    }

    %{ws: ws, block: block, socket: socket, title: title}
  end

  defp disable_tasks!(ws) do
    {:ok, _} =
      Barkpark.Tenancy.set_workspace_plugin_settings(ws.id, %{"tasks" => %{"enabled" => false}})

    :ok
  end

  defp assert_placeholder(ctx) do
    assert [entry] = StudioPaper.task_previews([ctx.block], ctx.socket)
    assert entry == %{"block_id" => "pts-list", "type" => "task-list", "unavailable" => true}

    # Canvas fleet paint (bp:block-html).
    %{"html" => fleet_html} = StudioPaper.fleet_render(ctx.block, %{"pts-list" => entry})
    assert fleet_html =~ ~s(data-unavailable="tasks")
    assert fleet_html =~ "task-list — tasks unavailable"
    refute fleet_html =~ ctx.title

    # Classic boundary widget.
    widget = render_component(&PaperEditor.task_block_preview/1, block: ctx.block, preview: entry)
    assert widget =~ ~s(data-unavailable="tasks")
    refute widget =~ "Loading live tasks"
    refute widget =~ ctx.title
  end

  test "tasks enabled: the editor preview renders the query's rows (control)", ctx do
    assert PaperTaskSeam.resolver(ctx.ws.id) == Barkpark.Tasks.PaperResolver

    assert [%{"snapshot" => [%{"title" => title}]} = entry] =
             StudioPaper.task_previews([ctx.block], ctx.socket)

    assert title == ctx.title

    %{"html" => html} = StudioPaper.fleet_render(ctx.block, %{"pts-list" => entry})
    assert html =~ ctx.title
    refute html =~ "data-unavailable"
  end

  test "tasks disabled for the workspace: the editor preview renders the unavailable placeholder",
       ctx do
    :ok = disable_tasks!(ctx.ws)
    assert PaperTaskSeam.resolver(ctx.ws.id) == nil
    assert_placeholder(ctx)
  end

  test "tasks out of the plugin load order: the editor preview renders the unavailable placeholder",
       ctx do
    :ok = Barkpark.PluginEnv.with_plugins(["media"], %{test: __MODULE__})
    assert Barkpark.Content.PaperTaskResolver.get() == nil
    assert_placeholder(ctx)
  end

  test "a nested query block (section / columns) is marked too; a pinned snapshot is not", ctx do
    :ok = disable_tasks!(ctx.ws)

    blocks = [
      %{"id" => "sec", "type" => "section", "blocks" => [ctx.block]},
      %{"id" => "cols", "type" => "columns", "columns" => [[%{ctx.block | "id" => "in-col"}]]},
      %{"id" => "pinned", "type" => "task-list", "snapshot" => [%{"title" => "Pinned"}]}
    ]

    assert StudioPaper.task_previews(blocks, ctx.socket) == [
             %{"block_id" => "pts-list", "type" => "task-list", "unavailable" => true},
             %{"block_id" => "in-col", "type" => "task-list", "unavailable" => true}
           ]
  end

  test "no file under studio_live names Barkpark.Tasks; the preview calls the seam" do
    root = Path.expand("../../../../lib/barkpark_web/live/studio", __DIR__)

    files = [
      Path.join(root, "studio_live.ex") | Path.wildcard(Path.join(root, "studio_live/**/*.ex"))
    ]

    files = Enum.filter(files, &File.exists?/1)

    # Control: the scan reaches the file that owns the preview, and that file
    # calls the seam — so an empty offender list is not an empty scan.
    paper = Path.join(root, "studio_live/shared/paper.ex")
    assert paper in files
    assert File.read!(paper) =~ "PaperTaskSeam.resolver("

    offenders =
      for f <- files,
          {line, n} <- f |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          line =~ ~r/Barkpark\.Tasks\b/,
          do: "#{Path.relative_to(f, root)}:#{n}: #{String.trim(line)}"

    assert offenders == []
  end
end
