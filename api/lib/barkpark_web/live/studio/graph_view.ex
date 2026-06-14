defmodule BarkparkWeb.Studio.GraphView do
  @moduledoc """
  Studio blast-radius pane (Goal `ges/graph-edge-seam`, Phase 5) — one
  `Phoenix.LiveComponent` owning the Cytoscape graph surface. Mirrors the
  `SheetGrid` LiveComponent's change-tracking contract: every derived assign
  the client reads (the JSON node/edge payloads) is computed in `update/2` and
  persisted on the socket, NEVER in `render/1`.

  ## Wire protocol — server derives, client lays out

  `traverse/2` (Phase 4) runs server-side and hands this component a
  `%{nodes: [...], edges: [...]}` map. `update/2` JSON-encodes it ONCE and
  stores `nodes_json` / `edges_json` / `rev` on the socket. `render/1` emits a
  single `<div id="studio-graph" phx-hook="GraphPane" data-nodes=… data-edges=…
  data-rev=…>`. The `Hooks.GraphPane` client half (`bp-graph.js`) parses the
  `data-*` attrs, inits Cytoscape on `mounted()`, and diffs via `cy.json({…})`
  on `updated()` — Cytoscape owns ALL client layout.

  ## Hook-id stability (the verified gotcha)

  The graph div carries a CONSTANT `id="studio-graph"` — NOT a `doc_id`-derived
  id. A `doc_id`-derived id would destroy+remount the hook on every navigation,
  re-initialising Cytoscape from scratch and losing the layout. Navigation
  changes the `data-*` attrs, which the hook's `updated()` diffs in place.

  ## Derive in update/2, never render/1

  Computing the JSON payloads in `render/1` would re-mark them changed on EVERY
  render and silently defeat LiveView's equality-based change tracking — the
  same `derive_grid/1` presence-optimisation trap SheetGrid documents. So the
  encode happens in `update/2` and the result rides the socket.

  ## Phantom nodes

  `phantom: true` nodes (dangling reference targets — a `to_id` the FK can't
  store) carry a bare `_id` + `via_field` + `refType` and are styled
  dashed/muted client-side; the hook NEVER requests expansion on them. Edge
  `weight` is read by Cytoscape for thickness/spring length ONLY — it is the
  one place weight is consumed (ranking is topology-only, see
  `Content.Graph.rank_dependents/3`).
  """

  use BarkparkWeb, :live_component

  @impl true
  def mount(socket) do
    {:ok, assign(socket, nodes_json: "[]", edges_json: "[]", rev: 0)}
  end

  # An incremental server push (a future `graph-update` delta) bumps the rev so
  # the hook diffs rather than remounts. Same two-clause shape as SheetGrid's
  # `update/2`: delta path first, normal assigns second.
  @impl true
  def update(%{graph_op: %{nodes: nodes, edges: edges}}, socket) do
    {:ok, derive_graph(socket, nodes, edges)}
  end

  def update(assigns, socket) do
    graph = Map.get(assigns, :graph) || %{}
    nodes = Map.get(graph, :nodes, [])
    edges = Map.get(graph, :edges, [])

    socket = assign(socket, Map.take(assigns, [:id, :doc]))
    {:ok, derive_graph(socket, nodes, edges)}
  end

  # ── derived assigns (the change-tracking contract) ──────────────────────────
  #
  # The JSON payloads the client reads are encoded HERE — on a graph change —
  # and persisted on the socket, never in render/1. An update that does not
  # touch the graph marks none of these changed and the div re-render is
  # skipped wholesale; an encode in render/1 would re-mark on every call and
  # defeat the tracking (the SheetGrid derive_grid lesson).
  defp derive_graph(socket, nodes, edges) do
    assign(socket,
      nodes_json: Jason.encode!(nodes),
      edges_json: Jason.encode!(edges),
      rev: (socket.assigns[:rev] || 0) + 1
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="editor-panel graph-editor" data-test-id="studio-graph-panel">
      <%!-- STABLE id (NOT doc_id-derived) so navigation diffs the data-* attrs
            rather than remounting Cytoscape and losing the layout. --%>
      <div
        id="studio-graph"
        class="graph-pane"
        phx-hook="GraphPane"
        phx-update="ignore"
        data-nodes={@nodes_json}
        data-edges={@edges_json}
        data-rev={@rev}
        data-test-id="studio-graph-canvas"
      >
      </div>
    </div>
    """
  end
end
