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
      "body" => [
        %{
          "_type" => "block",
          "_key" => "b1",
          "children" => [%{"_type" => "span", "_key" => "s1", "text" => "Hello"}]
        }
      ],
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
    %{token: token, scope: scope}
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

  test "T2: functions that pass a stored value through map to it", %{token: token} do
    q =
      ~s|*[_id == "p1"][0]{"up": upper(title), "low": lower(title), "c": coalesce(missing, title), "cl": coalesce("lit", title), "s": select(defined(title) => title, "x"), "sl": select(defined(missing) => title, "x"), "t": pt::text(body), "n": count(tags)}|

    m = resolved(fetch(token, q, %{"resultSourceMap" => "true"}))

    assert m == %{
             "$['up']" => {"p1", "$['title']"},
             "$['low']" => {"p1", "$['title']"},
             "$['c']" => {"p1", "$['title']"},
             "$['s']" => {"p1", "$['title']"},
             "$['t']" => {"p1", "$['body']"}
           }
  end

  test "T2: a[] over a list, array::unique and order() of a plain list keep each item's source",
       %{token: token} do
    q = ~s/array::unique(*[_type == "post"].tags[]) | order(@ desc)/
    body = fetch(token, q, %{"resultSourceMap" => "true"})
    # p2 has no tags: its null item sorts first and maps to nothing.
    assert body["result"] == [nil, "b", "a"]
    assert resolved(body) == %{"$[1]" => {"p1", "$['tags'][1]"}, "$[2]" => {"p1", "$['tags'][0]"}}
  end

  test "a bare-string reference maps _ref and _type as Sanity does, never a computed _weak", %{
    token: token,
    scope: scope
  } do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "card",
          "title" => "card",
          "visibility" => "public",
          "fields" => [%{"name" => "who", "type" => "reference", "refType" => "author"}]
        },
        @dataset,
        scope
      )

    {:ok, _} =
      Content.create_document(
        "card",
        %{"doc_id" => "c1", "content" => %{"who" => "ada"}},
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document("c1", "card", @dataset, scope)

    body =
      fetch(
        token,
        ~s|*[_id == "c1"][0]{"ref": who._ref, "t": who._type, "w": who._weak, "name": who->name}|,
        %{"resultSourceMap" => "true"}
      )

    assert body["result"]["ref"] == "ada"

    # _ref and _type map where Sanity's map points; a computed _weak maps nowhere.
    assert resolved(body) == %{
             "$['ref']" => {"c1", "$['who']['_ref']"},
             "$['t']" => {"c1", "$['who']['_type']"},
             "$['name']" => {"ada", "$['name']"}
           }
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

  describe "private fields" do
    setup %{scope: scope} do
      for {type, fields} <- [
            {"member",
             [
               %{"name" => "name", "type" => "string"},
               %{"name" => "email", "type" => "string", "private" => true}
             ]},
            {"note",
             [
               %{"name" => "title", "type" => "string"},
               %{"name" => "secret", "type" => "string", "private" => true},
               %{"name" => "owner", "type" => "reference", "refType" => "member"}
             ]}
          ] do
        {:ok, _} =
          Content.upsert_schema(
            %{"name" => type, "title" => type, "visibility" => "public", "fields" => fields},
            @dataset,
            scope
          )
      end

      for {type, id, content} <- [
            {"member", "m1", %{"name" => "Mia", "email" => "mia@example.com"}},
            {"note", "n1", %{"title" => "Note", "secret" => "s3cret", "owner" => "m1"}}
          ] do
        {:ok, _} =
          Content.create_document(type, %{"doc_id" => id, "content" => content}, @dataset, scope)

        {:ok, _} = Content.publish_document(id, type, @dataset, scope)
      end

      reader = "csm-read-#{System.unique_integer([:positive])}"
      {:ok, _} = Auth.create_token(reader, "csm read", @dataset, ["read"], scope[:workspace_id])
      admin = "csm-admin-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Auth.create_token(admin, "csm admin", @dataset, ["read", "admin"], scope[:workspace_id])

      %{reader: reader, admin: admin}
    end

    @private_queries [
      ~s|*[_id == "n1"][0]{title, secret, owner->{name, email}}|,
      ~s|*[_id == "n1"][0]{..., "who": owner->}|,
      ~s|*[_id == "n1"][0]|,
      ~s|*[_type == "note"]{secret, "e": owner->email}|,
      ~s|*[_id == "m1"][0]{...}|,
      # T2 functions over private fields
      ~s|*[_id == "n1"][0]{"u": upper(secret), "c": coalesce(secret, title), "s": select(defined(secret) => secret, title), "e": owner->{"l": lower(email)}}|
    ]

    test "a reader's map never names a private field, as a path, a mapping or by its value", %{
      reader: reader
    } do
      for q <- @private_queries, mode <- ["true", "withKeyArraySelector"] do
        body = fetch(reader, q, %{"resultSourceMap" => mode})
        dump = Jason.encode!(body)

        refute dump =~ "s3cret" or dump =~ "mia@example.com",
               "#{q}: a private value is in the response"

        map = Jason.encode!(body["resultSourceMap"])
        refute map =~ "secret" or map =~ "email", "#{q} (#{mode}): #{map}"
        # every mapping points at a path the reader can see in the result
        assert Enum.all?(
                 Map.keys(body["resultSourceMap"]["mappings"]),
                 &(not (&1 =~ ~r/secret|email/))
               ),
               q
      end
    end

    # The control: the same queries as an admin do map the private fields, so the test above
    # would see them if they leaked.
    test "an admin's map does name them", %{admin: admin} do
      map =
        Jason.encode!(
          fetch(admin, hd(@private_queries), %{"resultSourceMap" => "true"})["resultSourceMap"]
        )

      assert map =~ "secret" and map =~ "email"
    end
  end
end
