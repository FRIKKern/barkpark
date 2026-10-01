defmodule BarkparkWeb.ReadHotPathStatementSlopeTest do
  @moduledoc """
  `GET /v1/data/query/:dataset/:type` and the Studio desk list pane are the
  two list reads that had no statement pin. Both cost the SAME number of
  statements whether the list holds a few rows or many (task-5c0735c8e50afcfd).

  Measured 2026-10-02 with the lineage-scoped `Barkpark.QueryCounter`, median
  of 7 warm runs, on a loaded 10-core dev box:

      | read                                | small         | large          |
      |-------------------------------------|---------------|----------------|
      | GET /v1/data/query (published)      | 7 st, 1.2 ms  | 7 st, 2.6 ms   |  10 / 200 docs
      | GET /v1/data/query ?count=true      | 9 st, 1.4 ms  | 9 st, 4.7 ms   |
      | GET /v1/data/query ?perspective=…   | 7 st, 1.4 ms  | 7 st, 3.3 ms   |
      | desk list pane (both mount legs)    | 64 st, 47 ms  | 64 st, 111 ms  |  10 / 200 docs
      | /admin/projects board (both legs)   | 21 st, 10 ms  | 21 st, 31 ms   |  10 / 200 tasks

  There is no N+1 today: one `documents` statement reads every row on the page.
  The assertion is the SLOPE, meaning the statements at the larger size minus
  those at the smaller, and never an absolute count:

    * a per-row lookup makes the slope positive and reds here. An injected
      per-row `Repo.query!` in `QueryController` and in
      `PaneBuilder.list_page_preflighted/4` reddened 5 of 6 cases (12 -> 107,
      103 -> 223). The sixth case is two over-the-page lists, which by design
      read only one page;
    * a constant read added for a good reason does not move the slope.

  The board, `?expand=` and the paper reader already carry their own pins
  (`board_live_test`, `content/expand_test`, `reader_query_baseline_test`).

  ONE SESSION AT A TIME. A Studio mount costs one more statement for every
  other live Studio session in the workspace (task-c8a87043cb286a2f: each
  presence re-render reads the workspace row in render). So each desk mount
  here runs with no other Studio view alive. Without that, the slope would
  count this test's own leftover sessions instead of the list.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.QueryCounter

  @dataset "production"

  defp seed!(type, n) do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => type,
          "icon" => "file-text",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )

    for i <- 1..n do
      id = "#{type}-#{i}"
      {:ok, _} = Content.create_document(type, %{"doc_id" => id, "title" => "Row #{i}"}, @dataset)
      # half published, so the published read pages a real mix of pairs
      if rem(i, 2) == 0, do: {:ok, _} = Content.publish_document(id, type, @dataset)
    end

    type
  end

  defp http_statements(conn, path) do
    # warm once so a first-call cache fill is not billed to the slope
    conn |> get(path) |> json_response(200)
    {_, n} = QueryCounter.count(fn -> conn |> get(path) |> json_response(200) end)
    n
  end

  # See "ONE SESSION AT A TIME" in the moduledoc: the warm-up view is stopped,
  # and its exit awaited, before the measured one mounts.
  defp stop_view!(view) do
    ref = Process.monitor(view.pid)
    GenServer.stop(view.pid, :normal)
    assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
  end

  defp desk_statements(conn, type) do
    path = scoped_studio("/d/#{@dataset}/studio/content-types/#{type}")
    {:ok, warm, _html} = live(conn, path)
    stop_view!(warm)

    {view, n} =
      QueryCounter.count(fn ->
        {:ok, view, _html} = live(conn, path)
        QueryCounter.own(view.pid)
        _ = render(view)
        view
      end)

    stop_view!(view)
    n
  end

  describe "GET /v1/data/query/:dataset/:type" do
    for q <- ["", "?count=true", "?perspective=drafts", "?perspective=drafts&limit=100"] do
      @q q
      test "statements do not grow with the page (#{inspect(q)})", %{conn: conn} do
        small = seed!("slopesmall", 10)
        big = seed!("slopebig", 200)

        n_small = http_statements(conn, "/v1/data/query/#{@dataset}/#{small}#{@q}")
        n_big = http_statements(conn, "/v1/data/query/#{@dataset}/#{big}#{@q}")

        assert n_small > 0, "the counter saw nothing — the measurement is vacuous"

        assert n_big == n_small,
               "GET /v1/data/query#{@q}: #{n_small} statements at 10 documents, #{n_big} at 200 — " <>
                 "a per-row read (N+1) has entered the list path"
      end
    end
  end

  describe "the Studio desk list pane" do
    # The pane pages at 100 rows. A list that overflows the page costs a
    # constant extra read (the "100+ / Show more" probe), so each slope is taken
    # on ONE side of that line: both sizes fit, or both overflow.
    for {a, b} <- [{20, 80}, {150, 300}] do
      @a a
      @b b
      test "statements do not grow with the list (#{a} vs #{b} rows)", %{conn: conn} do
        small = seed!("slopedesk#{@a}", @a)
        big = seed!("slopedesk#{@b}", @b)

        n_small = desk_statements(conn, small)
        n_big = desk_statements(conn, big)

        assert n_small > 0, "the counter saw nothing — the measurement is vacuous"

        assert n_big == n_small,
               "desk list: #{n_small} statements at #{@a} documents, #{n_big} at #{@b} — " <>
                 "a per-row read (N+1) has entered the pane"
      end
    end
  end
end
