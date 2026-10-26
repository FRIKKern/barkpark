defmodule BarkparkWeb.GroqControllerTest do
  @moduledoc """
  `GET|POST /w/:ws/p/:proj/v{apiVersion}/data/query/:dataset`, the
  Sanity-compatible GROQ read: response shape, parameters, perspectives,
  tenancy, batching, sync tags and limits. Fixtures are synthetic.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.{Auth, Content, Tenancy}

  @dataset "groq_ds"
  @version "v2025-02-19"

  setup do
    {:ok, ws} = Tenancy.create_workspace(%{slug: "groq-ws-a", name: "GROQ A"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "site", name: "Site"})
    {:ok, ws_b} = Tenancy.create_workspace(%{slug: "groq-ws-b", name: "GROQ B"})
    {:ok, proj_b} = Tenancy.create_project(ws_b, %{slug: "site", name: "Site"})

    scope = [workspace_id: ws.id, project_id: proj.id]
    scope_b = [workspace_id: ws_b.id, project_id: proj_b.id]

    for type <- ["author", "book", "genre"] do
      {:ok, _} =
        Content.upsert_schema(
          %{"name" => type, "title" => type, "visibility" => "public", "fields" => []},
          @dataset,
          scope
        )

      {:ok, _} =
        Content.upsert_schema(
          %{"name" => type, "title" => type, "visibility" => "public", "fields" => []},
          @dataset,
          scope_b
        )
    end

    publish!("author", %{"_id" => "ada", "name" => "Ada", "slug" => %{"current" => "ada"}}, scope)
    publish!("author", %{"_id" => "bo", "name" => "Bo", "slug" => %{"current" => "bo"}}, scope)
    publish!("genre", %{"_id" => "poetry", "name" => "Poetry"}, scope)

    publish!(
      "book",
      %{
        "_id" => "b1",
        "name" => "First",
        "year" => 1999,
        "author" => ref("ada"),
        "genres" => [Map.put(ref("poetry"), "_key", "k1")]
      },
      scope
    )

    publish!(
      "book",
      %{"_id" => "b2", "name" => "Second", "year" => 2005, "author" => ref("ada")},
      scope
    )

    publish!(
      "book",
      %{"_id" => "b3", "name" => "Third", "year" => 2010, "author" => ref("bo")},
      scope
    )

    # The same id in workspace B: a scoped read in A must never see it.
    publish!("book", %{"_id" => "b1", "name" => "Other tenant", "year" => 1}, scope_b)

    token = "groq-a-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(token, "groq A", @dataset, ["read", "write"], ws.id)

    {:ok, token: token, scope: scope}
  end

  defp ref(id), do: %{"_type" => "reference", "_ref" => id}

  defp publish!(type, attrs, scope) do
    {:ok, _} = Content.create_document(type, attrs, @dataset, scope)
    {:ok, _} = Content.publish_document(attrs["_id"], type, @dataset, scope)
  end

  defp path(ws \\ "groq-ws-a"), do: "/w/#{ws}/p/site/#{@version}/data/query/#{@dataset}"

  defp get_query(conn, token, query, extra \\ %{}) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> get(path(), Map.merge(%{"query" => query}, extra))
  end

  test "answers Sanity's response shape: query, result, ms, syncTags", %{conn: conn, token: token} do
    body =
      conn
      |> get_query(token, ~s'*[_type == "book"] | order(year asc) {name, year}')
      |> json_response(200)

    assert body["query"] == ~s'*[_type == "book"] | order(year asc) {name, year}'
    assert is_integer(body["ms"])

    assert body["result"] == [
             %{"name" => "First", "year" => 1999},
             %{"name" => "Second", "year" => 2005},
             %{"name" => "Third", "year" => 2010}
           ]

    assert "bp:ds:#{@dataset}:type:book" in body["syncTags"]
  end

  test "documents carry the Sanity system fields and no Barkpark envelope keys", %{
    conn: conn,
    token: token
  } do
    %{"result" => doc} = conn |> get_query(token, ~s'*[_id == "b1"][0]') |> json_response(200)

    assert doc["_id"] == "b1"
    assert doc["_type"] == "book"
    assert is_binary(doc["_rev"])
    assert is_binary(doc["_createdAt"]) and is_binary(doc["_updatedAt"])
    assert doc["name"] == "First"
    refute Map.has_key?(doc, "_draft")
    refute Map.has_key?(doc, "_publishedId")
  end

  test "$params, dereference, ^ subqueries, count, coalesce, defined, select and slices", %{
    conn: conn,
    token: token
  } do
    query = """
    *[_type == "author" && slug.current == $slug][0]{
      name,
      "books": *[_type == "book" && references(^._id)] | order(year desc) [0...2] {
        name,
        "by": author->name,
        "genres": genres[]->name,
        "era": select(year < 2000 => "old", "new")
      },
      "bookCount": count(*[_type == "book" && author._ref == ^._id]),
      "nick": coalesce(nickname, name),
      "hasNick": defined(nickname)
    }
    """

    body = conn |> get_query(token, query, %{"$slug" => ~s'"ada"'}) |> json_response(200)

    assert body["result"] == %{
             "name" => "Ada",
             "books" => [
               %{"name" => "Second", "by" => "Ada", "genres" => nil, "era" => "new"},
               %{"name" => "First", "by" => "Ada", "genres" => ["Poetry"], "era" => "old"}
             ],
             "bookCount" => 2,
             "nick" => "Ada",
             "hasNick" => false
           }
  end

  test "in-lists and an || of field equalities filter through SQL", %{conn: conn, token: token} do
    body =
      conn
      |> get_query(token, ~s'*[_type == "book" && year in $years] | order(year asc).name', %{
        "$years" => "[1999, 2010]"
      })
      |> json_response(200)

    assert body["result"] == ["First", "Third"]

    body =
      scoped_conn()
      |> get_query(
        token,
        ~s'*[_type == "book" && (name == $n || year == $y)] | order(year asc).name',
        %{
          "$n" => ~s("Second"),
          "$y" => "1999"
        }
      )
      |> json_response(200)

    assert body["result"] == ["First", "Second"]
  end

  test "POST takes the query and params in the body", %{conn: conn, token: token} do
    body =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")
      |> post(path(), Jason.encode!(%{query: "*[_type == $t]._id", params: %{t: "genre"}}))
      |> json_response(200)

    assert body["result"] == ["poetry"]
  end

  test "returnQuery=false leaves the query out", %{conn: conn, token: token} do
    body = conn |> get_query(token, "count(*)", %{"returnQuery" => "false"}) |> json_response(200)
    refute Map.has_key?(body, "query")
    assert body["result"] == 6
  end

  test "reads stay inside the URL's workspace", %{conn: conn, token: token} do
    %{"result" => names} = conn |> get_query(token, ~s'*[_id == "b1"].name') |> json_response(200)
    assert names == ["First"]

    conn =
      scoped_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> get(path("groq-ws-b"), %{"query" => "*"})

    assert conn.status in [403, 404]
  end

  test "the drafts perspective overlays drafts and sets _originalId", %{
    conn: conn,
    token: token,
    scope: scope
  } do
    {:ok, _} =
      Content.create_document(
        "book",
        %{"_id" => "b3", "name" => "Third (edited)", "year" => 2010},
        @dataset,
        scope
      )

    published = conn |> get_query(token, ~s'*[_id == "b3"][0]{_id, name}') |> json_response(200)
    assert published["result"] == %{"_id" => "b3", "name" => "Third"}

    drafts =
      scoped_conn()
      |> get_query(token, ~s'*[_id == "b3"][0]{_id, _originalId, name}', %{
        "perspective" => "drafts"
      })
      |> json_response(200)

    assert drafts["result"] == %{
             "_id" => "b3",
             "_originalId" => "drafts.b3",
             "name" => "Third (edited)"
           }

    raw =
      scoped_conn()
      |> get_query(token, ~s'*[_type == "book"]._id', %{"perspective" => "raw"})
      |> json_response(200)

    assert "drafts.b3" in raw["result"]
  end

  test "a syntax error is a 400 Sanity's client can format", %{conn: conn, token: token} do
    body = conn |> get_query(token, "*[_type == ") |> json_response(400)
    error = body["error"]
    assert error["code"] == "malformed"
    assert error["type"] == "queryParseError"
    assert is_binary(error["description"])
    assert is_integer(error["start"]) and is_integer(error["end"])
    assert error["query"] == "*[_type == "
    # A query's hint, not `malformed`'s JSON-body one (task-b85cf70ca346260a).
    assert error["hint"] =~ "GROQ query"
    refute error["hint"] =~ "Content-Type"
  end

  # Barkpark writes a reference as the plain id string (post.author = "author-alan"):
  # `->` follows it as it follows `{_ref}`, single or in an array, and a string that
  # names no document reads null (task-b85cf70ca346260a).
  test "-> follows a plain id string as well as {_ref}", %{conn: conn, token: token, scope: scope} do
    publish!(
      "book",
      %{
        "_id" => "b4",
        "name" => "Fourth",
        "year" => 2020,
        "author" => "bo",
        "genres" => ["poetry", "nope"],
        "note" => "no-such-doc"
      },
      scope
    )

    body =
      conn
      |> get_query(
        token,
        ~s'*[_id == "b4"][0]{"by": author->name, "genres": genres[]->name, "note": note->name, "ref": *[_id == "b1"][0].author->name}'
      )
      |> json_response(200)

    assert body["result"] == %{
             "by" => "Bo",
             "genres" => ["Poetry", nil],
             "note" => nil,
             "ref" => "Ada"
           }
  end

  test "a parameter the query uses but the request lacks is a 400", %{conn: conn, token: token} do
    body = conn |> get_query(token, "*[_id == $id]") |> json_response(400)
    assert body["error"]["description"] =~ "$id"
  end

  test "a parameter that is not JSON is a 400", %{conn: conn, token: token} do
    body = conn |> get_query(token, "*[_id == $id]", %{"$id" => "not json"}) |> json_response(400)
    assert body["error"]["code"] == "malformed"
  end

  test "an unknown perspective is a 400", %{conn: conn, token: token} do
    assert conn |> get_query(token, "1", %{"perspective" => "bogus"}) |> json_response(400)
  end

  test "dereferences are batched: the SQL count does not grow with the result", %{
    token: token,
    scope: scope
  } do
    small =
      count_repo_queries(fn ->
        scoped_conn() |> get_query(token, ~s'*[_type == "book"]{"a": author->name}')
      end)

    for i <- 1..25 do
      publish!("author", %{"_id" => "extra-a#{i}", "name" => "A#{i}"}, scope)

      publish!(
        "book",
        %{"_id" => "extra-b#{i}", "name" => "B#{i}", "author" => ref("extra-a#{i}")},
        scope
      )
    end

    large =
      count_repo_queries(fn ->
        scoped_conn() |> get_query(token, ~s'*[_type == "book"]{"a": author->name}')
      end)

    assert large == small
  end

  test "sync tags name scanned types and documents read by id", %{conn: conn, token: token} do
    body =
      conn |> get_query(token, ~s'*[_id == "b1"][0]{"a": author->name}') |> json_response(200)

    assert Enum.sort(body["syncTags"]) ==
             Enum.sort(["bp:ds:#{@dataset}:doc:b1", "bp:ds:#{@dataset}:doc:ada"])
  end

  test "a query that would load too many documents is refused with 422", %{
    conn: conn,
    token: token
  } do
    previous = Application.get_env(:barkpark, Barkpark.Groq, [])
    Application.put_env(:barkpark, Barkpark.Groq, max_documents_per_fetch: 2)
    on_exit(fn -> Application.put_env(:barkpark, Barkpark.Groq, previous) end)

    body = conn |> get_query(token, ~s'*[_type == "book"]') |> json_response(422)
    assert body["error"]["type"] == "queryLimitError"
    # It names the cap and how to page, not a _type filter the query already has.
    assert body["error"]["description"] =~ "more than 2 documents"
    assert body["error"]["description"] =~ "[0...2], then [2...4]"
    refute body["error"]["description"] =~ "_type filter"

    # And the advice works: the slice it names is answered.
    paged =
      conn |> get_query(token, ~s'*[_type == "book"] | order(_id) [0...2]') |> json_response(200)

    assert length(paged["result"]) <= 2
  end

  # task-2a7741b89420a38a: a _createdAt comparison is answered in SQL, so it
  # narrows the read before the cap instead of loading every document of the
  # type, and it keeps exactly the documents GROQ's string comparison keeps.
  test "a _createdAt comparison narrows in SQL and matches GROQ's string comparison", %{
    conn: conn,
    token: token
  } do
    all =
      conn
      |> get_query(token, ~s'*[_type == "book"] | order(_createdAt asc) {_id, _createdAt}')
      |> json_response(200)

    stamps = Enum.map(all["result"], & &1["_createdAt"])

    assert length(stamps) >= 3 and
             Enum.all?(stamps, &(&1 =~ ~r/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z$/))

    newest = List.last(stamps)

    expected = fn op ->
      all["result"]
      |> Enum.filter(&apply(Kernel, op, [&1["_createdAt"], newest]))
      |> Enum.map(& &1["_id"])
      |> Enum.sort()
    end

    previous = Application.get_env(:barkpark, Barkpark.Groq, [])
    Application.put_env(:barkpark, Barkpark.Groq, max_documents_per_fetch: 2)
    on_exit(fn -> Application.put_env(:barkpark, Barkpark.Groq, previous) end)

    # The whole type is over the cap, so only the pushed-down filter can answer.
    assert conn |> get_query(token, ~s'*[_type == "book"]') |> json_response(422)

    for {groq, op} <- [{">=", :>=}, {"==", :==}, {">", :>}] do
      body =
        conn
        |> get_query(token, ~s'*[_type == "book" && _createdAt #{groq} $t]{_id}', %{
          "$t" => Jason.encode!(newest)
        })
        |> json_response(200)

      assert body["result"] |> Enum.map(& &1["_id"]) |> Enum.sort() == expected.(op), groq
    end
  end

  # task-2a7741b89420a38a: a projection of system fields only reads no stored
  # content, so the per-*[...] document cap gives way to the per-query load cap.
  test "*[...]._id answers past the per-*[...] cap; a content field does not", %{
    conn: conn,
    token: token
  } do
    all = conn |> get_query(token, ~s'*[_type == "book"]._id') |> json_response(200)
    assert length(all["result"]) >= 3

    previous = Application.get_env(:barkpark, Barkpark.Groq, [])
    Application.put_env(:barkpark, Barkpark.Groq, max_documents_per_fetch: 2)
    on_exit(fn -> Application.put_env(:barkpark, Barkpark.Groq, previous) end)

    ids = conn |> get_query(token, ~s'*[_type == "book"]._id') |> json_response(200)
    assert Enum.sort(ids["result"]) == Enum.sort(all["result"])

    projected =
      conn |> get_query(token, ~s'*[_type == "book"]{_id, _createdAt}') |> json_response(200)

    assert length(projected["result"]) == length(all["result"])

    assert conn |> get_query(token, ~s'*[_type == "book"].name') |> json_response(422)
  end

  # task-606142ef89bee14d: coalesce(a, b) in L pushes down as
  # a in L || (!defined(a) && b in L), so it narrows in SQL below the cap and
  # keeps GROQ's meaning: b is read only where a is missing or null.
  test "coalesce(a, b) in $list narrows in SQL and keeps coalesce's meaning", %{
    conn: conn,
    token: token
  } do
    books = conn |> get_query(token, ~s'*[_type == "book"]{_id, name}') |> json_response(200)
    [first | _] = Enum.sort_by(books["result"], & &1["_id"])

    previous = Application.get_env(:barkpark, Barkpark.Groq, [])
    Application.put_env(:barkpark, Barkpark.Groq, max_documents_per_fetch: 2)
    on_exit(fn -> Application.put_env(:barkpark, Barkpark.Groq, previous) end)

    query = fn groq, list ->
      conn
      |> get_query(token, groq, %{"$l" => Jason.encode!(list)})
      |> json_response(200)
      |> Map.fetch!("result")
    end

    # No book has a subtitle, so coalesce falls through to name.
    assert query.(~s'*[_type == "book" && coalesce(subtitle, name) in $l]._id', [first["name"]]) ==
             [first["_id"]]

    # Every book has a name, so _id is never consulted: nothing matches, where
    # `name in $l || _id in $l` would match the first book.
    assert query.(~s'*[_type == "book" && coalesce(name, _id) in $l]._id', [first["_id"]]) == []
  end

  # task-754316ae85c63a1a: gyldendal.no's draft-mode poller timed out
  # reading every document of the dataset. `_id in path()` narrows in SQL, and
  # with no stored field read the ordered slice is SQL's too, type or not.
  test "_id in path(\"drafts.**\") narrows in SQL", %{conn: conn, token: token, scope: scope} do
    for id <- ["b1", "b3"] do
      {:ok, _} = Content.create_document("book", %{"_id" => id, "name" => id}, @dataset, scope)
    end

    raw = %{"perspective" => "raw"}

    drafts =
      conn
      |> get_query(
        token,
        ~s'*[_id in path("drafts.**")] | order(_updatedAt desc){_id, _updatedAt}',
        raw
      )
      |> json_response(200)

    assert drafts["result"] |> Enum.map(& &1["_id"]) |> Enum.sort() == ["drafts.b1", "drafts.b3"]
    [newest | _] = drafts["result"]

    {poll, statements} =
      sql_statements(fn ->
        scoped_conn()
        |> get_query(
          token,
          ~s'*[_id in path("drafts.**")] | order(_updatedAt desc)[0]._updatedAt',
          raw
        )
        |> json_response(200)
      end)

    assert poll["result"] == newest["_updatedAt"]
    # The newest draft is one sorted, limited read, not every draft loaded.
    assert Enum.any?(
             statements,
             &(&1 =~ ~r/"doc_id" ~ \$.* ORDER BY .*"updated_at" DESC.* LIMIT/)
           )

    count = scoped_conn() |> get_query(token, ~s'count(*[_id in path("drafts.*")])', raw)
    assert json_response(count, 200)["result"] == 2

    assert scoped_conn()
           |> get_query(token, ~s'count(*[_id in path("*")])', raw)
           |> json_response(200)
  end

  test "a query that would load too much stored content is refused before loading", %{
    conn: conn,
    token: token
  } do
    previous = Application.get_env(:barkpark, Barkpark.Groq, [])
    Application.put_env(:barkpark, Barkpark.Groq, max_bytes_per_fetch: 1)
    on_exit(fn -> Application.put_env(:barkpark, Barkpark.Groq, previous) end)

    body = conn |> get_query(token, ~s'*[_type == "book"]') |> json_response(422)
    assert body["error"]["description"] =~ "stored content"
  end

  test "a ^ subquery inside a projection is one read per round, however many parents", %{
    token: token,
    scope: scope
  } do
    query =
      ~s'*[_type == "author"]{name, "books": *[_type == "book" && author._ref == ^._id].name}'

    small = count_repo_queries(fn -> scoped_conn() |> get_query(token, query) end)

    for i <- 1..20 do
      publish!("author", %{"_id" => "more-a#{i}", "name" => "M#{i}"}, scope)

      publish!(
        "book",
        %{"_id" => "more-b#{i}", "name" => "N#{i}", "author" => ref("more-a#{i}")},
        scope
      )
    end

    large = count_repo_queries(fn -> scoped_conn() |> get_query(token, query) end)
    assert large == small
  end

  test "an unsupported function is a 422 naming it", %{conn: conn, token: token} do
    body = conn |> get_query(token, ~s'geo::distance(1, 2)') |> json_response(422)
    assert body["error"]["description"] =~ "geo::distance"
  end

  describe "title, which the writer keeps in the documents.title column" do
    setup %{scope: scope} do
      publish!("genre", %{"_id" => "g-novel", "title" => "Novels"}, scope)

      publish!(
        "book",
        %{
          "_id" => "t1",
          "title" => "Peppa's Christmas",
          "genre" => ref("g-novel"),
          "genres" => [Map.put(ref("g-novel"), "_key", "k1")]
        },
        scope
      )

      # Written through the content-present branch: the column stays blank and
      # the envelope emits content.title.
      publish!(
        "book",
        %{"_id" => "t2", "content" => %{"title" => "Only in content", "genre" => ref("g-novel")}},
        scope
      )

      :ok
    end

    test "a top-level document carries the title the envelope renders", %{
      conn: conn,
      token: token,
      scope: scope
    } do
      %{"result" => doc} = conn |> get_query(token, ~s'*[_id == "t1"][0]') |> json_response(200)

      stored = Content.get_document("t1", "book", @dataset, scope)
      assert {:ok, %{title: "Peppa's Christmas"} = row} = stored
      assert doc["title"] == Barkpark.Content.Envelope.render(row)["title"]
      assert doc["title"] == "Peppa's Christmas"
    end

    test "projections, dereferences and ^ subqueries carry title", %{conn: conn, token: token} do
      query = """
      *[_id == "g-novel"][0]{
        title,
        "books": *[_type == "book" && references(^._id)] | order(_id asc) {
          title,
          "genre": genre->title,
          "genreDoc": genre->{title},
          "genres": genres[]->title
        }
      }
      """

      %{"result" => result} = conn |> get_query(token, query) |> json_response(200)

      assert result == %{
               "title" => "Novels",
               "books" => [
                 %{
                   "title" => "Peppa's Christmas",
                   "genre" => "Novels",
                   "genreDoc" => %{"title" => "Novels"},
                   "genres" => ["Novels"]
                 },
                 %{
                   "title" => "Only in content",
                   "genre" => "Novels",
                   "genreDoc" => %{"title" => "Novels"},
                   "genres" => nil
                 }
               ]
             }
    end

    test "an equality on title matches the column and the content fallback", %{
      conn: conn,
      token: token
    } do
      for {title, id} <- [{"Peppa's Christmas", "t1"}, {"Only in content", "t2"}] do
        %{"result" => ids} =
          conn
          |> get_query(token, ~s'*[_type == "book" && title == $t]._id', %{
            "$t" => Jason.encode!(title)
          })
          |> json_response(200)

        assert ids == [id]
      end

      {:ok, {:filter, {:everything}, filter}} = Barkpark.Groq.Parser.parse(~s'*[title == "x"]')
      assert Barkpark.Groq.Pushdown.constraints(filter).eq == [{["title"], "x"}]
    end

    test "a document written without a title has no title key", %{conn: conn, token: token} do
      %{"result" => doc} = conn |> get_query(token, ~s'*[_id == "b1"][0]') |> json_response(200)
      refute Map.has_key?(doc, "title")
    end
  end

  describe "count(*[...]) on a type with one hidden field" do
    # `record` hides `secret` and `meta.note` from a caller without admin.
    # Four records: r1 and r2 hold secret "x"; r1, r2 and r3 have kind "a".
    setup %{scope: scope} do
      fields = [
        %{"name" => "kind", "type" => "string"},
        %{"name" => "secret", "type" => "string", "private" => true},
        %{"name" => "tags", "type" => "array", "of" => [%{"type" => "string"}]},
        %{
          "name" => "meta",
          "type" => "object",
          "fields" => [
            %{"name" => "kind", "type" => "string"},
            %{"name" => "note", "type" => "string", "private" => true}
          ]
        }
      ]

      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => "record",
            "title" => "record",
            "visibility" => "public",
            "fields" => fields
          },
          @dataset,
          scope
        )

      for {id, kind, secret, tags} <- [
            {"r1", "a", "x", ["t"]},
            {"r2", "a", "x", []},
            {"r3", "a", "y", ["t", "u"]},
            {"r4", "b", "y", []}
          ] do
        publish!(
          "record",
          %{
            "_id" => id,
            "kind" => kind,
            "secret" => secret,
            "tags" => tags,
            "meta" => %{"kind" => kind, "note" => secret}
          },
          scope
        )
      end

      admin = "groq-admin-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Auth.create_token(admin, "groq admin", @dataset, ["read", "admin"], scope[:workspace_id])

      {:ok, admin: admin}
    end

    defp count_query(token, query, sql_count?) do
      {body, sql} =
        sql_statements(fn ->
          scoped_conn() |> get_query(token, query) |> json_response(200)
        end)

      counted_in_sql = Enum.any?(sql, &(&1 =~ ~r/SELECT .*count\(d\d\."id"\)/i))
      assert counted_in_sql == sql_count?, "#{query}: SQL count #{counted_in_sql}"
      body["result"]
    end

    test "a filter on another field counts in SQL", %{token: token} do
      assert count_query(token, ~s'count(*[_type == "record" && kind == "a"])', true) == 3
      assert count_query(token, ~s'count(*[_type == "record" && meta.kind == "a"])', true) == 3
      assert count_query(token, ~s'count(*[_type == "record" && count(tags) > 0])', true) == 2
      assert count_query(token, ~s'count(*[_type == "record" && defined(tags[1])])', true) == 1
    end

    test "a filter on the hidden field is not a SQL count and equals the in-memory evaluation",
         %{token: token} do
      for filter <- [
            ~s'_type == "record" && secret == "x"',
            ~s'_type == "record" && kind == "a" && secret == "x"',
            ~s'_type == "record" && meta.note == "x"',
            ~s'_type == "record" && defined(secret)',
            ~s'_type == "record" && defined(meta.note)'
          ] do
        counted = count_query(token, "count(*[#{filter}])", false)
        # `[0...100000]` makes the count read the loaded, rendered documents.
        loaded = count_query(token, "count(*[#{filter}][0...100000])", false)

        assert counted == loaded, "#{filter}: #{counted} != #{loaded}"
        assert counted == 0, filter
      end
    end

    test "a read that SQL filters alone still hides the hidden fields",
         %{token: token, admin: admin} do
      read = fn tok, q ->
        scoped_conn() |> get_query(tok, q) |> json_response(200) |> Map.fetch!("result")
      end

      filter = ~s'_type == "record" && kind == "a"'

      assert read.(token, "*[#{filter}]{_id, kind, secret, meta}") == [
               %{"_id" => "r1", "kind" => "a", "secret" => nil, "meta" => %{"kind" => "a"}},
               %{"_id" => "r2", "kind" => "a", "secret" => nil, "meta" => %{"kind" => "a"}},
               %{"_id" => "r3", "kind" => "a", "secret" => nil, "meta" => %{"kind" => "a"}}
             ]

      assert read.(token, "*[#{filter}].secret") == [nil, nil, nil]
      assert read.(token, "*[#{filter}].meta") == List.duplicate(%{"kind" => "a"}, 3)
      assert Enum.all?(read.(token, "*[#{filter}]"), &(not Map.has_key?(&1, "secret")))

      assert read.(admin, "*[#{filter}].secret") == ["x", "x", "y"]

      assert read.(admin, "*[#{filter}]{_id, meta}") |> Enum.map(& &1["meta"]["note"]) == [
               "x",
               "x",
               "y"
             ]
    end

    test "a caller that sees every field counts the hidden field in SQL", %{admin: admin} do
      assert count_query(admin, ~s'count(*[_type == "record" && secret == "x"])', true) == 2
      assert count_query(admin, ~s'count(*[_type == "record" && meta.note == "x"])', true) == 2
      assert count_query(admin, ~s'count(*[_type == "record" && kind == "a"])', true) == 3
    end
  end

  describe "a type with an encrypted field" do
    # `vault` encrypts `secret`. v1 holds one and v2 does not. Render drops the
    # ciphertext for a caller without admin, so to that caller neither holds
    # `secret`, while the stored content of v1 does.
    setup %{scope: scope} do
      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => "vault",
            "title" => "vault",
            "visibility" => "public",
            "fields" => [
              %{"name" => "kind", "type" => "string"},
              %{"name" => "secret", "type" => "string", "encrypted" => true}
            ]
          },
          @dataset,
          scope
        )

      publish!("vault", %{"_id" => "v1", "kind" => "a", "secret" => "x"}, scope)
      publish!("vault", %{"_id" => "v2", "kind" => "a"}, scope)

      admin = "groq-admin-#{System.unique_integer([:positive])}"

      {:ok, _} =
        Auth.create_token(admin, "groq admin", @dataset, ["read", "admin"], scope[:workspace_id])

      {:ok, admin: admin}
    end

    test "a filter on it matches what the caller reads, in count() and in a read",
         %{token: token, admin: admin} do
      read = fn tok, q ->
        scoped_conn() |> get_query(tok, q) |> json_response(200) |> Map.fetch!("result")
      end

      assert read.(token, ~s'*[_type == "vault"]{_id, secret}') == [
               %{"_id" => "v1", "secret" => nil},
               %{"_id" => "v2", "secret" => nil}
             ]

      assert read.(token, ~s'count(*[_type == "vault" && defined(secret)])') == 0
      assert read.(token, ~s'*[_type == "vault" && defined(secret)]._id') == []

      assert read.(admin, ~s'count(*[_type == "vault" && defined(secret)])') == 1
      assert read.(admin, ~s'*[_type == "vault" && defined(secret)]._id') == ["v1"]
    end
  end

  test "references() leads the read when the filter also has a common equality", %{
    conn: conn,
    token: token
  } do
    query =
      ~s'*[_type == "book" && !(_id in path("drafts.**")) && defined(year) && year == 1999 && references($a)]._id'

    {body, statements} =
      sql_statements(fn ->
        conn |> get_query(token, query, %{"$a" => ~s'"ada"'}) |> json_response(200)
      end)

    assert body["result"] == ["b1"]
    # gyl's series page: the path index guessed 6 rows for `isMainProduct ==
    # true` and found 11,257, so the planner chose it over the refs index.
    refute Enum.any?(statements, &(&1 =~ "@? CAST"))
    assert Enum.any?(statements, &(&1 =~ "jsonb_path_query_array(d0.\"content\""))
  end

  test "a count of \"x\" in a[].b per parent is a SQL count", %{
    conn: conn,
    token: token,
    scope: scope
  } do
    publish!("book", %{"_id" => "m1", "genres" => [ref("poetry"), ref("prose")]}, scope)
    publish!("book", %{"_id" => "m2", "genres" => ref("poetry")}, scope)
    publish!("book", %{"_id" => "m3", "genres" => [%{"_ref" => ["poetry"]}]}, scope)
    publish!("book", %{"_id" => "m4", "genres" => [%{"name" => "x"}, ref("poetry")]}, scope)

    {body, statements} =
      sql_statements(fn ->
        conn
        |> get_query(
          token,
          ~s'*[_type == "genre"]{_id, "n": count(*[_type == "book" && ^._id in genres[]._ref])}'
        )
        |> json_response(200)
      end)

    # b1, m1 and m4 hold poetry in an element's _ref; an object genres (m2)
    # and an array _ref (m3) do not.
    assert body["result"] == [%{"_id" => "poetry", "n" => 3}]
    assert Enum.any?(statements, &(&1 =~ ~s'count(d0."id")'))
    refute Enum.any?(statements, &(&1 =~ ~r/SELECT d0."id", d0."doc_id".*LIMIT 500/))
  end

  test "a query over the slot cap waits, then answers 503 with Retry-After", %{
    conn: conn,
    token: token
  } do
    previous = Application.get_env(:barkpark, Barkpark.Groq, [])
    Application.put_env(:barkpark, Barkpark.Groq, max_concurrent: 1, queue_ms: 100)
    on_exit(fn -> Application.put_env(:barkpark, Barkpark.Groq, previous) end)

    test_pid = self()

    holder =
      spawn(fn ->
        :ok = Barkpark.Groq.Slots.acquire()
        send(test_pid, :held)
        Process.sleep(:infinity)
      end)

    assert_receive :held

    busy = conn |> get_query(token, ~s'count(*[_type == "book"])')
    assert busy.status == 503
    assert get_resp_header(busy, "retry-after") == ["1"]
    assert json_response(busy, 503)["error"]["type"] == "queryBusyError"

    # A holder that dies without releasing frees its slot.
    Process.exit(holder, :kill)

    assert scoped_conn() |> get_query(token, ~s'count(*[_type == "book"])') |> json_response(200)
    assert Barkpark.Groq.Slots.held() == 0
  end

  test "the default slot cap fits half the memory in query heaps, two per scheduler at most" do
    heap = 512 * 1024 * 1024
    # gyl: 3.8 GB, 2 cores -> 3 heaps fit in half the memory.
    assert Barkpark.Groq.Slots.default_limit(3_907_408 * 1024, heap) ==
             min(3, 2 * System.schedulers_online())

    assert Barkpark.Groq.Slots.default_limit(256 * 1024 * 1024, heap) == 1
    assert Barkpark.Groq.Slots.default_limit(nil, heap) == min(4, 2 * System.schedulers_online())
  end

  defp sql_statements(fun) do
    ref = make_ref()
    parent = self()
    handler = "groq-sql-#{inspect(ref)}"

    :telemetry.attach(
      handler,
      [:barkpark, :repo, :query],
      fn _, _, meta, _ -> send(parent, {ref, meta.query}) end,
      nil
    )

    result =
      try do
        fun.()
      after
        :telemetry.detach(handler)
      end

    {result, collect_statements(ref, [])}
  end

  defp collect_statements(ref, acc) do
    receive do
      {^ref, q} -> collect_statements(ref, [q | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp count_repo_queries(fun) do
    ref = make_ref()
    parent = self()
    handler = "groq-count-#{inspect(ref)}"

    :telemetry.attach(
      handler,
      [:barkpark, :repo, :query],
      fn _, _, _, _ -> send(parent, {ref, :q}) end,
      nil
    )

    try do
      conn = fun.()
      assert conn.status == 200
    after
      :telemetry.detach(handler)
    end

    count_messages(ref, 0)
  end

  defp count_messages(ref, n) do
    receive do
      {^ref, :q} -> count_messages(ref, n + 1)
    after
      0 -> n
    end
  end
end
