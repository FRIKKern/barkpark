defmodule BarkparkWeb.GroqSourceMapTest do
  # task-640e8371b8e468ce, T1: `resultSourceMap` on the GROQ endpoint, in Sanity's shape,
  # only when asked. Each mapping is checked by resolving it to (result path, document,
  # source path), as the conformance mode compares it with Sanity.
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tenancy}

  @dataset "csm_ds"
  @path "/w/csm-ws/p/site/v2025-02-19/data/query/#{@dataset}"

  setup do
    {:ok, ws} = Tenancy.create_workspace(%{slug: "csm-ws", name: "CSM"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "site", name: "Site"})
    scope = [workspace_id: ws.id, project_id: proj.id]

    for type <- ["author", "post"] do
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => type, "title" => type, "visibility" => "public", "fields" => []},
          @dataset,
          scope
        )
    end

    publish = fn type, id, content ->
      {:ok, _} =
        Content.create_document(type, %{"doc_id" => id, "content" => content}, @dataset, scope)

      {:ok, _} = Content.publish_document(id, type, @dataset, scope)
    end

    publish.("author", "ada", %{"name" => "Ada"})

    publish.("post", "p1", %{
      "title" => "First",
      "author" => %{"_type" => "reference", "_ref" => "ada"},
      "tags" => ["a", "b"],
      "links" => [%{"_key" => "k1", "title" => "A"}, %{"_key" => "k2", "title" => "B"}]
    })

    publish.("post", "p2", %{
      "title" => "Second",
      "author" => %{"_type" => "reference", "_ref" => "ada"}
    })

    # A draft of p1 over its published version.
    {:ok, _} =
      Content.create_document(
        "post",
        %{"doc_id" => "p1", "content" => %{"title" => "First draft"}},
        @dataset,
        scope
      )

    token = "csm-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(token, "csm", @dataset, ["read", "write"], ws.id)
    %{token: token}
  end

  defp fetch(token, query, extra \\ %{}) do
    scoped_conn()
    |> put_req_header("authorization", "Bearer " <> token)
    |> get(@path, Map.merge(%{"query" => query}, extra))
    |> json_response(200)
  end

  # {result path => {document _id, source path}}
  defp resolved(%{"resultSourceMap" => %{"documents" => docs, "paths" => paths, "mappings" => m}}) do
    Map.new(m, fn {rpath,
                   %{
                     "source" => %{"document" => d, "path" => p, "type" => "documentValue"},
                     "type" => "value"
                   }} ->
      {rpath, {Enum.at(docs, d)["_id"], Enum.at(paths, p)}}
    end)
  end

  test "no resultSourceMap parameter: no map, the response as before", %{token: token} do
    body = fetch(token, ~s|*[_id == "p1"][0]{title}|)
    refute Map.has_key?(body, "resultSourceMap")
    assert Map.keys(body) |> Enum.sort() == ["ms", "query", "result", "syncTags"]
  end

  test "fields, projections and -> map to their own documents", %{token: token} do
    body =
      fetch(token, ~s|*[_id == "p1"][0]{title, author->{name}}|, %{"resultSourceMap" => "true"})

    assert resolved(body) == %{
             "$['title']" => {"p1", "$['title']"},
             "$['author']['name']" => {"ada", "$['name']"}
           }

    assert body["resultSourceMap"]["documents"] == [
             %{"_id" => "ada", "_type" => "author"},
             %{"_id" => "p1", "_type" => "post"}
           ]
  end

  test "a whole document maps once as $; a slice maps each row; computed values do not map", %{
    token: token
  } do
    assert resolved(fetch(token, ~s|*[_id == "p1"][0]|, %{"resultSourceMap" => "true"})) == %{
             "$" => {"p1", "$"}
           }

    body =
      fetch(
        token,
        ~s/*[_type == "post"] | order(_id)[0...2]{_id, title, "n": count(tags), "lit": "x"}/,
        %{"resultSourceMap" => "true"}
      )

    assert resolved(body) == %{
             "$[0]['_id']" => {"p1", "$['_id']"},
             "$[0]['title']" => {"p1", "$['title']"},
             "$[1]['_id']" => {"p2", "$['_id']"},
             "$[1]['title']" => {"p2", "$['title']"}
           }
  end

  test "array items: index or _key, filters keep the stored position, maps and spreads", %{
    token: token
  } do
    q =
      ~s|*[_id == "p1"][0]{"second": links[1].title, "b": links[title == "B"], "titles": links[].title, ...}|

    plain = resolved(fetch(token, q, %{"resultSourceMap" => "true"}))
    assert plain["$['second']"] == {"p1", "$['links'][1]['title']"}
    assert plain["$['b'][0]"] == {"p1", "$['links'][1]"}
    assert plain["$['titles'][0]"] == {"p1", "$['links'][0]['title']"}
    assert plain["$['tags']"] == {"p1", "$['tags']"}

    keyed = resolved(fetch(token, q, %{"resultSourceMap" => "withKeyArraySelector"}))
    assert keyed["$['second']"] == {"p1", "$['links'][?(@._key=='k2')]['title']"}
    assert keyed["$['b'][0]"] == {"p1", "$['links'][?(@._key=='k2')]"}
  end

  test "a subquery with ^ maps its rows to their documents", %{token: token} do
    q =
      ~s/*[_id == "ada"][0]{name, "posts": *[_type == "post" && author._ref == ^._id] | order(_id){title}}/

    m = resolved(fetch(token, q, %{"resultSourceMap" => "true"}))
    assert m["$['name']"] == {"ada", "$['name']"}
    assert m["$['posts'][0]['title']"] == {"p1", "$['title']"}
    assert m["$['posts'][1]['title']"] == {"p2", "$['title']"}
  end

  test "under drafts a draft maps to its drafts. id; the result is unchanged by asking", %{
    token: token
  } do
    q = ~s|*[_id == "p1"][0]{title}|
    with_map = fetch(token, q, %{"resultSourceMap" => "true", "perspective" => "drafts"})
    without = fetch(token, q, %{"perspective" => "drafts"})

    assert with_map["result"] == without["result"]
    assert with_map["result"]["title"] == "First draft"
    assert resolved(with_map) == %{"$['title']" => {"drafts.p1", "$['title']"}}
  end
end
