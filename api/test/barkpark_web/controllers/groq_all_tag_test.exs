defmodule BarkparkWeb.GroqAllTagTest do
  @moduledoc """
  task-d6566cbed9b7c33c: the page-created case. `*[slug.current == $s][0]`
  for a page that does not exist yet scans every type and matches nothing, so
  it read no type or document to tag. It carries `bp:ds:<dataset>:_all`, the tag
  the live events stream sends on every change of the dataset, so creating
  the page refreshes it. A typed query does not carry it.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tenancy}
  alias Barkpark.Groq.SyncTag

  @dataset "groq_alltag_ds"

  setup do
    {:ok, ws} = Tenancy.create_workspace(%{slug: "groq-alltag", name: "GROQ all tag"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "site", name: "Site"})

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "page",
          "title" => "Page",
          "visibility" => "public",
          "fields" => [%{"name" => "slug", "type" => "string"}]
        },
        @dataset,
        workspace_id: ws.id,
        project_id: proj.id
      )

    token = "groq-alltag-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(token, "alltag", @dataset, ["read"], ws.id)
    {:ok, token: token, project_id: proj.id}
  end

  defp tags(conn, token, query) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> get("/w/groq-alltag/p/site/v2025-02-19/data/query/#{@dataset}", %{"query" => query})
    |> json_response(200)
    |> Map.fetch!("syncTags")
  end

  test "an untyped lookup that matches nothing carries the all tag and its twin", %{
    conn: conn,
    token: t,
    project_id: project_id
  } do
    tags = tags(conn, t, ~s|*[slug == "not-yet"][0]|)
    assert "bp:ds:#{@dataset}:_all" in tags
    assert SyncTag.opaque(project_id, "bp:ds:#{@dataset}:_all") in tags
  end

  test "a typed lookup carries its type tag, not the all tag", %{conn: conn, token: t} do
    tags = tags(conn, t, ~s|*[_type == "page" && slug == "not-yet"][0]|)
    assert "bp:ds:#{@dataset}:type:page" in tags
    refute "bp:ds:#{@dataset}:_all" in tags
  end
end
