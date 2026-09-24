defmodule BarkparkWeb.BulldocsLiveTasksEnablementTest do
  @moduledoc """
  task-857c9f987268a75a: the public /papers reader honours PER-WORKSPACE Tasks
  enablement, keyed by the RENDERED PAPER'S own workspace.

  Tasks is registered on the instance throughout. Workspace A is the seeded
  Default (Tasks ON), read through the flat `/papers/:slug` reader; workspace B
  switches Tasks OFF in `workspaces.settings["plugins"]` and its paper is read
  through the share-gated scoped reader `/w/:ws/p/:project/papers/:slug`. Each
  paper carries a task chip (wikilink to a task with 1/2 criteria) and a
  query-carrying `task-list`. A renders the criteria and the rows; B renders
  the explicit unavailable placeholders — never B's task data — even though the
  caller's default workspace (A) has Tasks ON. The reverse direction (Default
  OFF, paper's workspace ON) proves the check is not keyed by the default.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Content, Tasks, Tenancy, TenancyFixtures}

  @dataset "production"

  setup do
    {ws_a, project_a} = TenancyFixtures.ensure_default_scope!()
    ws_b = TenancyFixtures.create_workspace!()
    project_b = TenancyFixtures.create_project!(ws_b)

    Barkpark.LabelFixtures.register_tags!(@dataset)

    a = seed!(ws_a, project_a)
    b = seed!(ws_b, project_b)

    Barkpark.SharingFixtures.plant_shares!(
      "#{ws_b.slug}/#{project_b.slug}/#{@dataset}:papers:read"
    )

    %{
      a: Map.put(a, :path, "/papers/#{a.slug}"),
      b: Map.put(b, :path, "/w/#{ws_b.slug}/p/#{project_b.slug}/papers/#{b.slug}"),
      ws_a: ws_a,
      ws_b: ws_b
    }
  end

  # Task schemas, one PUBLISHED task (1/2 criteria, under an epic), and a
  # published paper chipping it and querying the epic — all in one workspace.
  defp seed!(ws, project) do
    scope = [workspace_id: ws.id, project_id: project.id]

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    n = System.unique_integer([:positive])
    epic = "enab-epic-#{n}"
    title = "Enablement chip #{n}"

    {:ok, doc} =
      Content.create_document(
        "task",
        %{
          "doc_id" => "enab-#{n}",
          "title" => title,
          "content" =>
            Barkpark.LabelFixtures.with_labels(%{
              "kind" => "task",
              "brief" => Barkpark.TaskBriefFixtures.brief(),
              "lifecycle_status" => "open",
              "parent_id" => epic,
              "acceptance_criteria" => [
                %{"criterion" => "first", "met" => true},
                %{"criterion" => "second", "met" => false}
              ]
            })
        },
        @dataset,
        scope
      )

    pid = Content.DraftId.published_id(doc.doc_id)
    {:ok, _} = Content.publish_document(pid, "task", @dataset, scope)

    slug = "enab-paper-#{n}"

    {:ok, _paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          "slug" => slug,
          "dataset" => @dataset,
          "style" => "article",
          "workspace_id" => ws.id,
          "project_id" => project.id,
          "blocks" => [
            %{
              "id" => "p1",
              "type" => "paragraph",
              "content" => [
                %{"type" => "text", "value" => "Chip here "},
                %{"type" => "wikilink", "target" => title, "children" => []}
              ]
            },
            %{
              "id" => "t1",
              "type" => "task-list",
              "query" => %{"parent_id" => epic, "dataset" => @dataset}
            }
          ]
        })
      )

    %{slug: slug, title: title}
  end

  defp tasks_disabled!(ws) do
    {:ok, _} = Tenancy.set_workspace_plugin_settings(ws.id, %{"tasks" => %{"enabled" => false}})
    :ok
  end

  defp assert_live!(html, title) do
    assert html =~ "Chip here"
    # The chip's criteria segment AND the task-list row carry the task.
    assert html =~ ~s(<span class="bp-task-chip__badge">○ open · 1/2</span>)
    assert html =~ ~s(<span class="bp-trow__t">#{title}</span>)
    refute html =~ "criteria unavailable"
    refute html =~ "tasks unavailable"
  end

  defp assert_placeholders!(html, title) do
    assert html =~ "Chip here"
    assert html =~ "criteria unavailable"
    assert html =~ "task-list — tasks unavailable"
    refute html =~ "1/2"
    # The chip still names its target, but no task-list row renders.
    assert html =~ ~s(data-taskchip="#{title}")
    refute html =~ ~s(class="bp-trow__t")
  end

  test "A (Tasks ON) renders criteria + rows; B (Tasks OFF) renders the placeholders", ctx do
    :ok = tasks_disabled!(ctx.ws_b)

    {:ok, _view, html_a} = live(build_conn(), ctx.a.path)
    assert_live!(html_a, ctx.a.title)

    # B's caller has no workspace of its own and the instance Default (A) has
    # Tasks ON — only B's own enablement can produce these placeholders.
    {:ok, _view, html_b} = live(build_conn(), ctx.b.path)
    assert_placeholders!(html_b, ctx.b.title)
  end

  test "the caller's default workspace differs from the paper's: the paper's wins", ctx do
    :ok = tasks_disabled!(ctx.ws_a)
    assert Tenancy.get_default_workspace().id == ctx.ws_a.id

    {:ok, _view, html_b} = live(build_conn(), ctx.b.path)
    assert_live!(html_b, ctx.b.title)

    {:ok, _view, html_a} = live(build_conn(), ctx.a.path)
    assert_placeholders!(html_a, ctx.a.title)
  end
end
