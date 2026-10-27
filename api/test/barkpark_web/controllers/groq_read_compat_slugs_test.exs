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

    # A type that stores a `slug` string without declaring it a slug: the
    # mixed case for order(slug.current).
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "page",
          "title" => "Page",
          "visibility" => "public",
          "fields" => [%{"name" => "slug", "type" => "string"}]
        },
        @dataset,
        scope
      )

    for id <- ["g1", "g2"] do
      {:ok, _} =
        Content.create_document(
          "page",
          %{"_id" => id, "title" => id, "slug" => "page-" <> id},
          @dataset,
          scope
        )

      {:ok, _} = Content.publish_document(id, "page", @dataset, scope)
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

  # The lead on slice 2: an evaluator sort loads every row, so on a dataset
  # past the per-fetch limit order(slug.current) would be refused where it
  # works today. It sorts in SQL: with a per-fetch limit of 2 the first rows
  # of the 4 posts still come back, in slug order.
  test "order(slug.current) on a declared slug sorts in SQL, under the per-fetch limit",
       %{conn: conn, token: t} do
    previous = Application.get_env(:barkpark, Barkpark.Groq, [])

    Application.put_env(:barkpark, Barkpark.Groq,
      max_documents_per_fetch: 2,
      max_documents_loaded: 2
    )

    on_exit(fn -> Application.put_env(:barkpark, Barkpark.Groq, previous) end)

    assert q(conn, t, ~s|*[_type == "post"] \| order(slug.current asc) [0...2]._id|) == [
             "p1",
             "p2"
           ]

    assert q(conn, t, ~s|*[_type == "post"] \| order(slug.current desc) [0]._id|) == "p4"

    assert q(conn, t, ~s|*[_type == "post" && defined(slug)] \| order(slug.current desc) [0]._id|) ==
             "p3"
  end

  # The lead: when only some types in scope declare the slug, order() keeps
  # today's SQL sort (a bare slug sorts as missing) rather than an evaluator
  # sort that could be refused at the per-fetch limit. It still answers.
  test "order(slug.current) over types that declare it and types that don't stays a SQL sort",
       %{conn: conn, token: t} do
    previous = Application.get_env(:barkpark, Barkpark.Groq, [])

    Application.put_env(:barkpark, Barkpark.Groq,
      max_documents_per_fetch: 2,
      max_documents_loaded: 2
    )

    on_exit(fn -> Application.put_env(:barkpark, Barkpark.Groq, previous) end)

    ids = q(conn, t, ~s|*[_type in ["post", "page"]] \| order(slug.current asc) [0...2]._id|)
    assert length(ids) == 2
  end
end
