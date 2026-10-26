defmodule BarkparkWeb.GroqReferencesWikilinksTest do
  @moduledoc """
  task-b1eb62967525ad1b (design: /papers/references-body-links-design):
  Sanity's `references()` counts a link inside Portable Text (a markDef's
  `_ref`). Barkpark stores a body link as a PortableDoc wikilink
  `{type: "wikilink", docId, target}`, which references() did not see. It now
  counts one, found through `documents_content_wikilinks_idx`, and only where
  the caller may read the field that holds it.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tenancy}

  @dataset "groq_wikilinks_ds"
  @version "v2025-02-19"

  setup do
    {:ok, ws} = Tenancy.create_workspace(%{slug: "groq-wl", name: "GROQ wikilinks"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "site", name: "Site"})
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "author", "title" => "author", "visibility" => "public", "fields" => []},
        @dataset,
        scope
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "post",
          "visibility" => "public",
          "fields" => [
            %{"name" => "author", "type" => "reference", "refType" => "author"},
            %{"name" => "body", "type" => "richText"},
            %{"name" => "notes", "type" => "richText", "private" => true}
          ]
        },
        @dataset,
        scope
      )

    publish!("author", %{"_id" => "ada"}, scope)
    # p1 links Ada only in its body, p2 by its author field, p3 only in its
    # private notes; p4 links someone else.
    publish!("post", %{"_id" => "p1", "body" => body("ada")}, scope)
    publish!("post", %{"_id" => "p2", "author" => "ada"}, scope)
    publish!("post", %{"_id" => "p3", "notes" => body("ada")}, scope)
    publish!("post", %{"_id" => "p4", "body" => body("bo")}, scope)

    reader = "groq-wl-read-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(reader, "reader", @dataset, ["read", "write"], ws.id)
    admin = "groq-wl-admin-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(admin, "admin", @dataset, ["read", "admin"], ws.id)

    {:ok, reader: reader, admin: admin}
  end

  defp body(id),
    do: %{
      "blocks" => [
        %{
          "type" => "paragraph",
          "content" => [
            %{"type" => "text", "value" => "see "},
            %{
              "type" => "wikilink",
              "docId" => id,
              "target" => id,
              "children" => [%{"type" => "text", "value" => id}]
            }
          ]
        }
      ]
    }

  defp publish!(type, attrs, scope) do
    {:ok, _} = Content.create_document(type, attrs, @dataset, scope)
    {:ok, _} = Content.publish_document(attrs["_id"], type, @dataset, scope)
  end

  defp q(token, query) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> get("/w/groq-wl/p/site/#{@version}/data/query/#{@dataset}", %{"query" => query})
    |> json_response(200)
    |> Map.fetch!("result")
  end

  test "references() counts a body wikilink, typed and typeless", %{reader: reader} do
    assert q(reader, ~s'*[_type == "post" && references("ada")] | order(_id asc)._id') ==
             ["p1", "p2"]

    assert q(reader, ~s'*[references("ada")] | order(_id asc)._id') == ["p1", "p2"]
    assert q(reader, ~s'count(*[_type == "post" && references("ada")])') == 2
    assert q(reader, ~s'*[_id == "p1"][0]{"links": references("ada")}') == %{"links" => true}
  end

  test "a wikilink in a field the caller may not read is not counted", %{
    reader: reader,
    admin: admin
  } do
    refute "p3" in q(reader, ~s'*[_type == "post" && references("ada")]._id')

    assert q(admin, ~s'*[_type == "post" && references("ada")] | order(_id asc)._id') ==
             ["p1", "p2", "p3"]
  end
end
