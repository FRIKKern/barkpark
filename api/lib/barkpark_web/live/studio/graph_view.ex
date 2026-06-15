defmodule BarkparkWeb.Studio.GraphView do
  @moduledoc """
  Studio blast-radius pane (Goal `ges/graph-edge-seam`, Phase 5) — one
  `Phoenix.LiveComponent` owning the graph surface. Mirrors the `SheetGrid`
  LiveComponent's change-tracking contract: every derived assign the client
  reads (the JSON node/edge payloads + the root id) is computed in `update/2`
  and persisted on the socket, NEVER in `render/1`.

  ## Renderer — Canvas2D, NOT Cytoscape

  The client half (`bp-graph.js`) is a SELF-CONTAINED vanilla Canvas2D
  renderer with a hand-rolled velocity-Verlet force simulation — ZERO npm,
  ZERO network-fetched libraries (Cytoscape is fully gutted). Layout is now a
  CLIENT-SIDE force sim: the server derives only the node/edge topology + the
  root id, and the client owns ALL positioning, the BFS blast-ring banding,
  the angular fan, and the per-frame draw. (Historically Cytoscape owned
  client layout; that dependency is removed.)

  ## Wire protocol — server derives topology + root, client lays out

  `traverse/2` (Phase 4) runs server-side and hands this component a
  `%{root: id, nodes: [...], edges: [...]}` map. `update/2` JSON-encodes the
  node/edge lists ONCE and stores `nodes_json` / `edges_json` / `root` / `rev`
  on the socket. `render/1` emits a single `<div id="studio-graph"
  phx-hook="GraphPane" data-nodes=… data-edges=… data-root=… data-rev=…>`. The
  `Hooks.GraphPane` client half parses the `data-*` attrs, mounts the Canvas2D
  renderer on `mounted()`, and re-ingests via `update(nodes, edges, {rootId})`
  on `updated()`.

  ## Root is load-bearing — it MUST be threaded

  The renderer pins the root dead-center as the gravitational sun and bands
  dependents into concentric BFS blast-rings, so radial distance encodes
  impact rank. That entire utility is computed AROUND the root id. The server
  emits the root authoritatively (`graph.ex` `root:` field, published +
  drafts); `derive_graph/3` carries it onto `data-root` and the hook passes it
  as `opts.rootId` on BOTH mount and every update. Dropping root here would
  silently re-center the graph on an arbitrary serialization-order node.

  ## Hook-id stability (the verified gotcha)

  The graph div carries a CONSTANT `id="studio-graph"` — NOT a `doc_id`-derived
  id. A `doc_id`-derived id would destroy+remount the hook on every navigation,
  re-initialising the renderer from scratch and losing the layout. Navigation
  changes the `data-*` attrs, which the hook's `updated()` re-ingests in place.

  ## Derive in update/2, never render/1

  Computing the JSON payloads in `render/1` would re-mark them changed on EVERY
  render and silently defeat LiveView's equality-based change tracking — the
  same `derive_grid/1` presence-optimisation trap SheetGrid documents. So the
  encode happens in `update/2` and the result rides the socket.

  ## Phantom nodes

  `phantom: true` nodes (dangling reference targets — a `to_id` the FK can't
  store) carry a bare `_id` + `via_field` + `refType` and are styled
  dashed/muted client-side; the hook NEVER requests expansion on them. Edge
  `weight` is read client-side for thickness/spring rest-length ONLY — it is
  the one place weight is consumed (ranking is topology-only, see
  `Content.Graph.rank_dependents/3`).
  """

  use BarkparkWeb, :live_component

  @impl true
  def mount(socket) do
    {:ok, assign(socket, nodes_json: "[]", edges_json: "[]", root: "", rev: 0)}
  end

  # An incremental server push (a future `graph-update` delta) bumps the rev so
  # the hook diffs rather than remounts. Same two-clause shape as SheetGrid's
  # `update/2`: delta path first, normal assigns second. The delta carries the
  # graph map (incl. `root`) so the client can re-root on navigation.
  @impl true
  def update(%{graph_op: %{nodes: nodes, edges: edges} = op}, socket) do
    {:ok, derive_graph(socket, nodes, edges, Map.get(op, :root))}
  end

  def update(assigns, socket) do
    graph = Map.get(assigns, :graph) || %{}
    nodes = Map.get(graph, :nodes, [])
    edges = Map.get(graph, :edges, [])
    root = Map.get(graph, :root)

    socket = assign(socket, Map.take(assigns, [:id, :doc]))
    {:ok, derive_graph(socket, nodes, edges, root)}
  end

  # ── derived assigns (the change-tracking contract) ──────────────────────────
  #
  # The JSON payloads + the root id the client reads are encoded HERE — on a
  # graph change — and persisted on the socket, never in render/1. An update
  # that does not touch the graph marks none of these changed and the div
  # re-render is skipped wholesale; an encode in render/1 would re-mark on every
  # call and defeat the tracking (the SheetGrid derive_grid lesson).
  #
  # `root` is the load-bearing axis: the client pins it dead-center and bands
  # dependents by BFS depth around it. Emitting it as a bare data-root attr
  # (string id, NOT JSON) keeps the wire trivial and the client robust.
  defp derive_graph(socket, nodes, edges, root) do
    assign(socket,
      nodes_json: Jason.encode!(nodes),
      edges_json: Jason.encode!(edges),
      root: to_string(root || ""),
      rev: (socket.assigns[:rev] || 0) + 1
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="editor-panel graph-editor" data-test-id="studio-graph-panel">
      <%!-- STABLE id (NOT doc_id-derived) so navigation re-ingests via the
            data-* attrs rather than remounting the renderer and losing layout.
            data-root carries the gravitational-sun node id (string) the client
            pins dead-center; without it the graph re-centers on an arbitrary
            serialization-order node. --%>
      <div
        id="studio-graph"
        class="graph-pane"
        style="height: calc(100vh - 56px); min-height: 480px;"
        phx-hook="GraphPane"
        phx-update="ignore"
        data-nodes={@nodes_json}
        data-edges={@edges_json}
        data-root={@root}
        data-rev={@rev}
        data-test-id="studio-graph-canvas"
      >
      </div>
    </div>
    """
  end
end
