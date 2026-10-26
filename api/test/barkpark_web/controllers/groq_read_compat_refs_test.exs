defmodule BarkparkWeb.GroqReadCompatRefsTest do
  @moduledoc """
  task-c2be444ac1d07719, slice 1: GROQ reads a declared reference stored as a
  bare id as Sanity reads its {_type: "reference", _ref}. Expected values are
  Sanity's, read from ecu57yeh/e2e-local on 2026-10-26 for the same shape
  (post-01: author._ref "author-alan", author._type "reference", title._ref
  null, count(*[_type=='post' && references('author-alan')]) 10). Nothing
  stored changes: `author` itself still reads the id.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tenancy}

  @dataset "groq_compat_ds"

  setup do
    {:ok, ws} = Tenancy.create_workspace(%{slug: "groq-compat", name: "GROQ compat"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "site", name: "Site"})
    scope = [workspace_id: ws.id, project_id: proj.id]
    ref = fn name -> %{"name" => name, "type" => "reference", "refType" => "author"} end

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "author",
          "title" => "Author",
          "visibility" => "public",
          "fields" => [%{"name" => "name", "type" => "string"}]
        },
        @dataset,
        scope
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "note", "type" => "string"},
            ref.("author"),
            Map.put(ref.("hidden"), "private", true),
            %{"name" => "seo", "type" => "composite", "fields" => [ref.("reviewer")]},
            %{
              "name" => "coauthors",
              "type" => "arrayOf",
              "of" => %{"type" => "reference", "refType" => "author"}
            }
          ]
        },
        @dataset,
        scope
      )

    publish = fn type, attrs ->
      {:ok, _} = Content.create_document(type, attrs, @dataset, scope)
      {:ok, _} = Content.publish_document(attrs["_id"], type, @dataset, scope)
    end

    publish.("author", %{"_id" => "alan", "name" => "Alan Turing"})
    publish.("author", %{"_id" => "ada", "name" => "Ada Lovelace"})
    publish.("post", %{"_id" => "p1", "title" => "One", "note" => "alan", "author" => "alan"})
    publish.("post", %{"_id" => "p2", "title" => "Two", "seo" => %{"reviewer" => "alan"}})
    publish.("post", %{"_id" => "p3", "title" => "Three", "coauthors" => ["ada", "alan"]})
    publish.("post", %{"_id" => "p4", "title" => "Four", "author" => "ada", "hidden" => "alan"})

    publish.("post", %{
      "_id" => "p5",
      "title" => "Five",
      "author" => %{"_type" => "reference", "_ref" => "alan"}
    })

    # A read-only member token: not an admin, so `hidden` is redacted for it.
    token = "groq-compat-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(token, "compat", @dataset, ["read"], ws.id)
    {:ok, token: token}
  end

  defp q(conn, token, query) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> get("/w/groq-compat/p/site/v2025-02-19/data/query/#{@dataset}", %{"query" => query})
    |> json_response(200)
    |> Map.fetch!("result")
  end

  test "a declared reference answers _ref and _type; any other string does not", %{
    conn: conn,
    token: t
  } do
    assert q(conn, t, ~s|*[_id == "p1"][0].author._ref|) == "alan"
    assert q(conn, t, ~s|*[_id == "p1"]{"r": author._ref}|) == [%{"r" => "alan"}]
    assert q(conn, t, ~s|*[_id == "p1"][0].author._type|) == "reference"
    assert q(conn, t, ~s|*[_id == "p1"][0].author|) == "alan"
    assert q(conn, t, ~s|*[_id == "p1"][0].title._ref|) == nil
    assert q(conn, t, ~s|*[_id == "p1"][0].note._ref|) == nil
    assert q(conn, t, ~s|*[_id == "p2"][0].seo.reviewer._ref|) == "alan"
    assert q(conn, t, ~s|*[_id == "p5"][0].author._ref|) == "alan"
    assert q(conn, t, ~s|*[_id == "p1"][0].author->name|) == "Alan Turing"
  end

  test "references() matches bare ids in declared positions, nested and in arrays", %{
    conn: conn,
    token: t
  } do
    assert q(conn, t, ~s|*[_type == "post" && references("alan")] \| order(_id) ._id|) ==
             ["p1", "p2", "p3", "p5"]

    assert q(conn, t, ~s|count(*[references("alan")])|) == 4

    assert q(
             conn,
             t,
             ~s|*[_type == "author" && _id == "alan"][0]{"n": count(*[references(^._id)])}.n|
           ) == 4
  end

  test "author._ref in a filter finds the bare and the stored-object shape", %{
    conn: conn,
    token: t
  } do
    assert q(conn, t, ~s|*[_type == "post" && author._ref == "alan"] \| order(_id) ._id|) == [
             "p1",
             "p5"
           ]

    assert q(conn, t, ~s|count(*[_type == "post" && author._ref == "alan"])|) == 2
    assert q(conn, t, ~s|*[author._ref == "alan"] \| order(_id) ._id|) == ["p1", "p5"]
  end

  test "a private reference the caller cannot read never leaks through the new paths",
       %{conn: conn, token: t} do
    assert q(conn, t, ~s|*[_id == "p4"][0].hidden._ref|) == nil
    refute "p4" in q(conn, t, ~s|*[_type == "post" && references("alan")]._id|)
    assert q(conn, t, ~s|*[_type == "post" && hidden._ref == "alan"]._id|) == []
  end
end
