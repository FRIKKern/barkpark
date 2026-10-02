defmodule BarkparkWeb.ReadMemoLifetimeTest do
  @moduledoc """
  The read memo (`Barkpark.Content.WriteScope.request_memo/3`): what it saves,
  and that it never outlives the unit of work it was built for
  (task-dbfa7f69abb3b2ed, task-43754c756edf2af6).

  Measured with the lineage-scoped `Barkpark.QueryCounter`, both legs of a
  Studio desk mount and one `GET /v1/data/query`, origin/main → this change:

      | read                         | before                         | after                         |
      |------------------------------|--------------------------------|-------------------------------|
      | desk mount, connected leg    | 34 (datasets 10, projects 7,   | 19 (datasets 2, projects 2,   |
      |                              |  schema_definitions 10)        |  schema_definitions 8)        |
      | desk mount, both legs        | 76                             | 61 (the dead render is not    |
      |                              |                                |  memoized — see StudioLive)   |
      | GET /v1/data/query           | 7 (schema_definitions 4)       | 6 (schema_definitions 2)      |
      | GET /v1/data/query?count=true| 9 (schema_definitions 5)       | 7 (schema_definitions 2)      |

  The lifetime arms below are the point of this file:

    * an HTTP request starts EMPTY. Bandit serves a keep-alive connection's
      requests in one process, and before this change a memo built by one request
      was still set when the next one began (measured);
    * a Studio socket's memo lives for ONE callback (barkpark-sknf: a long-lived
      socket must never pin a row that changed) — a schema edited between two
      callbacks is seen by the second;
    * a write in the same process drops it — a schema written mid-request is read
      back by the same request.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.Content.WriteScope
  alias Barkpark.QueryCounter

  @dataset "production"

  defp schema!(name, title) do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => name,
          "title" => title,
          "icon" => "file-text",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )
  end

  describe "statement budgets the memo buys" do
    test "a desk mount resolves datasets and projects a handful of times, not per caller", %{
      conn: conn
    } do
      schema!("memodesk", "Memo Desk")
      path = scoped_studio("/d/#{@dataset}/studio/content-types/memodesk")
      {:ok, warm, _} = live(conn, path)
      GenServer.stop(warm.pid, :normal)

      {view, events} =
        QueryCounter.capture(fn ->
          {:ok, view, _} = live(conn, path)
          QueryCounter.own(view.pid)
          _ = render(view)
          view
        end)

      # the CONNECTED leg: the socket's own process (the dead render runs in
      # this test process and is deliberately not memoized)
      connected = Enum.filter(events, &(&1.pid == view.pid))
      per = Enum.frequencies_by(connected, & &1.source)
      tenancy = Map.get(per, "datasets", 0) + Map.get(per, "projects", 0)
      schemas = Map.get(per, "schema_definitions", 0)

      assert connected != [], "the counter saw nothing on the socket — vacuous"

      assert tenancy <= 5,
             "the connected desk mount read datasets+projects #{tenancy}x (#{inspect(per)}); " <>
               "it was 17 before the per-callback memo and 4 with it"

      assert schemas <= 8,
             "the connected desk mount read schema_definitions #{schemas}x (#{inspect(per)}); " <>
               "it was 10 before the memo, 9 with the row memo, 8 once the catalog " <>
               "is memoized too (scope_plugin_nodes/4 built the SAME unscoped catalog twice)"
    end

    test "one GET /v1/data/query reads its schema row at most twice", %{conn: conn} do
      schema!("memoq", "Memo Q")
      {:ok, _} = Content.create_document("memoq", %{"doc_id" => "mq-1", "title" => "t"}, @dataset)
      {:ok, _} = Content.publish_document("mq-1", "memoq", @dataset)

      for q <- ["", "?count=true"] do
        {_, {_n, per}} =
          QueryCounter.census(fn ->
            conn |> get("/v1/data/query/#{@dataset}/memoq#{q}") |> json_response(200)
          end)

        assert Map.get(per, "schema_definitions", 0) <= 2,
               "GET /v1/data/query#{q} read schema_definitions #{per["schema_definitions"]}x " <>
                 "(was 4-5): #{inspect(per)}"
      end
    end
  end

  describe "the memo never outlives its unit of work" do
    test "every HTTP request starts with an empty memo and no process opt-in", %{conn: conn} do
      # a stale entry and an opt-in left behind in this (request-serving) process
      Process.put({:barkpark_request_memo, :r4d_sentinel}, :stale)
      WriteScope.enable_process_memo()

      conn |> get("/v1/data/query/#{@dataset}/nothing_here_#{System.unique_integer([:positive])}")

      refute Process.get({:barkpark_request_memo, :r4d_sentinel}),
             "a memo entry from before the request survived into it"

      refute Process.get(:barkpark_process_memo),
             "a Studio dead render's opt-in leaked into the next request on the process"
    end

    test "a Studio socket sees a schema edited between two of its callbacks", %{conn: conn} do
      schema!("memolive", "Before Title")
      path = scoped_studio("/d/#{@dataset}/studio/content-types/memolive")
      {:ok, view, html} = live(conn, path)
      assert html =~ "Before Title"

      # a write from ANOTHER process (this test), between callbacks
      schema!("memolive", "After Title")

      html = render_patch(view, path)

      assert html =~ "After Title",
             "the socket's next callback served the memoized schema, not the row as it is"
    end

    test "the schema memo keeps only its 8 newest rows — a corpus fold cannot pile them up" do
      opts = [memoize: true]
      WriteScope.reset_request_memo()
      names = for i <- 1..10, do: "memocap#{i}_#{System.unique_integer([:positive])}"
      for n <- names, do: Content.Schema.get_schema_raw(n, @dataset, opts)

      held =
        for {{:barkpark_request_memo, {:get_schema_raw, n, _, _, _}}, _} <- Process.get(), do: n

      assert length(held) == 8, "the schema memo holds #{length(held)} rows, not 8"
      refute Enum.at(names, 0) in held, "the OLDEST row was kept and a newer one dropped"
      assert List.last(names) in held
      WriteScope.reset_request_memo()
    end

    test "two catalogs under DIFFERENT scopes are never conflated, and a write between is seen" do
      schema!("memocat#{System.unique_integer([:positive])}", "Catalog Probe")
      ws = Barkpark.TenancyFixtures.create_workspace!()
      wide = []
      narrow = [workspace_id: ws.id]

      # the truth, memo OFF
      truth_wide = Enum.map(Content.list_schemas(@dataset, wide), & &1.name)
      truth_narrow = Enum.map(Content.list_schemas(@dataset, narrow), & &1.name)
      refute truth_wide == truth_narrow, "vacuous: the two scopes return the same catalog"

      WriteScope.reset_request_memo()
      on = [memoize: true]
      assert Enum.map(Content.list_schemas(@dataset, on ++ wide), & &1.name) == truth_wide

      assert Enum.map(Content.list_schemas(@dataset, on ++ narrow), & &1.name) == truth_narrow,
             "the memo served the WIDE catalog to a NARROWER scope"

      added = "memocatnew#{System.unique_integer([:positive])}"
      schema!(added, "Added Mid-Request")

      assert added in Enum.map(Content.list_schemas(@dataset, on ++ wide), & &1.name),
             "the memo served a catalog from before this process's own schema write"

      WriteScope.reset_request_memo()
    end

    test "a schema written mid-request is read back by the same request" do
      opts = [memoize: true]
      name = "memowrite#{System.unique_integer([:positive])}"

      assert {:error, :not_found} = Content.Schema.get_schema_raw(name, @dataset, opts)
      schema!(name, "Written")

      read_back = Content.Schema.get_schema_raw(name, @dataset, opts)

      assert match?({:ok, %{name: ^name}}, read_back),
             "the memo answered #{inspect(read_back)} for a schema this process had just written"
    end
  end
end
