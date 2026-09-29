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

  ## Truncation is NOT a phantom

  `Content.Graph.build_drafts_index/1` reads each type's drafts corpus at the
  `Content.Query` 1000-row ceiling. A corpus bigger than that yields a PARTIAL
  graph: the unread documents are absent as nodes, and every edge pointing at
  one resolves as `phantom`/`dangling` — a truncation presented to the reader as
  a phantom reference, which is an actively WRONG diagnosis, not merely an
  incomplete one. When the payload says the read was capped, this component
  renders a named notice (`data-test-id="studio-graph-truncated"`) above the
  canvas saying so; absent the flag it renders nothing at all.

  ## Why NOT the `truncated` boolean — it is the wrong instrument

  `Content.Graph.traverse/2` (api lane, #17359) returns THREE truncation
  fields, and only one of them means what this banner says:

    * `truncated` — a boolean that is ALSO `true` for a BFS node-budget,
      fan-out, or depth clamp. Keying the banner on it would accuse the drafts
      corpus every time the traversal simply hit its own depth bound, which is
      a normal, complete, correctly-drawn graph.
    * `truncation_reason` — `:node_budget | :fan_out | :depth | :corpus_cap |
      nil`, and a BFS bound WINS the tie. So a read that hit BOTH the corpus cap
      and a depth clamp reports `:depth`, and keying on it would hide the very
      condition this pane exists to name.
    * `corpus_truncation` — `nil`, or `%{truncated: true, limit: _, read: _}`.
      Present on every traverse map, and true ONLY for the corpus cap. That is
      the field, and `corpus_truncation/1` below is the only thing this
      component keys on.

  Read DEFENSIVELY: atom OR string key, and the value must be a MAP carrying
  `truncated: true`. Anything else — `nil`, a bare boolean, a stray string — is
  not-truncated, because a banner accusing a whole graph of being partial is the
  same class of lie in the other direction.
  """

  use BarkparkWeb, :live_component

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       nodes_json: "[]",
       edges_json: "[]",
       root: "",
       rev: 0,
       graph_truncation: nil
     )}
  end

  # An incremental server push (a future `graph-update` delta) bumps the rev so
  # the hook diffs rather than remounts. Same two-clause shape as SheetGrid's
  # `update/2`: delta path first, normal assigns second. The delta carries the
  # graph map (incl. `root`) so the client can re-root on navigation.
  @impl true
  def update(%{graph_op: %{nodes: nodes, edges: edges} = op}, socket) do
    {:ok, derive_graph(socket, nodes, edges, Map.get(op, :root), corpus_truncation(op))}
  end

  def update(assigns, socket) do
    graph = Map.get(assigns, :graph) || %{}
    nodes = Map.get(graph, :nodes, [])
    edges = Map.get(graph, :edges, [])
    root = Map.get(graph, :root)

    socket = assign(socket, Map.take(assigns, [:id, :doc]))
    {:ok, derive_graph(socket, nodes, edges, root, corpus_truncation(graph))}
  end

  # The CORPUS truncation, read defensively off whatever the graph payload is.
  # Returns `nil` (not truncated) or `%{limit: _, read: _}` — the two numbers the
  # banner names, each possibly `nil` when the payload omits them.
  #
  # Deliberately NOT keyed on the sibling `truncated` boolean or on
  # `truncation_reason`: the first is true for BFS clamps too, and the second
  # lets a BFS bound win the tie and mask a real corpus cap. See the moduledoc.
  #
  # Atom key OR string key, because the same map reaches this component both as
  # a server-built map (atom keys) and, on the `graph_op` delta path, possibly
  # decoded from the wire (string keys). The value must be a MAP carrying
  # `truncated: true`; everything else is not-truncated.
  defp corpus_truncation(map) when is_map(map) do
    case Map.get(map, :corpus_truncation, Map.get(map, "corpus_truncation")) do
      ct when is_map(ct) ->
        if Map.get(ct, :truncated, Map.get(ct, "truncated")) == true do
          %{
            limit: Map.get(ct, :limit, Map.get(ct, "limit")),
            read: Map.get(ct, :read, Map.get(ct, "read"))
          }
        end

      _ ->
        nil
    end
  end

  defp corpus_truncation(_), do: nil

  # The banner copy. Names the two numbers when the payload carries them, and
  # falls back to the number-free sentence when it does not — an absent `limit`
  # must degrade the wording, never blank the banner or print "read  of a
  # corpus larger than  documents".
  defp truncation_copy(%{limit: limit, read: read})
       when is_integer(limit) and is_integer(read) do
    "Partial graph — read #{read} of a drafts corpus larger than #{limit} documents, " <>
      "so some documents were never read. Dangling edges shown here may be truncation, " <>
      "not phantom references."
  end

  defp truncation_copy(_) do
    "Partial graph — the drafts corpus exceeded the read ceiling, so some documents were " <>
      "never read. Dangling edges shown here may be truncation, not phantom references."
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
  defp derive_graph(socket, nodes, edges, root, corpus_truncation) do
    assign(socket,
      nodes_json: Jason.encode!(nodes),
      edges_json: Jason.encode!(edges),
      root: to_string(root || ""),
      rev: (socket.assigns[:rev] || 0) + 1,
      graph_truncation: corpus_truncation
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="editor-panel graph-editor" data-role="content" data-test-id="studio-graph-panel">
      <%!-- Truncation is rendered, never swallowed. Without this the reader sees
            a graph whose missing half is drawn as dashed PHANTOM nodes and reads
            them as broken references. Colors come from the --warn token pair
            (no literals — scripts/studio-literal-check.sh). --%>
      <div
        :if={@graph_truncation}
        class="bp-pane-notice"
        style="color: var(--warn); background: var(--warn-soft);"
        role="status"
        data-test-id="studio-graph-truncated"
      >
        <%= truncation_copy(@graph_truncation) %>
      </div>
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
