defmodule BarkparkWeb.FinderGraphBridgeTest do
  @moduledoc """
  THE FINDER -> GRAPH BRIDGE.

  `/finder` runs a server-side search and renders a Canvas2D corpus graph on the
  same screen. The renderer (`/assets/bp-graph.js`) has always exposed the exact
  entry point a host needs to drive it — `setMatches([{id, w}])`, which dims
  every non-match and scales each match's emphasis by its weight — and nothing
  on this page ever called it: `finder_live.ex` contained no `push_event` at
  all, so matches delivered per keystroke were ZERO. Typing filtered the result
  list and left the canvas inert.

  The second half of the same defect: because the host never declared that it
  owned the query, the renderer drew its OWN in-canvas search box on any corpus
  past 30 nodes (a naive substring dimmer) — so the page shipped TWO unrelated
  search fields, one that only touched the list and one that only touched the
  graph. The renderer's own comment says the `externalSearch` suppression exists
  "so a second in-canvas box would be a confusing duplicate"; the host simply
  never set it.

  What is pinned here:

    * every resolved query pushes `graph-matches` — a cold `?q=` URL and a typed
      keystroke alike, because `handle_params/3` owns the search for both;
    * the payload's ids are the hit ids and the weights are the EXACT curve the
      React editions publish (`w = 0.2 + 0.8·(1−t)^1.4`), so the three framework
      editions of this surface emphasize identically rather than merely
      similarly;
    * `matches: nil` (idle) and `matches: []` (a query that matched nothing) are
      DIFFERENT payloads — collapsing them would draw a zero-hit search exactly
      like no search at all;
    * the graph div carries `data-external-search="true"`, the flag the hook
      reads to suppress the duplicate box — asserted on the dead render too,
      since that is the markup a crawler and the first paint see;
    * a node click does not kill the view. The shared hook installs
      `onNodeClick -> pushEvent("node-clicked")` unconditionally and LiveView has
      no catch-all `handle_event/3`, so the missing clause was a
      FunctionClauseError on the first click.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content

  @type_name "findergraphdoc"
  @dataset "findergraphbridge"

  setup do
    {default_ws, default_project} = Barkpark.TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: default_ws.id, project_id: default_project.id]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => @type_name, "title" => @type_name, "visibility" => "public", "fields" => []},
        @dataset,
        scope
      )

    uid = System.unique_integer([:positive])
    # A nonsense token so the hit count is EXACTLY three: the weight curve is
    # pinned by value below, and it is a function of the returned set size.
    token = "zqxgraphbridge#{uid}"

    ids =
      for n <- 1..3 do
        doc_id = "finder-graph-#{uid}-#{n}"
        publish!(doc_id, "#{token} #{n}", scope)
        Content.published_id(doc_id)
      end

    %{token: token, ids: ids}
  end

  defp publish!(doc_id, title, scope) do
    {:ok, _} =
      Content.create_document(
        @type_name,
        %{"doc_id" => doc_id, "title" => title, "content" => %{}},
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document(doc_id, @type_name, @dataset, scope)
    :ok
  end

  defp finder_path(query \\ nil) do
    case query do
      nil -> "/finder?dataset=#{@dataset}"
      q -> "/finder?dataset=#{@dataset}&q=#{URI.encode_www_form(q)}"
    end
  end

  describe "matches per query" do
    test "a cold ?q= URL pushes the weighted hit set to the graph", %{
      conn: conn,
      token: token,
      ids: ids
    } do
      {:ok, view, html} = live(conn, finder_path(token))

      # PERMIT DIRECTION FIRST — the search really ran and rendered its hits, so
      # the push assertion below is not read off an empty page.
      assert html =~ token

      assert_push_event(view, "graph-matches", %{matches: matches})

      assert length(matches) == 3,
             "the graph must receive the visible hit set, got: #{inspect(matches)}"

      assert MapSet.new(matches, & &1.id) == MapSet.new(ids),
             "the pushed ids must be the PUBLISHED ids the graph payload keys nodes by"
    end

    test "the weights are the React editions' rank curve, to the decimal", %{
      conn: conn,
      token: token
    } do
      {:ok, view, _html} = live(conn, finder_path(token))

      assert_push_event(view, "graph-matches", %{matches: matches})

      # w = 0.2 + 0.8·(1−t)^1.4 with t = rank/(n−1) over n = 3 hits:
      #   rank 0 -> t 0.0 -> 1.0     (the top hit reads loudest)
      #   rank 1 -> t 0.5 -> 0.503
      #   rank 2 -> t 1.0 -> 0.2     (the floor, still visible above the dimmed)
      assert Enum.map(matches, & &1.w) == [1.0, 0.503, 0.2],
             "the weight curve drifted from web/components/finder.tsx `graphMatches`"
    end

    test "a keystroke pushes matches — the same path a typed query takes", %{
      conn: conn,
      token: token,
      ids: ids
    } do
      {:ok, view, _html} = live(conn, finder_path())

      # Drain the idle push the cold mount emits, so the assertion below is about
      # the KEYSTROKE and not about the mount that preceded it.
      assert_push_event(view, "graph-matches", %{matches: nil})

      html = view |> element("form") |> render_change(%{"q" => token})
      assert html =~ token

      assert_push_event(view, "graph-matches", %{matches: matches})
      assert MapSet.new(matches, & &1.id) == MapSet.new(ids)
    end
  end

  describe "idle vs. zero hits" do
    test "no query pushes nil — the filter clears and the corpus shows undimmed",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, finder_path())

      assert_push_event(view, "graph-matches", %{matches: nil})
    end

    test "a query that matches nothing pushes [] — NOT nil", %{conn: conn} do
      {:ok, view, _html} = live(conn, finder_path("zzzznothingmatchesthisatall"))

      assert_push_event(view, "graph-matches", %{matches: []})
    end
  end

  describe "the duplicate in-canvas search box" do
    test "the graph div declares the host owns search on the connected render",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, finder_path())

      assert html =~ ~s(data-external-search="true"),
             "without this flag bp-graph.js draws its own search box past 30 nodes — " <>
               "/finder would ship two unrelated search fields"
    end

    test "and on the dead render, which is what a crawler and the first paint see",
         %{conn: conn} do
      html = conn |> get(finder_path()) |> html_response(200)

      assert html =~ ~s(data-external-search="true")
    end
  end

  describe "node clicks" do
    test "a node click does not kill the view", %{conn: conn, ids: ids} do
      {:ok, view, _html} = live(conn, finder_path())

      # The hook pushes this unconditionally on every host that mounts it. With
      # no matching clause LiveView raises FunctionClauseError and the view dies.
      view |> element("#finder-graph") |> render_hook("node-clicked", %{"id" => hd(ids)})

      assert render(view) =~ "bp-finder",
             "the view did not survive a node click"
    end
  end
end
