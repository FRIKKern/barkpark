defmodule BarkparkWeb.BulldocsReaderDatasetTest do
  use BarkparkWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.Content

  setup do
    {workspace, project} = ensure_default_scope!()
    dataset = "reader-dataset-#{System.unique_integer([:positive])}"
    label = "reader-dataset-label-#{System.unique_integer([:positive])}"
    slug = "reader-dataset-paper-#{System.unique_integer([:positive])}"
    scope = [workspace_id: workspace.id, project_id: project.id]

    seed_task!("Wanted non-production task", label, dataset, scope)
    seed_task!("Wrong production task", label, "production", scope)

    blocks = [
      %{"id" => "tasks", "type" => "task-list", "query" => %{"label" => label}},
      %{
        "id" => "body",
        "type" => "paragraph",
        "content" => [%{"type" => "text", "value" => "Dataset reader proof"}]
      }
    ]

    {:ok, _paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: slug,
          dataset: dataset,
          blocks: blocks,
          workspace_id: workspace.id,
          project_id: project.id
        })
      )

    %{dataset: dataset, slug: slug}
  end

  test "source resolves implicit task queries in the requested non-production dataset", %{
    conn: conn,
    dataset: dataset,
    slug: slug
  } do
    [task_block | _] =
      conn
      |> get("/d/#{dataset}/papers/#{slug}/source")
      |> json_response(200)
      |> get_in(["source", "blocks"])

    titles = Enum.map(task_block["snapshot"], & &1["title"])
    assert titles == ["Wanted non-production task"]
  end

  test "email resolves implicit task queries in the requested non-production dataset", %{
    conn: conn,
    dataset: dataset,
    slug: slug
  } do
    html = conn |> get("/d/#{dataset}/papers/#{slug}/email") |> response(200)
    assert html =~ "Wanted non-production task"
    refute html =~ "Wrong production task"
  end

  test "LiveView resolves implicit task queries in the requested non-production dataset", %{
    conn: conn,
    dataset: dataset,
    slug: slug
  } do
    {:ok, _view, html} = live(conn, "/d/#{dataset}/papers/#{slug}")
    assert html =~ "Wanted non-production task"
    refute html =~ "Wrong production task"
  end

  defp seed_task!(title, label, dataset, scope) do
    Content.upsert_document(
      "task",
      %{
        "doc_id" => "task-#{System.unique_integer([:positive])}",
        "title" => title,
        "content" => %{
          "kind" => "task",
          "lifecycle_status" => "open",
          "labels" => [label]
        }
      },
      dataset,
      scope
    )
  end
end
