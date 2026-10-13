defmodule BarkparkWeb.PaperFleetBlocksControllerTest do
  @moduledoc """
  task-4feb8efa46a0ed33 — `GET /w/:ws/p/:proj/v1/papers/:slug/fleet-blocks`
  renders a paper's fleet blocks (task list/board/detail, …) as HTML over
  HTTP, by a member token, the same render the Studio canvas gets pushed
  in-process.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content, Tasks}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @dataset "production"

  setup do
    ws = create_workspace!("pfb-#{System.unique_integer([:positive])}")
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

    member_raw = "pfb-member-#{System.unique_integer([:positive])}"
    {:ok, member} = Auth.create_token(member_raw, "pfb-member", @dataset, ["read", "write"])
    {:ok, _} = TenancyAuth.create_membership(ws.id, member.id, "member", "api_token")

    %{ws: ws, project: project, scope: scope, member_raw: member_raw}
  end

  defp req(raw) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer #{raw}")
    |> put_req_header("content-type", "application/json")
  end

  defp fleet_blocks_path(ws, project, slug),
    do: "/w/#{ws.slug}/p/#{project.slug}/v1/papers/#{slug}/fleet-blocks"

  defp seed_task!(scope, epic) do
    title = "Fleet block row #{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.create_document(
        "task",
        %{
          "doc_id" => "pfb-#{System.unique_integer([:positive])}",
          "title" => title,
          "content" => %{"kind" => "task", "lifecycle_status" => "open", "parent_id" => epic}
        },
        @dataset,
        scope
      )

    title
  end

  defp seed_paper!(ws, project, blocks) do
    slug = "paper-fleet-blocks-#{System.unique_integer([:positive])}"

    attrs =
      Barkpark.LabelFixtures.paper_attrs(%{
        slug: slug,
        blocks: blocks,
        workspace_id: ws.id,
        project_id: project.id
      })

    {:ok, _paper} = Content.upsert_paper(attrs)
    slug
  end

  test "renders a task-list block's live rows as HTML, keyed by block id", %{
    ws: ws,
    project: project,
    scope: scope,
    member_raw: raw
  } do
    epic = "pfb-epic-#{System.unique_integer([:positive])}"
    title = seed_task!(scope, epic)

    block = %{"id" => "fleet-1", "type" => "task-list", "query" => %{"parent_id" => epic}}
    slug = seed_paper!(ws, project, [block])

    conn = get(req(raw), fleet_blocks_path(ws, project, slug))
    body = json_response(conn, 200)

    assert body["slug"] == slug
    assert is_binary(body["rev"])
    assert %{"fleet-1" => html} = body["blocks"]
    assert html =~ title
  end

  test "a non-fleet block (plain paragraph) is absent from the response", %{
    ws: ws,
    project: project,
    member_raw: raw
  } do
    blocks = [%{"id" => "lead", "type" => "paragraph", "text" => "not a fleet block"}]
    slug = seed_paper!(ws, project, blocks)

    conn = get(req(raw), fleet_blocks_path(ws, project, slug))
    assert %{"blocks" => %{}} = json_response(conn, 200)
  end

  test "an unknown paper slug is a 404", %{ws: ws, project: project, member_raw: raw} do
    conn = get(req(raw), fleet_blocks_path(ws, project, "no-such-paper"))
    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
  end

  test "an anonymous caller is refused", %{ws: ws, project: project} do
    blocks = [
      %{"id" => "fleet-1", "type" => "task-list", "query" => %{"parent_id" => "pfb-none"}}
    ]

    slug = seed_paper!(ws, project, blocks)

    conn = get(scoped_conn(), fleet_blocks_path(ws, project, slug))
    assert conn.status in [401, 403]
  end

  test "Tasks disabled for the workspace renders the unavailable placeholder, never a crash",
       %{ws: ws, project: project, member_raw: raw} do
    {:ok, _} =
      Barkpark.Tenancy.set_workspace_plugin_settings(ws.id, %{"tasks" => %{"enabled" => false}})

    block = %{"id" => "fleet-1", "type" => "task-list", "query" => %{"parent_id" => "pfb-none"}}
    slug = seed_paper!(ws, project, [block])

    conn = get(req(raw), fleet_blocks_path(ws, project, slug))
    body = json_response(conn, 200)
    assert %{"fleet-1" => html} = body["blocks"]
    assert html =~ ~s(data-unavailable="tasks")
  end
end
