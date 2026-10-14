defmodule BarkparkWeb.ViewsControllerTest do
  @moduledoc """
  Document view counts over HTTP (task-5feac4e826cff9a5): the write endpoint
  `POST /w/:ws/p/:proj/v1/data/views/:dataset`, its access and rate limit,
  and the reads that use the counts: GROQ `_views7d` / `_views30d` /
  `_popularity`, the query API `order=popularity:desc` and search
  `boost=popularity`. Fixtures are synthetic.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content}
  alias Barkpark.Content.WriteScope
  alias Barkpark.Search.Views
  alias Barkpark.Search.Views.Buffer

  @dataset "production"
  @version "v2025-02-19"

  setup do
    Buffer.reset()
    on_exit(&Buffer.reset/0)
    # The rate-limit test below empties an anonymous bucket; start each test
    # with none.
    :ets.delete_all_objects(:barkpark_rate_limiter)

    ws = create_workspace!()
    project = create_project!(ws)
    scope = [workspace_id: ws.id, project_id: project.id]

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "book",
          "title" => "Book",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "type" => "string"}]
        },
        @dataset,
        scope
      )

    # Three books whose titles all match "garden"; b3 is the newest, so
    # without views it ranks first among equals.
    for {id, year} <- [{"b1", 1990}, {"b2", 2000}, {"b3", 2010}] do
      attrs = %{"_id" => id, "title" => "The garden #{id}", "year" => year}
      {:ok, _} = Content.create_document("book", attrs, @dataset, scope)
      {:ok, _} = Content.publish_document(id, "book", @dataset, scope)
    end

    token = "views-tok-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(token, "views", @dataset, ["read"], ws.id)

    dataset_id = WriteScope.resolve_read_dataset_id(@dataset, scope)
    {:ok, ws: ws, project: project, token: token, dataset_id: dataset_id}
  end

  defp views_path(ws, project), do: "/w/#{ws.slug}/p/#{project.slug}/v1/data/views/#{@dataset}"

  defp authed(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  # Records views straight into the tables: `views` per id for today, then a
  # rollup, so the reads below see `document_popularity` rows.
  defp seed_views(dataset_id, counts) do
    for {id, n} <- counts, _ <- 1..n, do: {:ok, _} = Views.record(dataset_id, [id], nil)
    Views.flush()
    Views.rollup()
  end

  describe "POST /v1/data/views/:dataset" do
    test "a token caller records views; the visitor value dedupes", ctx do
      %{conn: conn, ws: ws, project: project, token: token} = ctx

      body =
        conn
        |> authed(token)
        |> post(views_path(ws, project), %{"id" => "b1", "visitor" => "session-1"})
        |> json_response(202)

      assert body == %{"ok" => true, "accepted" => 1, "duplicates" => 0}

      again =
        scoped_conn()
        |> authed(token)
        |> post(views_path(ws, project), %{"ids" => ["b1", "b2"], "visitor" => "session-1"})
        |> json_response(202)

      assert again == %{"ok" => true, "accepted" => 1, "duplicates" => 1}

      assert Views.flush() == 2
      Views.rollup()
      counts = Views.lookup(ctx.dataset_id, ["b1", "b2"])
      assert counts["b1"]["_views30d"] == 1
      assert counts["b2"]["_views30d"] == 1
    end

    test "the id may ride the query string, as navigator.sendBeacon sends it", ctx do
      %{conn: conn, ws: ws, project: project, token: token} = ctx

      assert %{"accepted" => 1} =
               conn
               |> authed(token)
               |> post(views_path(ws, project) <> "?id=b2")
               |> json_response(202)
    end

    test "without a token the visitor value is ignored; IP and user agent dedupe", ctx do
      %{ws: ws, project: project} = ctx
      Barkpark.SharingFixtures.plant_shares!("#{ws.slug}/#{project.slug}/#{@dataset}:docs:read")

      post_view = fn visitor ->
        scoped_conn()
        |> put_req_header("user-agent", "test-browser")
        |> post(views_path(ws, project), %{"id" => "b1", "visitor" => visitor})
        |> json_response(202)
      end

      assert %{"accepted" => 1} = post_view.("a")
      assert %{"accepted" => 0, "duplicates" => 1} = post_view.("b")
    end

    test "an anonymous caller is refused when the scope is not shared", ctx do
      %{conn: conn, ws: ws, project: project} = ctx
      conn = post(conn, views_path(ws, project), %{"id" => "b1"})
      assert conn.status in [401, 403, 404]
      assert Views.flush() == 0
    end

    test "a missing or malformed id is a 422", ctx do
      %{conn: conn, ws: ws, project: project, token: token} = ctx

      assert %{"error" => %{"code" => "validation_failed"}} =
               conn |> authed(token) |> post(views_path(ws, project), %{}) |> json_response(422)

      too_many = Enum.map(1..51, &"id#{&1}")

      assert %{"error" => %{"code" => "validation_failed"}} =
               scoped_conn()
               |> authed(token)
               |> post(views_path(ws, project), %{"ids" => too_many})
               |> json_response(422)
    end

    test "an unknown dataset is a 404", ctx do
      %{conn: conn, ws: ws, project: project, token: token} = ctx
      path = "/w/#{ws.slug}/p/#{project.slug}/v1/data/views/nosuchds"
      conn = conn |> authed(token) |> post(path, %{"id" => "b1"})
      assert conn.status in [403, 404]
    end

    test "anonymous callers are limited per IP by view_per_minute", ctx do
      %{ws: ws, project: project} = ctx
      Barkpark.SharingFixtures.plant_shares!("#{ws.slug}/#{project.slug}/#{@dataset}:docs:read")
      original = Application.get_env(:barkpark, :rate_limits)
      on_exit(fn -> Application.put_env(:barkpark, :rate_limits, original) end)
      Application.put_env(:barkpark, :rate_limits, Keyword.put(original, :view_per_minute, 2))

      statuses =
        for _ <- 1..3 do
          scoped_conn() |> post(views_path(ws, project), %{"id" => "b1"}) |> Map.get(:status)
        end

      assert statuses == [202, 202, 429]
    end
  end

  describe "GROQ view fields" do
    defp groq(conn, ctx, query) do
      conn
      |> authed(ctx.token)
      |> get("/w/#{ctx.ws.slug}/p/#{ctx.project.slug}/#{@version}/data/query/#{@dataset}", %{
        "query" => query
      })
      |> json_response(200)
      |> Map.fetch!("result")
    end

    test "documents carry _views7d, _views30d and _popularity when the query names one", ctx do
      seed_views(ctx.dataset_id, %{"b1" => 3, "b2" => 1})

      result =
        groq(
          ctx.conn,
          ctx,
          ~s'*[_type == "book"] | order(_id asc) {_id, _views30d, _views7d, _popularity}'
        )

      assert [
               %{"_id" => "b1", "_views30d" => 3, "_views7d" => 3, "_popularity" => p1},
               %{"_id" => "b2", "_views30d" => 1},
               %{"_id" => "b3", "_views30d" => 0, "_views7d" => 0, "_popularity" => p3}
             ] = result

      # GROQ numbers are JSON numbers: a whole score encodes without a fraction.
      assert p1 == 3
      assert p3 == 0

      # A comparison that 0 passes keeps the documents with no views.
      assert ["b3"] = groq(scoped_conn(), ctx, ~s'*[_type == "book" && _views30d < 1]._id')
      assert 1 = groq(scoped_conn(), ctx, ~s'count(*[_type == "book" && _views30d == 0])')

      assert ["b1", "b2", "b3"] =
               groq(scoped_conn(), ctx, ~s'*[_type == "book" && _views7d <= 3] | order(_id)._id')

      # A query that does not name them gets plain documents.
      [doc | _] = groq(scoped_conn(), ctx, ~s'*[_type == "book"]')
      refute Map.has_key?(doc, "_views30d")
    end

    test "order(_views30d desc) and a _views30d filter run in SQL and match GROQ", ctx do
      seed_views(ctx.dataset_id, %{"b1" => 1, "b2" => 5, "b3" => 2})

      assert ["b2", "b3", "b1"] =
               groq(ctx.conn, ctx, ~s'*[_type == "book"] | order(_views30d desc)[0...3]._id')

      assert ["b2", "b3"] =
               groq(
                 scoped_conn(),
                 ctx,
                 ~s'*[_type == "book" && _views30d >= 2] | order(_views30d desc)._id'
               )

      assert 2 = groq(scoped_conn(), ctx, ~s'count(*[_type == "book" && _views30d > 1])')

      # An in-memory filter beside the pushed-down one still applies.
      assert ["b3"] =
               groq(
                 scoped_conn(),
                 ctx,
                 ~s'*[_type == "book" && _views30d > 0 && year > 2005] | order(_popularity desc)._id'
               )
    end
  end

  describe "query API and search" do
    test "order=popularity:desc sorts by the decayed score; _views30d:asc works too", ctx do
      seed_views(ctx.dataset_id, %{"b1" => 4, "b3" => 1})
      path = "/w/#{ctx.ws.slug}/p/#{ctx.project.slug}/v1/data/query/#{@dataset}/book"

      ids = fn order ->
        scoped_conn()
        |> authed(ctx.token)
        |> get(path, %{"order" => order})
        |> json_response(200)
        |> get_in(["result", "documents"])
        |> Enum.map(& &1["_id"])
      end

      assert ids.("popularity:desc") == ["b1", "b3", "b2"]
      assert ids.("_views30d:asc") |> hd() == "b2"
    end

    test "boost=popularity lifts the most viewed of equally relevant matches", ctx do
      seed_views(ctx.dataset_id, %{"b1" => 20})
      path = "/w/#{ctx.ws.slug}/p/#{ctx.project.slug}/v1/data/search/#{@dataset}"

      search = fn params ->
        scoped_conn()
        |> authed(ctx.token)
        |> get(path, Map.merge(%{"q" => "garden", "type" => "book"}, params))
        |> json_response(200)
        |> Map.fetch!("documents")
        |> Enum.map(& &1["_id"])
      end

      refute hd(search.(%{})) == "b1"
      assert hd(search.(%{"boost" => "popularity"})) == "b1"

      conn =
        scoped_conn()
        |> authed(ctx.token)
        |> get(path, %{"q" => "garden", "boost" => "views"})

      assert %{"error" => %{"code" => "malformed"}} = json_response(conn, 400)
    end
  end
end
