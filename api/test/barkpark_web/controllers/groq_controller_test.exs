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
