defmodule BarkparkWeb.GroqReadCompatSlugsTest do
  @moduledoc """
  task-c2be444ac1d07719, slice 2: GROQ reads a declared slug stored as a
  string as Sanity reads its {_type: "slug", current}. Expected values are
  Sanity's, read from ecu57yeh/e2e-local on 2026-10-26 for the same shape
  (post-01: slug.current "fixture-post-01", slug._type "slug",
  *[slug.current == "fixture-post-01"] finds it, defined(slug.current) counts
  every post). `slug` itself still reads the string.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tenancy}

  @dataset "groq_slug_ds"

  setup do
    {:ok, ws} = Tenancy.create_workspace(%{slug: "groq-slug", name: "GROQ slug"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "site", name: "Site"})
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [
            %{"name" => "slug", "type" => "slug"},
            %{"name" => "handle", "type" => "string"},
            %{
              "name" => "seo",
              "type" => "composite",
              "fields" => [%{"name" => "path", "type" => "slug"}]
            }
          ]
        },
        @dataset,
        scope
      )

    for {id, content} <- [
          {"p1",
           %{"slug" => "fixture-post-01", "handle" => "h1", "seo" => %{"path" => "seo-one"}}},
          {"p2", %{"slug" => "fixture-post-02"}},
          {"p3", %{"slug" => %{"_type" => "slug", "current" => "stored-object"}}},
          {"p4", %{"handle" => "no-slug"}}
        ] do
      {:ok, _} =
        Content.create_document(
          "post",
          Map.merge(%{"_id" => id, "title" => id}, content),
          @dataset,
          scope
        )

      {:ok, _} = Content.publish_document(id, "post", @dataset, scope)
    end

    token = "groq-slug-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(token, "slug", @dataset, ["read"], ws.id)
    {:ok, token: token}
  end

  defp q(conn, token, query) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> get("/w/groq-slug/p/site/v2025-02-19/data/query/#{@dataset}", %{"query" => query})
    |> json_response(200)
    |> Map.fetch!("result")
  end

  test "a declared slug answers current and _type; any other string does not", %{
    conn: conn,
    token: t
  } do
    assert q(conn, t, ~s|*[_id == "p1"][0].slug.current|) == "fixture-post-01"
    assert q(conn, t, ~s|*[_id == "p1"][0].slug._type|) == "slug"
    assert q(conn, t, ~s|*[_id == "p1"][0].slug|) == "fixture-post-01"
    assert q(conn, t, ~s|*[_id == "p1"][0].handle.current|) == nil
    assert q(conn, t, ~s|*[_id == "p1"][0].seo.path.current|) == "seo-one"
    assert q(conn, t, ~s|*[_id == "p3"][0].slug.current|) == "stored-object"
    assert q(conn, t, ~s|*[_id == "p1"][0]{"s": slug.current}|) == %{"s" => "fixture-post-01"}
  end

  test "filters on slug.current find bare and stored-object slugs", %{conn: conn, token: t} do
    assert q(conn, t, ~s|*[_type == "post" && slug.current == "fixture-post-01"]._id|) == ["p1"]
    assert q(conn, t, ~s|*[slug.current == "fixture-post-02"]._id|) == ["p2"]

    assert q(
             conn,
             t,
             ~s|*[_type == "post" && slug.current in ["fixture-post-02", "stored-object"]] \| order(_id) ._id|
           ) ==
             ["p2", "p3"]

    assert q(conn, t, ~s|count(*[_type == "post" && defined(slug.current)])|) == 3
    assert q(conn, t, ~s|count(*[_type == "post" && !defined(slug.current)])|) == 1
    assert q(conn, t, ~s|*[_type == "post" && !defined(slug.current)]._id|) == ["p4"]

    assert q(conn, t, ~s|*[_type == "post" && defined(slug)] \| order(slug.current desc) [0]._id|) ==
             "p3"
  end
end
