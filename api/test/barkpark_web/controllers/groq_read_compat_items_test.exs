defmodule BarkparkWeb.GroqReadCompatItemsTest do
  @moduledoc """
  task-c2be444ac1d07719, slice 3: GROQ reads an object-array item's `_type`
  as Sanity stores it. Barkpark's single-member `arrayOf` keeps the type in a
  marker field (`kind`, decision 0005) or nowhere (the member's `name`).
  Expected values are Sanity's, read from ecu57yeh/e2e-local on 2026-10-26
  for the same shape (field-types-01: cards[]._type ["card", "card"];
  count(*[_type == 'post' && 'externalLink' in links[]._type]) 3; longform
  rows[0]._type "row"). Nothing stored changes: `kind` still reads as stored.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tenancy}

  @dataset "groq_items_ds"

  setup do
    {:ok, ws} = Tenancy.create_workspace(%{slug: "groq-items", name: "GROQ items"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "site", name: "Site"})
    scope = [workspace_id: ws.id, project_id: proj.id]
    composite = fn extra -> Map.merge(%{"type" => "composite"}, extra) end
    text = fn name -> %{"name" => name, "type" => "string"} end

    links_of =
      composite.(%{
        "options" => %{
          "typeField" => "kind",
          "fieldsByType" => %{"externalLink" => ["title"], "docLink" => ["title"]}
        },
        "fields" => [
          %{
            "name" => "kind",
            "type" => "select",
            "options" => [%{"value" => "externalLink"}, %{"value" => "docLink"}]
          },
          text.("title")
        ]
      })

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [
            text.("title"),
            %{"name" => "links", "type" => "arrayOf", "of" => links_of},
            %{
              "name" => "cards",
              "type" => "arrayOf",
              "of" => composite.(%{"name" => "card", "fields" => [text.("label")]})
            },
            %{
              "name" => "rows",
              "type" => "arrayOf",
              "of" => composite.(%{"fields" => [text.("title")]})
            },
            %{
              "name" => "people",
              "type" => "arrayOf",
              "of" => composite.(%{"fields" => [text.("name")]})
            },
            # The member declares its own `kind`: user data, not a type.
            %{
              "name" => "notes",
              "type" => "arrayOf",
              "of" => composite.(%{"name" => "note", "fields" => [text.("kind"), text.("text")]})
            },
            %{
              "name" => "seo",
              "type" => "composite",
              "fields" => [
                %{
                  "name" => "items",
                  "type" => "arrayOf",
                  "of" => composite.(%{"name" => "item", "fields" => [text.("label")]})
                }
              ]
            },
            %{
              "name" => "secret",
              "type" => "arrayOf",
              "private" => true,
              "of" => composite.(%{"name" => "hush", "fields" => [text.("label")]})
            }
          ]
        },
        @dataset,
        scope
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "page",
          "title" => "Page",
          "visibility" => "public",
          "fields" => [text.("title")]
        },
        @dataset,
        scope
      )

    docs = [
      {"post", "p1",
       %{
         "links" => [
           %{"_key" => "l1", "kind" => "externalLink", "title" => "Ext"},
           %{"_key" => "l2", "kind" => "docLink", "title" => "Doc"}
         ],
         # As imported (kind) and as the studio adds one (no kind).
         "cards" => [
           %{"_key" => "c1", "kind" => "card", "label" => "One"},
           %{"_key" => "c2", "label" => "Two"}
         ],
         "rows" => [%{"_key" => "r1", "kind" => "row", "title" => "R"}],
         "people" => [%{"_key" => "k1", "name" => "Ada"}],
         "notes" => [%{"_key" => "n1", "kind" => "urgent", "text" => "x"}],
         "seo" => %{"items" => [%{"_key" => "i1", "label" => "a"}]}
       }},
      {"post", "p2",
       %{
         "links" => [%{"_key" => "l1", "kind" => "docLink", "title" => "Other"}],
         "cards" => [%{"_key" => "c1", "_type" => "special", "label" => "S"}]
       }},
      {"post", "p3", %{"links" => [], "secret" => [%{"_key" => "s1", "label" => "x"}]}},
      {"post", "p4",
       %{"links" => [%{"_key" => "l1", "_type" => "externalLink", "title" => "Stored"}]}},
      {"page", "g1", %{}}
    ]

    for {type, id, content} <- docs do
      attrs = Map.merge(%{"_id" => id, "title" => id}, content)
      {:ok, _} = Content.create_document(type, attrs, @dataset, scope)
      {:ok, _} = Content.publish_document(id, type, @dataset, scope)
    end

    # A read-only member token: not an admin, so `secret` is redacted for it.
    token = "groq-items-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(token, "items", @dataset, ["read"], ws.id)
    {:ok, token: token}
  end

  defp q(conn, token, query) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> get("/w/groq-items/p/site/v2025-02-19/data/query/#{@dataset}", %{"query" => query})
    |> json_response(200)
    |> Map.fetch!("result")
  end

  test "an item reads _type from its stored _type, its marker, else its member's name", %{
    conn: conn,
    token: t
  } do
    assert q(conn, t, ~s|*[_id == "p1"][0].links[]._type|) == ["externalLink", "docLink"]
    assert q(conn, t, ~s|*[_id == "p1"][0].links[0].kind|) == "externalLink"
    assert q(conn, t, ~s|*[_id == "p1"][0].cards[]._type|) == ["card", "card"]
    assert q(conn, t, ~s|*[_id == "p1"][0].cards[_type == "card"].label|) == ["One", "Two"]
    assert q(conn, t, ~s|*[_id == "p2"][0].cards[0]._type|) == "special"
    assert q(conn, t, ~s|*[_id == "p1"][0].rows[0]._type|) == "row"
    assert q(conn, t, ~s|*[_id == "p1"][0].people[0]._type|) == nil
    assert q(conn, t, ~s|*[_id == "p1"][0].seo.items[0]._type|) == "item"
    # A member's own `kind` field is data: the type is the member's name.
    assert q(conn, t, ~s|*[_id == "p1"][0].notes[0]{_type, kind}|) == %{
             "_type" => "note",
             "kind" => "urgent"
           }
  end

  test "filters on an item's _type match what the read says, in SQL", %{conn: conn, token: t} do
    assert q(conn, t, ~s|count(*[_type == "post" && "externalLink" in links[]._type])|) == 2
    assert q(conn, t, ~s|count(*["externalLink" in links[]._type])|) == 2

    assert q(
             conn,
             t,
             ~s|*[_type == "post" && count(links[_type == "docLink"]) > 0] \| order(_id)._id|
           ) ==
             ["p1", "p2"]

    assert q(
             conn,
             t,
             ~s|count(*[_type == "post" && count(links[_type == "docLink" && title == "Doc"]) > 0])|
           ) ==
             1

    assert q(conn, t, ~s|*[_type == "post" && count(cards[_type == "card"]) > 0]._id|) == ["p1"]

    assert q(conn, t, ~s|*[_type == "post" && defined(cards[_type == "special"][0])]._id|) == [
             "p2"
           ]

    assert q(conn, t, ~s|*[!(count(links[_type == "docLink"]) > 0)] \| order(_id)._id|) == [
             "p3",
             "p4"
           ]

    assert q(conn, t, ~s|count(*[_type == "post" && "note" in notes[]._type])|) == 1
    assert q(conn, t, ~s|count(*[_type == "post" && "urgent" in notes[]._type])|) == 0
  end

  test "a private array's items never answer a filter or a read", %{conn: conn, token: t} do
    assert q(conn, t, ~s|count(*[_type == "post" && "hush" in secret[]._type])|) == 0
    assert q(conn, t, ~s|*[_id == "p3"][0].secret|) == nil
  end

  test "each filter form answers from SQL past the per-fetch limit", %{conn: conn, token: t} do
    previous = Application.get_env(:barkpark, Barkpark.Groq, [])

    Application.put_env(:barkpark, Barkpark.Groq,
      max_documents_per_fetch: 2,
      max_documents_loaded: 2
    )

    on_exit(fn -> Application.put_env(:barkpark, Barkpark.Groq, previous) end)

    assert q(conn, t, ~s|*[_type == "post" && "externalLink" in links[]._type] \| order(_id)._id|) ==
             ["p1", "p4"]

    assert q(
             conn,
             t,
             ~s|*[_type == "post" && count(links[_type == "docLink"]) > 0] \| order(_id)._id|
           ) ==
             ["p1", "p2"]

    assert q(conn, t, ~s|count(*[_type == "post" && defined(cards[_type == "card"][0])])|) == 1

    assert q(
             conn,
             t,
             ~s|*[_type == "post" && !(count(links[_type == "docLink"]) > 0)] \| order(_id)._id|
           ) ==
             ["p3", "p4"]
  end

  # The member-name term (`!exists _type && !exists kind`) is one no index
  # serves: a typeless filter must still read only the declaring types' rows,
  # never the whole dataset (run-perf on #24093: 41-60 ms through the dataset
  # index before the branch carried `type IN`).
  test "a typeless member-name filter reads only the declaring types", %{conn: conn, token: t} do
    test_pid = self()
    handler = "groq-items-sql-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:barkpark, :repo, :query],
      fn _event, _measurements, meta, _cfg -> send(test_pid, {:sql, meta.params}) end,
      nil
    )

    try do
      assert q(conn, t, ~s|count(*["card" in cards[]._type])|) == 1
    after
      :telemetry.detach(handler)
    end

    params = drain_params([])

    typed =
      Enum.filter(params, fn ps -> Enum.any?(ps, &(is_binary(&1) and &1 =~ "keyvalue()")) end)

    # The branch's exact test carries `type IN ["post"]`; its index
    # narrowing must carry it too, or the planner reads the dataset.
    assert typed != []
    assert Enum.all?(typed, fn ps -> Enum.count(ps, &(&1 == ["post"])) >= 2 end)
  end

  defp drain_params(acc) do
    receive do
      {:sql, params} -> drain_params([params | acc])
    after
      0 -> acc
    end
  end
end
