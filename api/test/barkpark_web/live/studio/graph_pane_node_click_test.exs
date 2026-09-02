defmodule BarkparkWeb.Studio.GraphPaneNodeClickTest do
  @moduledoc """
  THE STUDIO GRAPH PANE'S NODE CLICK.

  The shared Canvas2D renderer (`priv/static/assets/bp-graph.js`, registered as
  `Hooks.GraphPane`) installs `onNodeClick -> pushEvent("node-clicked", {id})`
  UNCONDITIONALLY on every host that mounts it. `BarkparkWeb.Studio.GraphView`
  is a `live_component` that mounts the hook with NO `phx-target`, so the event
  lands on the PARENT `StudioLive` — which had no `handle_event("node-clicked",
  …)` clause and no catch-all. PR #14778 fixed the `FinderLive` half only.

  ## What actually happens on main — the filing's crash claim is FALSE

  The row says "StudioLive has no catch-all handle_event/3 clause, so the first
  node click is a FunctionClauseError: the LiveView process crashes, the page
  blanks and remounts." MEASURED on `origin/main` (9059e00143), that is not what
  happens, and no test can be written that reproduces it: `studio_live.ex` HAS a
  fall-through `handle_event(event, _params, socket)` (last clause, added with
  the comment "a stale/unknown phx event must not FunctionClauseError-crash the
  session"). It has been there since #13073. `FinderLive` — the surface #14778
  fixed — is the one that had no fall-through, which is where the crash shape
  came from.

  What a node click on main really does, in two shapes, because
  `BarkparkWeb.Studio.Caps.classify/1` is DEFAULT-DENY and the
  `:studio_caps_gate` `handle_event` hook halts a `:deny` event unless the
  socket is admin:

    * ADMIN — the gate passes, the fall-through absorbs the event, and the only
      trace is `[warning] studio: unhandled event "node-clicked"`. The click is
      silently dead.

    * NON-ADMIN MEMBER — the gate halts BEFORE the fall-through and answers with
      `You don't have access to do that.` (measured: the rendered page carries
      that string). Every node in the blast radius is dead AND accuses the user
      of a permission problem they do not have.

  So the pane is inert either way, and for most users it lies about why. Fixing
  only the missing clause would leave every non-admin still staring at the false
  permission error, so the fix is BOTH: the clause, and `node-clicked` in the
  `@safe_events` (navigation/read, no capability) tier next to `view-graph` and
  `open-backlink`. `describe "the non-admin half"` below is that second half and
  it is the reason the `caps.ex` edit is in this PR.

  ## What is pinned

    * A node click OPENS THE CLICKED DOCUMENT, through the reserved
      `["open", type, doc_id]` nav path — the same door the backlinks panel uses
      (`Handlers.Paper.open_backlink/2`), chosen because a graph node may live
      OUTSIDE the currently-navigated structure subtree and that path resolves
      with no structure lookup.

    * The clicked id is resolved AGAINST THE PAYLOAD ALREADY ON THE SOCKET
      (`@graph_data.nodes`), never with a fresh PK read. The wire carries only
      `documents.id` (the hook pushes `{id}`, and `bp-graph.js` is a 4-copy
      mirror set under a drift gate, so the payload cannot be widened), while
      the nav path needs `{type, doc_id}` — both of which the node map already
      carries. That makes the handler fail-CLOSED for free: `graph_data` was
      built under this caller's tenancy scope, so a FORGED id naming a document
      in another workspace is simply absent from the list and the click is an
      inert no-op. The third test is that direction, and it is what keeps the
      first two from being the whole story.

  Isolated ws/proj/dataset, two published docs and one materialised
  `content_edges` row between them, so the traversal returns TWO real nodes and
  the click target is a node that is NOT the root.
  """

  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Tenancy
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  @ws_slug "graphclick-ws"
  @proj_slug "graphclick-proj"
  @dataset "graphclick-ds"
  @type_name "graphclicknode"

  @root_id "graphclick-root"
  @child_id "graphclick-child"

  setup %{conn: conn} do
    default_ws = Tenancy.get_default_workspace()

    {:ok, ws} = Tenancy.create_workspace(%{slug: @ws_slug, name: "GraphClickWS"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: @proj_slug, name: "GraphClickProj"})
    {:ok, _ds} = Tenancy.create_dataset(proj, %{slug: @dataset, name: "GraphClick"})

    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _schema} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Graph Click Nodes",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset,
        scope
      )

    root = publish!(@root_id, "Graph Click Root", scope)
    child = publish!(@child_id, "Graph Click Child", scope)

    # The Phase-3 edge projector is async/:manual in tests, so materialise the
    # one `content_edges` row the BFS walks directly (the `graph_test.exs`
    # harness contract).
    [{:ok, _}] =
      Content.add_edges(
        [%{from_id: @root_id, to_id: @child_id, kind: "references"}],
        [dataset: @dataset] ++ scope
      )

    admin_conn = signed_in_conn(conn, default_ws, ws, "admin")
    member_conn = signed_in_conn(conn, default_ws, ws, "member")

    {:ok, conn: admin_conn, member_conn: member_conn, root: root, child: child}
  end

  defp signed_in_conn(conn, default_ws, ws, role) do
    raw = "graphclick-#{role}-" <> Ecto.UUID.generate()

    # BOTH halves of the seat rule: `Caps.admin` is token perms AND membership
    # role (`admin_from/3` -> `token_admin_from/3`), so an "admin" membership on
    # a read/write-only token still derives `admin: false` — and the caps gate
    # would then halt the admin case before it ever reached the handler, hiding
    # the difference between the two shapes described above.
    perms = if role == "admin", do: ["read", "write", "admin"], else: ["read", "write"]

    {:ok, token} =
      Auth.create_token(raw, "graphclick-#{role}", "production", perms, default_ws.id)

    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id, role)

    Plug.Test.init_test_session(conn, %{"api_token" => raw})
  end

  defp publish!(doc_id, title, scope) do
    {:ok, _} =
      Content.create_document(
        @type_name,
        %{"_id" => doc_id, "title" => title},
        @dataset,
        scope
      )

    {:ok, doc} = Content.publish_document(doc_id, @type_name, @dataset, scope)
    doc
  end

  defp graph_path(doc_id),
    do: "/w/#{@ws_slug}/p/#{@proj_slug}/d/#{@dataset}/studio/graph/#{doc_id}"

  defp open_path(doc_id),
    do: "/w/#{@ws_slug}/p/#{@proj_slug}/d/#{@dataset}/studio/open/#{@type_name}/#{doc_id}"

  describe "node-clicked" do
    test "a click on a node opens that document via the reserved open/<type>/<id> nav path",
         %{conn: conn, child: child} do
      {:ok, view, html} = live(conn, graph_path(@root_id))

      # PERMIT DIRECTION FIRST — the graph pane really rendered and its payload
      # really carries the child node, so the click below is not fired at an
      # empty canvas and the assertion that follows is not vacuous.
      assert html =~ ~s(data-test-id="studio-graph-canvas")

      assert html =~ child.id,
             "the clicked node's documents.id UUID must be in the data-nodes payload"

      view |> element("#studio-graph") |> render_hook("node-clicked", %{"id" => child.id})

      assert_patch(view, open_path(@child_id))

      # And the pane actually resolved that path into the clicked document —
      # the classic editor shell, whose header carries the doc-action bar. The
      # graph pane renders NO header, so `view-graph` is the marker that
      # separates "opened a document" from "still on the canvas" (test 3 reads
      # it in the negative).
      assert has_element?(view, "[data-test-id=view-graph]")
      assert render(view) =~ "Graph Click Child"
    end

    test "clicking the root node opens the root document rather than killing the view",
         %{conn: conn, root: root} do
      {:ok, view, _html} = live(conn, graph_path(@root_id))

      view |> element("#studio-graph") |> render_hook("node-clicked", %{"id" => root.id})

      assert_patch(view, open_path(@root_id))
      assert render(view) =~ "Graph Click Root"
    end

    test "an id that is not in this socket's graph payload is an inert no-op, not a crash",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, graph_path(@root_id))

      # A forged id — the shape a client can always push, and the shape a doc in
      # ANOTHER workspace would have. It is not in `@graph_data.nodes` (which
      # was built under this caller's scope), so nothing is navigated and no
      # foreign slug reaches the URL bar.
      view
      |> element("#studio-graph")
      |> render_hook("node-clicked", %{"id" => Ecto.UUID.generate()})

      # The view is alive AND still on the graph pane — nothing navigated.
      # (`=~ "Graph Click Child"` would NOT discriminate here: every node's
      # title rides the canvas' own data-nodes JSON payload. The editor-header
      # doc-action bar is the marker only the opened-document render has, and
      # test 1 asserts its presence on that render.)
      assert has_element?(view, "#studio-graph[data-test-id=studio-graph-canvas]")
      refute has_element?(view, "[data-test-id=view-graph]")
    end
  end

  describe "the non-admin half (the caps default-DENY tier)" do
    test "a plain member's click navigates too — it is not answered with a permission error",
         %{member_conn: conn, child: child} do
      {:ok, view, html} = live(conn, graph_path(@root_id))

      # Same permit direction: this member can see the pane and the node.
      assert html =~ ~s(data-test-id="studio-graph-canvas")
      assert html =~ child.id

      view |> element("#studio-graph") |> render_hook("node-clicked", %{"id" => child.id})

      assert_patch(view, open_path(@child_id))

      refute render(view) =~ "have access to do that",
             "an unclassified event is halted by the caps gate with a FALSE permission " <>
               "error — `node-clicked` belongs in the @safe_events navigation tier"
    end
  end
end
