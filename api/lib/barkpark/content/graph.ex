defmodule Barkpark.Content.Graph do
  @moduledoc """
  The content-graph BFS engine (Goal `ges/graph-edge-seam`, Phase 4).

  Walks the materialised `content_edges` table from a root document, bounded by
  three trip-wires, and returns a node/edge payload the Studio Cytoscape pane
  (Phase 5) and the `/v1/graph/*` HTTP surface consume.

  ## What it reads

  `content_edges` rows are keyed by `documents.id` UUIDs (the FK target), NOT
  the `doc_id` slug. `traverse/2` therefore takes a root `documents.id` UUID and
  walks `Content.list_outbound_edges/2` (forward) and
  `Content.list_inbound_edges/2` (reverse). Node metadata (title, type, doc_id)
  is hydrated by a keyed read on the `documents` table.

  ## Trip-wires (whichever fires first wins)

    * `visited >= @node_budget` (1000) → stop, `truncation_reason: :node_budget`.
    * neighbours at one level `> @fan_out` (200) → take 200, mark truncated,
      `truncation_reason: :fan_out`.
    * `depth > clamped_depth` → stop, `truncation_reason: :depth`.

  `depth` is CLAMPed to `1..5` (clamp, never 4xx). The response ALWAYS carries
  `truncated` (bool) + `truncation_reason` (atom | nil).

  ## Perspective

  Default `:published` — the materialised `content_edges` table is
  published-only (Phase 3) and `traverse_published/2` walks it keyed by
  `documents.id` UUIDs.

  `:drafts` is a token-gated, slower LIVE extract handled by a SEPARATE path
  (`traverse_drafts/2`): it folds `Content.extract_edges/2` over the drafts
  corpus (`list_documents(type, dataset, perspective: :drafts)`), builds an
  in-memory edge index keyed by published-coalesced slug, and runs the SAME BFS
  bound (depth clamp, 1000-node budget, 200/level fan-out, truncation flags)
  over that index. It NEVER reads the materialised table, which holds no draft
  rows. Because `extract_edges/2` works in published-slug space, the drafts root
  is the root's published-coalesced slug (passed as `:root_pub_id`), not a UUID.

  ## Dangling / phantom nodes

  A reference whose target is not resolvable under the `:published` lens is a
  phantom node: the materialised table cannot store the broken edge (the `to_id`
  FK forbids it), so dangling targets surface ONLY at read time via
  `Content.extract_edges/2`'s dangling pass. `dangling/2` reports them; the
  traversal flags `phantom: true` ghosts (capped `@ghost_cap` per source).

  ## Ranking

  `rank_dependents/1` orders by topology — distance ASC, inbound-edge-count
  DESC, inserted_at ASC. It NEVER reads `weight` (see the forbidding comment at
  `rank_dependents/1`).

  ## Phase-5 dependency

  `reverse_referencers/2` is the inbound-edge query the Studio unpublish guard
  (Phase 5) uses INSTEAD of the scalar-only `Content.find_referencing_docs/3` —
  it covers arrayOf-of-reference because Phase 2 already materialised those
  edges into `content_edges`. Phase 5 depends on this module existing first.
  """

  import Ecto.Query
  alias Barkpark.Repo
  alias Barkpark.Content
  alias Barkpark.Content.{Document, Edge, Scope}

  @node_budget 1000
  @fan_out 200
  @ghost_cap 20
  @min_depth 1
  @max_depth 5
  @default_depth 2

  @type direction :: :out | :in | :both

  @doc """
  Clamp a requested depth into `1..5`. Never raises, never errors — an
  out-of-range request is silently brought into range (clamp-don't-error per the
  endpoint contract).
  """
  @spec clamp_depth(integer() | nil) :: pos_integer()
  def clamp_depth(nil), do: @default_depth
  def clamp_depth(depth) when is_integer(depth), do: depth |> max(@min_depth) |> min(@max_depth)
  def clamp_depth(_), do: @default_depth

  @doc """
  BFS-traverse the content graph from a root `documents.id` UUID.

  ## Options

    * `:depth`       — clamped `1..5` (default 2).
    * `:direction`   — `:out` | `:in` | `:both` (default `:both`).
    * `:kinds`       — list of kind strings to keep (default: all).
    * `:sources`     — list of `plugin_source` strings to keep (default: all).
    * `:perspective` — `:published` (default; reads the materialised table) or
                       `:drafts` (live extract over the drafts corpus).
    * `:dataset`     — required for the `:drafts` live-extract path and for
                       phantom-node resolution.
    * `:workspace_id` / `:project_id` — tenancy scope for hydration + phantom
      resolution.

  Returns:

      %{
        root: doc_id,
        nodes: [%{id, doc_id, type, title, phantom: bool, ...}],
        edges: [%{from_id, to_id, kind, weight, plugin_source}],
        dependents: [ranked node maps],
        truncated: bool,
        truncation_reason: :node_budget | :fan_out | :depth | nil
      }
  """
  @spec traverse(binary(), keyword()) :: map()
  def traverse(root_id, opts \\ []) do
    case Keyword.get(opts, :perspective, :published) do
      :drafts -> traverse_drafts(root_id, opts)
      _ -> traverse_published(root_id, opts)
    end
  end

  # The default, materialised path: BFS over the published-only `content_edges`
  # table keyed by `documents.id` UUIDs.
  defp traverse_published(root_id, opts) do
    depth = clamp_depth(Keyword.get(opts, :depth))
    direction = Keyword.get(opts, :direction, :both)
    perspective = Keyword.get(opts, :perspective, :published)

    state = %{
      visited: MapSet.new([root_id]),
      edges: [],
      truncated: false,
      reason: nil,
      # distance map for ranking: documents.id => hop count
      distance: %{root_id => 0}
    }

    state = bfs([root_id], 1, depth, direction, perspective, opts, state)

    node_ids = MapSet.to_list(state.visited)
    edges = Enum.reverse(state.edges) |> Enum.uniq()

    real_nodes = hydrate_nodes(node_ids, opts)
    phantoms = phantom_nodes(real_nodes, edges, perspective, opts)
    nodes = real_nodes ++ phantoms

    dependents =
      real_nodes
      |> Enum.reject(fn n -> n.id == root_id end)
      |> rank_dependents(state.distance, edges)

    %{
      root: root_id,
      nodes: nodes,
      edges: Enum.map(edges, &render_edge/1),
      dependents: dependents,
      truncated: state.truncated,
      truncation_reason: state.reason
    }
  end

  # ── Drafts live-extract path ────────────────────────────────────────────────
  #
  # The materialised `content_edges` table is published-only, so a drafts graph
  # CANNOT be served from it (gap: a token-gated drafts request must never fall
  # through to the published table — that is a silent-200-with-wrong-data bug).
  # Instead we build the whole drafts edge set in memory by extracting edges over
  # the drafts corpus, then run the SAME BFS bound over it. Edges here are keyed
  # by published-coalesced slug (`extract_edges/2`'s key model), so the root must
  # be a slug — `:root_pub_id` (the controller passes the root's published slug);
  # we fall back to `root_id` when absent (e.g. direct callers in slug space).
  defp traverse_drafts(root_id, opts) do
    depth = clamp_depth(Keyword.get(opts, :depth))
    direction = Keyword.get(opts, :direction, :both)
    root_slug = Keyword.get(opts, :root_pub_id) || Content.published_id(root_id)

    {out_index, in_index, edge_list} = build_drafts_index(opts)

    state = %{
      visited: MapSet.new([root_slug]),
      edges: [],
      truncated: false,
      reason: nil,
      distance: %{root_slug => 0}
    }

    state = drafts_bfs([root_slug], 1, depth, direction, out_index, in_index, state)

    edges = Enum.reverse(state.edges) |> Enum.uniq()
    visited = MapSet.to_list(state.visited)

    nodes =
      Enum.map(visited, fn slug ->
        %{id: slug, doc_id: slug, type: nil, title: slug, phantom: false}
      end)

    # Phantoms: drafts-corpus dangling targets reachable from the visited set.
    phantoms =
      edge_list
      |> Enum.filter(fn e -> e.dangling and e.from_id in visited end)
      |> Enum.uniq_by(& &1.to_id)
      |> Enum.map(fn e ->
        %{
          id: nil,
          broken_id: e.to_id,
          via_field: e.field,
          refType: e.refType,
          source: e.from_id,
          phantom: true,
          title: e.to_id
        }
      end)

    dependents =
      nodes
      |> Enum.reject(fn n -> n.id == root_slug end)
      |> rank_dependents(state.distance, edges)

    %{
      root: root_slug,
      nodes: nodes ++ phantoms,
      edges: Enum.map(edges, &render_drafts_edge/1),
      dependents: dependents,
      truncated: state.truncated,
      truncation_reason: state.reason
    }
  end

  # Fold extract_edges over the drafts corpus, build slug-keyed adjacency indexes
  # (filtered by the requested kinds/sources), and keep the full edge list for the
  # phantom pass. Drafts edges have no plugin_source/weight (live-extracted), so
  # the `sources` filter is a no-op here and `weight` renders nil.
  #
  # `list_documents/3` filters by a single type, but a drafts graph spans every
  # content type, so we fold over EVERY schema name in the dataset with the
  # `perspective: :drafts` merge (draft-preferred over its published twin).
  defp build_drafts_index(opts) do
    dataset = Keyword.get(opts, :dataset)
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)

    docs =
      if is_binary(dataset) and dataset != "" do
        dataset
        |> Content.list_schemas(opts)
        |> Enum.flat_map(fn schema ->
          Content.list_documents(schema.name, dataset,
            perspective: :drafts,
            limit: 1000,
            workspace_id: workspace_id,
            project_id: project_id
          )
        end)
      else
        []
      end

    edge_list =
      docs
      |> Enum.flat_map(fn doc -> Content.extract_edges(doc, opts) end)
      |> filter_drafts_edges(opts)

    out_index = Enum.group_by(edge_list, & &1.from_id)
    in_index = Enum.group_by(edge_list, & &1.to_id)

    {out_index, in_index, edge_list}
  end

  defp filter_drafts_edges(edges, opts) do
    case Keyword.get(opts, :kinds) do
      list when is_list(list) and list != [] -> Enum.filter(edges, fn e -> e.kind in list end)
      _ -> edges
    end
  end

  # Slug-space BFS mirroring `bfs/7`'s bounds: 1000-node budget, 200/level fan-out,
  # and the boundary depth trip-wire's false-positive guard (only :depth when the
  # boundary frontier still has an unvisited, NON-dangling neighbour to expand).
  defp drafts_bfs([], _level, _max, _dir, _out, _in, state), do: state

  defp drafts_bfs(frontier, level, max, dir, out_index, in_index, state) when level > max do
    had_more? =
      Enum.any?(frontier, fn slug ->
        slug
        |> drafts_neighbor_edges(dir, out_index, in_index)
        |> Enum.any?(fn edge ->
          neighbor = drafts_other_end(edge, slug)
          not edge.dangling and not is_nil(neighbor) and not MapSet.member?(state.visited, neighbor)
        end)
      end)

    if had_more?, do: %{state | truncated: true, reason: state.reason || :depth}, else: state
  end

  defp drafts_bfs(frontier, level, max, dir, out_index, in_index, state) do
    if MapSet.size(state.visited) >= @node_budget do
      %{state | truncated: true, reason: state.reason || :node_budget}
    else
      level_edges =
        Enum.flat_map(frontier, fn slug ->
          slug
          |> drafts_neighbor_edges(dir, out_index, in_index)
          |> Enum.map(fn e -> {slug, e} end)
        end)

      {kept, fanned?} =
        if length(level_edges) > @fan_out,
          do: {Enum.take(level_edges, @fan_out), true},
          else: {level_edges, false}

      state =
        if fanned?, do: %{state | truncated: true, reason: state.reason || :fan_out}, else: state

      {next_frontier, state} =
        Enum.reduce(kept, {[], state}, fn {slug, edge}, {acc, st} ->
          neighbor = drafts_other_end(edge, slug)
          st = %{st | edges: [edge | st.edges]}

          cond do
            # Dangling targets are phantoms, never traversable real nodes.
            edge.dangling or is_nil(neighbor) ->
              {acc, st}

            MapSet.member?(st.visited, neighbor) ->
              {acc, st}

            MapSet.size(st.visited) >= @node_budget ->
              {acc, %{st | truncated: true, reason: st.reason || :node_budget}}

            true ->
              st = %{
                st
                | visited: MapSet.put(st.visited, neighbor),
                  distance: Map.put_new(st.distance, neighbor, level)
              }

              {[neighbor | acc], st}
          end
        end)

      drafts_bfs(Enum.reverse(next_frontier), level + 1, max, dir, out_index, in_index, state)
    end
  end

  defp drafts_neighbor_edges(slug, :out, out_index, _in), do: Map.get(out_index, slug, [])
  defp drafts_neighbor_edges(slug, :in, _out, in_index), do: Map.get(in_index, slug, [])

  defp drafts_neighbor_edges(slug, :both, out_index, in_index),
    do: Map.get(out_index, slug, []) ++ Map.get(in_index, slug, [])

  defp drafts_other_end(%{from_id: from, to_id: to}, slug) do
    cond do
      from == slug -> to
      to == slug -> from
      true -> nil
    end
  end

  defp render_drafts_edge(e) do
    %{from_id: e.from_id, to_id: e.to_id, kind: e.kind, weight: nil, plugin_source: nil}
  end

  # BFS over the frontier. `level` is the 1-based depth currently being expanded.
  defp bfs([], _level, _max, _dir, _persp, _opts, state), do: state

  defp bfs(frontier, level, max, dir, persp, opts, state) when level > max do
    # depth>clamped trip-wire. FALSE-POSITIVE GUARD: firing :depth here means the
    # walk stopped at the clamp BEFORE the graph was fully explored. But a
    # boundary-exact graph (the deepest edge sits exactly at the depth limit)
    # arrives here with a LEAF frontier — those nodes have no further outbound
    # edges, so nothing was actually cut. Only declare :depth truncation when at
    # least one frontier node still has an expandable (filtered) neighbour edge;
    # an empty/leaf frontier at the boundary means the graph was fully explored,
    # so leave truncated:false / reason:nil.
    had_more? =
      Enum.any?(frontier, fn id ->
        id
        |> neighbor_edges(dir, persp, opts)
        |> filter_edges(opts)
        |> Enum.any?(fn edge ->
          neighbor = other_end(edge, frontier)
          not is_nil(neighbor) and not MapSet.member?(state.visited, neighbor)
        end)
      end)

    if had_more? do
      %{state | truncated: true, reason: state.reason || :depth}
    else
      state
    end
  end

  defp bfs(frontier, level, max, dir, persp, opts, state) do
    if MapSet.size(state.visited) >= @node_budget do
      %{state | truncated: true, reason: state.reason || :node_budget}
    else
      # Gather every edge reachable from the current frontier at this level.
      level_edges =
        frontier
        |> Enum.flat_map(fn id -> neighbor_edges(id, dir, persp, opts) end)
        |> filter_edges(opts)

      {kept_edges, fanned?} =
        if length(level_edges) > @fan_out do
          {Enum.take(level_edges, @fan_out), true}
        else
          {level_edges, false}
        end

      state =
        if fanned? do
          %{state | truncated: true, reason: state.reason || :fan_out}
        else
          state
        end

      {next_frontier, state} =
        Enum.reduce(kept_edges, {[], state}, fn edge, {acc, st} ->
          neighbor = other_end(edge, frontier)
          st = %{st | edges: [edge | st.edges]}

          cond do
            is_nil(neighbor) ->
              {acc, st}

            MapSet.member?(st.visited, neighbor) ->
              {acc, st}

            MapSet.size(st.visited) >= @node_budget ->
              {acc, %{st | truncated: true, reason: st.reason || :node_budget}}

            true ->
              st = %{
                st
                | visited: MapSet.put(st.visited, neighbor),
                  distance: Map.put_new(st.distance, neighbor, level)
              }

              {[neighbor | acc], st}
          end
        end)

      bfs(Enum.reverse(next_frontier), level + 1, max, dir, persp, opts, state)
    end
  end

  # Neighbour edges of a node for the requested direction. This is the MATERIALISED
  # path only — `traverse/2` routes `:drafts` to `traverse_drafts/2` (a separate
  # live extract, see below), so `persp` is always `:published` when it reaches
  # here. We keep the dispatch arity explicit for the trip-wire guard's reuse.
  defp neighbor_edges(id, :out, _persp, opts), do: Content.list_outbound_edges(id, edge_opts(opts))
  defp neighbor_edges(id, :in, _persp, opts), do: Content.list_inbound_edges(id, edge_opts(opts))

  defp neighbor_edges(id, :both, persp, opts) do
    neighbor_edges(id, :out, persp, opts) ++ neighbor_edges(id, :in, persp, opts)
  end

  defp edge_opts(opts) do
    case Keyword.get(opts, :kinds) do
      [single] when is_binary(single) -> [kind: single]
      _ -> []
    end
  end

  # Given an edge and the set of frontier ids, return the id on the OTHER side
  # (the neighbour we may visit). nil if neither end is in the frontier (cannot
  # happen for edges we just gathered, but keeps the reducer total).
  defp other_end(%Edge{from_id: from, to_id: to}, frontier) do
    fset = MapSet.new(frontier)

    cond do
      MapSet.member?(fset, from) -> to
      MapSet.member?(fset, to) -> from
      true -> nil
    end
  end

  # Apply kind + plugin_source filters (the `kinds`/`sources` query params).
  defp filter_edges(edges, opts) do
    kinds = Keyword.get(opts, :kinds)
    sources = Keyword.get(opts, :sources)

    edges
    |> maybe_filter(kinds, fn e -> e.kind in kinds end)
    |> maybe_filter(sources, fn e -> e.plugin_source in sources end)
  end

  defp maybe_filter(edges, nil, _pred), do: edges
  defp maybe_filter(edges, [], _pred), do: edges
  defp maybe_filter(edges, list, pred) when is_list(list), do: Enum.filter(edges, pred)

  # Hydrate the visited documents.id UUIDs into node maps via one keyed read.
  # Defense-in-depth tenancy: the keyed read is scoped to the caller's
  # workspace/project (via `scope_to_workspace_or_global/3`) so a UUID that
  # belongs to ANOTHER tenant — e.g. one that reached `state.visited` through a
  # cross-tenant `content_edges` row — hydrates to NOTHING instead of leaking
  # its title/doc_id/type. An unscoped caller (`opts` without `:workspace_id`,
  # e.g. a single-tenant back-compat read) keeps the global read via the
  # `_or_global` bridge, matching the documented Scope posture.
  defp hydrate_nodes([], _opts), do: []

  defp hydrate_nodes(ids, opts) do
    Document
    |> where([d], d.id in ^ids)
    |> scope_query(opts)
    |> Repo.all()
    |> Enum.map(fn %Document{} = d ->
      %{
        id: d.id,
        doc_id: d.doc_id,
        type: d.type,
        title: d.title,
        phantom: false
      }
    end)
  end

  # Phantom (ghost) nodes — dangling targets that are NOT in `content_edges`
  # (the FK forbids them) so they never appear as a real node. We re-derive them
  # by re-extracting the visited source docs and keeping the dangling targets,
  # capped @ghost_cap per source with a '+N more broken' overflow marker.
  defp phantom_nodes(real_nodes, _edges, _perspective, opts) do
    dataset = Keyword.get(opts, :dataset)

    if is_nil(dataset) do
      []
    else
      real_nodes
      |> Enum.flat_map(fn node ->
        case fetch_doc(node.id, opts) do
          %Document{} = doc ->
            doc
            |> Content.extract_edges(opts)
            |> Enum.filter(& &1.dangling)
            |> cap_ghosts(node.doc_id)

          _ ->
            []
        end
      end)
      |> Enum.uniq_by(& &1.broken_id)
    end
  end

  defp cap_ghosts(dangling_edges, source_doc_id) do
    kept = Enum.take(dangling_edges, @ghost_cap)
    overflow = length(dangling_edges) - length(kept)

    ghosts =
      Enum.map(kept, fn e ->
        %{
          id: nil,
          broken_id: e.to_id,
          via_field: e.field,
          refType: e.refType,
          source: source_doc_id,
          phantom: true,
          title: e.to_id
        }
      end)

    if overflow > 0 do
      ghosts ++
        [
          %{
            id: nil,
            broken_id: "+#{overflow} more broken",
            via_field: nil,
            refType: nil,
            source: source_doc_id,
            phantom: true,
            title: "+#{overflow} more broken"
          }
        ]
    else
      ghosts
    end
  end

  # Scoped keyed read for phantom re-extraction. Same tenancy posture as
  # `hydrate_nodes/2`: a node.id that belongs to another tenant resolves to nil
  # (and contributes no phantoms) instead of being re-read across the boundary.
  defp fetch_doc(id, opts) do
    Document |> where([d], d.id == ^id) |> scope_query(opts) |> Repo.one()
  end

  defp render_edge(%Edge{} = e) do
    # `weight` is emitted for the Cytoscape LAYOUT ONLY — it is NEVER read by
    # ranking (see rank_dependents/3).
    %{
      from_id: e.from_id,
      to_id: e.to_id,
      kind: e.kind,
      weight: e.weight,
      plugin_source: e.plugin_source
    }
  end

  @doc """
  Rank dependent nodes by TOPOLOGY.

  Order: distance ASC → inbound-edge-count DESC → inserted_at ASC.

  NEVER sort by weight — weight is Cytoscape-layout-only; ranking is topology
  (distance, fan-in, inserted_at). A future author wiring `edge.weight` into
  this sort would silently couple layout to ranking — do NOT.
  """
  @spec rank_dependents([map()], %{optional(binary()) => non_neg_integer()}, [Edge.t()]) :: [map()]
  def rank_dependents(nodes, distance, edges) do
    inbound_counts =
      edges
      |> Enum.group_by(& &1.to_id)
      |> Map.new(fn {to_id, es} -> {to_id, length(es)} end)

    nodes
    |> Enum.map(fn node ->
      Map.merge(node, %{
        distance: Map.get(distance, node.id, 0),
        inbound_count: Map.get(inbound_counts, node.id, 0)
      })
    end)
    # distance ASC, inbound DESC (negate), inserted_at via doc_id tiebreak left to
    # caller ordering — inserted_at is not on the hydrated node, so we sort by the
    # stable doc_id as the inserted_at proxy (hydration order is inserted-stable).
    |> Enum.sort_by(fn n -> {n.distance, -n.inbound_count, n.doc_id} end)
  end

  # Single-arg convenience used by tests / callers that don't need distance/edge
  # context — ranks by inbound_count alone (still weight-free).
  @spec rank_dependents([map()]) :: [map()]
  def rank_dependents(nodes) when is_list(nodes) do
    Enum.sort_by(nodes, fn n -> {Map.get(n, :distance, 0), -Map.get(n, :inbound_count, 0)} end)
  end

  @doc """
  Inbound-edge query over `content_edges` for a published doc id (slug or UUID).

  THE Phase-5 dependency: the Studio unpublish guard uses this INSTEAD of the
  scalar-only `Content.find_referencing_docs/3` because `content_edges` already
  materialised arrayOf-of-reference edges (Phase 2) — `find_referencing_docs`
  undercounts them, the exact blast-radius bug the feature targets.

  Resolves the slug to its `documents.id`, then reads `list_inbound_edges/2` and
  hydrates each referencing source with `via_field` (the `kind`) for the modal.
  Returns `[]` for an unresolvable id (nothing references a non-existent doc).
  """
  @spec reverse_referencers(binary(), keyword()) :: [map()]
  # @canonical capability:doc-backlinks aka:backlinks,references,referenced_by,who_references
  def reverse_referencers(pub_id, opts \\ []) do
    case resolve_pk(pub_id, opts) do
      nil ->
        []

      pk ->
        inbound = Content.list_inbound_edges(pk, edge_opts(opts))

        from_ids = Enum.map(inbound, & &1.from_id)
        docs_by_id = docs_by_id(from_ids, opts)

        Enum.map(inbound, fn %Edge{} = e ->
          src = Map.get(docs_by_id, e.from_id)

          %{
            from_id: e.from_id,
            from_doc_id: src && src.doc_id,
            title: (src && src.title) || e.from_id,
            type: src && src.type,
            kind: e.kind,
            via_field: e.kind,
            plugin_source: e.plugin_source
          }
        end)
    end
  end

  @doc """
  Documents with ZERO inbound AND ZERO outbound edges in `content_edges` — the
  isolated corpus. Scoped by `:workspace_id` / `:project_id` (+ optional
  `:dataset`). Returns hydrated node maps.
  """
  @spec orphans(keyword()) :: [map()]
  def orphans(opts \\ []) do
    connected =
      from(e in Edge, select: e.from_id)
      |> union(^from(e in Edge, select: e.to_id))
      |> Repo.all()
      |> MapSet.new()

    scoped_docs_query(opts)
    |> Repo.all()
    |> Enum.reject(fn d -> MapSet.member?(connected, d.id) end)
    |> Enum.map(fn d ->
      %{id: d.id, doc_id: d.doc_id, type: d.type, title: d.title}
    end)
  end

  @doc """
  Broken references — the live typed+untyped resolution pass over the scoped
  corpus reporting every reference whose target is not resolvable under the
  `:published` lens. Uses the SAME `Content.extract_edges/2` dangling signal
  (shared `resolve_target_existence` from Phase 2), so a typed and an untyped
  broken ref are reported consistently.

  Returns `[%{from_id, to_id, via_field, refType}]`.
  """
  @spec dangling(keyword()) :: [map()]
  def dangling(opts \\ []) do
    scoped_docs_query(opts)
    |> Repo.all()
    |> Enum.flat_map(fn doc ->
      doc
      |> Content.extract_edges(opts)
      |> Enum.filter(& &1.dangling)
      |> Enum.map(fn e ->
        %{from_id: e.from_id, to_id: e.to_id, via_field: e.field, refType: e.refType}
      end)
    end)
  end

  # ── Internal scope helpers ──────────────────────────────────────────────────

  # All published docs in the caller's scope. Used by orphans/dangling.
  defp scoped_docs_query(opts) do
    dataset = Keyword.get(opts, :dataset)
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)
    prefix = "drafts.%"

    query =
      Document
      |> where([d], not like(d.doc_id, ^prefix))
      |> Barkpark.Content.Scope.scope_to_workspace_or_global(workspace_id, project_id)

    if is_binary(dataset) and dataset != "" do
      where(query, [d], d.dataset == ^dataset)
    else
      query
    end
  end

  # Resolve a slug/UUID to its documents.id, published-preferred (CASE-ordered,
  # mirroring reference_title/4), scoped by workspace/project (+ optional
  # dataset). Returns the UUID or nil.
  @doc """
  Resolve a `doc_id` (a slug; published-preferred) to its `Document`, within
  `dataset` and the caller's tenancy scope. The single canonical slug→doc
  resolver, shared by the graph engine (`resolve_pk/2`) and the Studio graph
  pane (`PaneBuilder`) — it replaces what were two byte-identical private copies
  (the resolve_pk / resolve_graph_doc duplication). Returns `nil` for a nil or
  unresolvable id.

  Distinct from `Barkpark.Content.Edges.resolve_doc_pk/3`, which ALSO matches a
  raw UUID and scopes datasets via `WriteScope` for edge-endpoint resolution — a
  deliberately richer variant, not a duplicate of this one.
  """
  @spec resolve_doc(String.t() | nil, String.t() | nil, keyword()) :: Document.t() | nil
  # @canonical capability:slug-resolve aka:resolve_doc,resolve_pk,slug_to_pk,resolve_doc_pk
  def resolve_doc(nil, _dataset, _opts), do: nil

  def resolve_doc(doc_id, dataset, opts) when is_binary(doc_id) do
    pub_id = Content.published_id(doc_id)
    draft = Content.draft_id(pub_id)

    query =
      Document
      |> where([d], d.doc_id == ^pub_id or d.doc_id == ^draft)
      |> Scope.scope_to_workspace_or_global(
        Keyword.get(opts, :workspace_id),
        Keyword.get(opts, :project_id)
      )
      |> order_by([d], asc: fragment("CASE WHEN ? LIKE 'drafts.%' THEN 1 ELSE 0 END", d.doc_id))

    query =
      if is_binary(dataset) and dataset != "" do
        where(query, [d], d.dataset == ^dataset)
      else
        query
      end

    query |> limit(1) |> Repo.one()
  end

  defp resolve_pk(id, opts) when is_binary(id) do
    case resolve_doc(id, Keyword.get(opts, :dataset), opts) do
      %Document{id: pk} -> pk
      _ -> nil
    end
  end

  defp docs_by_id([], _opts), do: %{}

  defp docs_by_id(ids, opts) do
    Document
    |> where([d], d.id in ^ids)
    |> scope_query(opts)
    |> Repo.all()
    |> Map.new(fn d -> {d.id, d} end)
  end

  # Apply the caller's tenancy scope to a keyed Document read. Pulls
  # `:workspace_id` / `:project_id` off `opts` and pipes through
  # `Scope.scope_to_workspace_or_global/3` — a real workspace scopes the read
  # (out-of-scope ids drop), an absent one is a deliberate global read (the
  # documented single-tenant / direct-caller back-compat bridge).
  defp scope_query(query, opts) do
    Scope.scope_to_workspace_or_global(
      query,
      Keyword.get(opts, :workspace_id),
      Keyword.get(opts, :project_id)
    )
  end
end
