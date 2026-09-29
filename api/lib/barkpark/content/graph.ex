defmodule Barkpark.Content.Graph do
  @moduledoc """
  The content-graph BFS engine (Goal `ges/graph-edge-seam`, Phase 4).

  Walks the materialised `content_edges` table from a root document, bounded by
  three trip-wires, and returns a node/edge payload the Studio Canvas2D graph
  pane (Phase 5, bp-graph.js) and the `/v1/graph/*` HTTP surface consume.

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

  A FOURTH condition exists on the `:drafts` path only, and it is not a BFS
  bound at all — the CORPUS READ under `build_drafts_index/1` can itself stop
  at `corpus_limit/0`. It reports as `truncation_reason: :corpus_cap` and is
  detailed by `corpus_truncation` (see below), because a capped corpus is a
  categorically different defect from a capped walk: it makes the index a
  PREFIX, which used to render real references as `dangling` phantoms.

  `depth` is CLAMPed to `1..5` (clamp, never 4xx). The response ALWAYS carries
  `truncated` (bool) + `truncation_reason` (atom | nil) + `corpus_truncation`
  (map | nil).

  ## `corpus_truncation` — the payload half of the corpus bound

  `nil` on every complete read (and on the whole `:published` path, which has
  no corpus read). When the drafts corpus read capped:

      %{truncated: true, limit: <corpus_limit/0>, read: <docs actually folded>}

  It exists so a consumer can tell a PHANTOM REFERENCE (a target that really
  is not there) from an UNREAD one (a target past the bound). Before it, the
  two were the same `dangling` edge and the truncation was reported as a
  broken link — a wrong diagnosis, not merely an incomplete one.

  ## Perspective

  Default `:published` — the materialised `content_edges` table is
  published-only (Phase 3) and `traverse_published/2` walks it keyed by
  `documents.id` UUIDs.

  `:drafts` is a token-gated HYBRID handled by a SEPARATE path
  (`traverse_drafts/2`).

  IT USED TO SAY: "it NEVER reads the materialised table, which holds no draft
  rows." THAT SENTENCE IS RETIRED, and here is the reason, because a contract
  should not change in silence.

  The drafts path folded `Content.extract_edges/2` PLUS the plugin
  `resolve_extract_edges` chain over the WHOLE dataset corpus on every request.
  On guerrilla that is 8,597 tasks (~9.5 KB each) and 1,048 papers (~62 KB
  each): ~150 MB of `content` jsonb read, shipped, JSON-decoded and recursively
  walked, per request, for a depth-2 graph. Measured live: 18.4 s, then 11.8 s
  after the read was reshaped (task `graph-endpoint-latency`). A projection
  cannot rescue it — `Plugins.Bulldocs.extract_edges/2` walks the whole content
  with no type guard, so the bytes are load-bearing and dropping them buys
  1.7x, not the 12x needed.

  What IS true is that only 8.4% of those documents have a `drafts.` twin. So
  the drafts graph now reads:

    * **live, with content** — the documents whose edges cannot be in
      `content_edges`: every `drafts.` twin (the table is published-only), plus
      every document written inside the PROJECTOR-LAG WINDOW
      (`projection_lag_window_s/0` — projection is async and debounced, and
      nothing records per-document projection state);
    * **materialised** — every other source's edges, straight from
      `content_edges`, the same indexed table `traverse_published/2` walks;
    * **slugs only, no content** — the whole corpus's ids, for the phantom
      membership lens (56 ms instead of 810 ms over 9,646 documents).

  Edges are keyed by published-coalesced slug (`extract_edges/2`'s key model),
  so the drafts root is the root's published-coalesced slug (passed as
  `:root_pub_id`), not a UUID, and the SAME BFS bound runs over the union.

  TWO CONSEQUENCES A READER MUST KNOW:

    1. A published-only document's edges are now as fresh as the projector,
      not as fresh as the request. `traverse_published/2` has always had that
      tolerance; the drafts path did not, and now shares it, bounded by the lag
      window above.
    2. `content_edges` CANNOT hold a dangling edge (`Content.Edge`: the `to_id`
      FK forbids it), so phantoms are recovered separately — see
      `recover_visited_dangling/4`, which re-extracts the ≤ `@node_budget`
      documents the walk VISITED. Keyed on visited, never on twin status.

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

  require Logger

  # The drafts fold holds the whole corpus in memory to build its adjacency
  # indexes, so the read is bounded on purpose: 20,000 documents for the WHOLE
  # dataset — the same budget the per-type OFFSET walk this replaces carried
  # (page_size 1000 x max_pages 20), now applied ONCE across every type rather
  # than to each type separately. That is a strictly TIGHTER memory bound: the
  # old shape let a five-type dataset materialise 100,000 documents into the
  # BEAM before any bound fired. Overridable per call via :corpus_limit and
  # config-overridable (:graph_drafts_corpus_limit) for tests, the same escape
  # hatch `corpus_scan_limit/0` has and for the same reason.
  @corpus_limit 20_000

  # THE PROJECTOR-LAG WINDOW. Every document written inside it joins the
  # live-extract set, because `content_edges` may not have caught up. Derived
  # from `Barkpark.EdgeProjector.ProjectorWorker`, not guessed: `schedule_in:
  # 5` seconds of debounce, `unique: [period: 30]` across
  # `:available`/`:scheduled`/`:executing` (a save inside that window rides an
  # already-scheduled job that may predate it), a concurrency-2 queue, and a
  # default REBUILD op under a `timeout: 60_000` transaction — ~95 s before the
  # queue backlog term, which on a write-hot board is the one that moves. 120 s
  # is that derivation plus headroom. Config-overridable
  # (`:barkpark, :graph_projection_lag_window_s`) for TESTS ONLY.
  @projection_lag_window_s 120

  # Bound on the MATERIALISED arm — the `content_edges` read that replaces
  # live-extracting the published-only corpus. Five times `@node_budget`, the
  # same ratio `@corpus_scan_limit` takes to it, so the edge set the walk draws
  # from stays strictly more generous than the walk it feeds.
  @materialised_edge_limit 50_000

  # Bound on the WHOLE-CORPUS scans behind `/v1/graph/orphans` and
  # `/v1/graph/dangling`. Both used to be unbounded `Repo.all/1`s over every
  # published document in scope, and `dangling/1` then paid a per-document
  # reference-resolution fold on top — so a large tenant's click materialised
  # the entire corpus into the BEAM. Five times the traversal `@node_budget`,
  # so the derived surfaces stay strictly more generous than the graph walk
  # they summarise, and small enough that a runaway dataset truncates instead
  # of exhausting the node.
  @corpus_scan_limit 5_000

  @doc """
  The derived-corpus scan bound (`orphans_bounded/1` / `dangling_bounded/1`).

  Config-overridable (`:barkpark, :graph_corpus_scan_limit`) for TESTS ONLY —
  the same escape hatch `/v1/graph`'s node budget has, and for the same reason:
  a bound whose only proof needs 5,001 fixture rows is a bound nobody tests.
  """
  @spec corpus_scan_limit() :: pos_integer()
  def corpus_scan_limit,
    do: Application.get_env(:barkpark, :graph_corpus_scan_limit, @corpus_scan_limit)

  @doc """
  The whole-corpus bound the drafts fold reads under
  (`build_drafts_index/1`). Config-overridable
  (`:barkpark, :graph_drafts_corpus_limit`) for TESTS ONLY — a bound whose only
  proof needs 20,001 fixture rows is a bound nobody tests.
  """
  @spec corpus_limit() :: pos_integer()
  def corpus_limit,
    do: Application.get_env(:barkpark, :graph_drafts_corpus_limit, @corpus_limit)

  @doc """
  The projector-lag window in SECONDS (`build_drafts_index/1`). Every document
  written inside it is live-extracted regardless of whether it has a draft
  twin. Config-overridable (`:barkpark, :graph_projection_lag_window_s`) for
  TESTS ONLY — a window whose only proof needs a two-minute sleep is a window
  nobody tests.
  """
  @spec projection_lag_window_s() :: non_neg_integer()
  def projection_lag_window_s,
    do: Application.get_env(:barkpark, :graph_projection_lag_window_s, @projection_lag_window_s)

  @doc """
  The bound on the materialised `content_edges` read behind the drafts graph.
  Config-overridable (`:barkpark, :graph_materialised_edge_limit`) for TESTS.
  """
  @spec materialised_edge_limit() :: pos_integer()
  def materialised_edge_limit,
    do: Application.get_env(:barkpark, :graph_materialised_edge_limit, @materialised_edge_limit)

  alias Barkpark.Repo
  alias Barkpark.Content
  alias Barkpark.Content.{Document, DraftId, Edge, Scope}

  # The INVERTED plugin edge-extractor seam. The kernel (`content`) must hold no
  # compile-time reference to a feature concept, and `Barkpark.Plugins.Registry`
  # is one — so the drafts fold no longer calls the registry. Instead the
  # composition root (`Barkpark.Application.start/2`, the ONE installer) hands
  # the fan-out DOWN into this key, and `collect_plugin_edges/2` only reads it.
  @edge_extractor_collector_key :edge_extractor_collector

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
  The traversal node budget (#{@node_budget}). Exposed so graph-DERIVED list
  surfaces (e.g. `Barkpark.Tasks.Expectations.driven_tasks/2`) bound
  themselves with the engine's OWN ceiling instead of inventing a second
  constant that could drift.
  """
  @spec node_budget() :: pos_integer()
  def node_budget, do: @node_budget

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
        truncation_reason: :node_budget | :fan_out | :depth | :corpus_cap | nil,
        corpus_truncation: nil | %{truncated: true, limit: pos_integer, read: non_neg_integer}
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
    all_edges = Enum.reverse(state.edges) |> Enum.uniq()

    # Hydrate ONCE and KEEP the structs: `phantom_nodes/4` used to re-read every
    # one of these rows through a keyed `Repo.one` per traversed
    # node, up to @node_budget of them) because hydration discarded the struct
    # and handed on only the rendered node map.
    hydrated_docs = hydrate_docs(node_ids, opts)
    real_nodes = Enum.map(hydrated_docs, &node_map/1)

    # Owner/tenancy ACL on the EDGE list (MEDIUM-5, edge-half). The BFS crosses
    # ownership boundaries freely (no per-node ACL inside `bfs/7`), and node
    # hydration drops an owner_scoped node owned by another user — but the raw
    # edge list still references that hidden node's `documents.id` UUID, leaking
    # its existence + internal id + subgraph topology to a non-owner. Drop any
    # edge whose endpoint did NOT survive hydration, mirroring
    # `reverse_referencers/2`'s "drop the unhydrated source" posture so the edge
    # list can never out a node the node list hides.
    surviving_ids = MapSet.new(real_nodes, & &1.id)

    edges =
      Enum.filter(all_edges, fn %Edge{from_id: from, to_id: to} ->
        MapSet.member?(surviving_ids, from) and MapSet.member?(surviving_ids, to)
      end)

    phantoms = phantom_nodes(hydrated_docs, edges, perspective, opts)
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
      truncation_reason: state.reason,
      # The published path reads the materialised `content_edges` table, never
      # a corpus, so it has no corpus bound to report. Stated, not omitted: the
      # key is present on EVERY graph response so a consumer never has to read
      # its absence as "complete".
      corpus_truncation: nil
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

    {out_index, in_index, edge_list, corpus_truncation} = build_drafts_index(opts)

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

    # PHANTOM RECOVERY. Under the hybrid a published-only document's dangling
    # out-edge is in NO table (`content_edges` cannot hold one), so it is
    # re-extracted from the ≤ `@node_budget` documents the walk actually
    # visited. See `recover_visited_dangling/4` for why doing this AFTER the
    # walk is exact rather than merely convenient.
    already_seen =
      MapSet.new(edge_list, fn e -> {e.from_id, e.to_id, e.kind} end)

    recovered =
      recover_visited_dangling(visited, already_seen, Keyword.get(opts, :dataset), opts)

    dangling_edges =
      edge_list
      |> Enum.filter(fn e -> e.dangling and e.from_id in visited end)
      |> Kernel.++(recovered)

    # The recovered edges never reached `state.edges` (they were not in the
    # index the BFS walked), so they are appended to the rendered edge list —
    # the payload must show the broken reference, not only its phantom node.
    edges = edges ++ Enum.reject(recovered, fn e -> e in edges end)

    phantoms =
      dangling_edges
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
      # A capped corpus truncates the graph just as surely as a BFS bound does,
      # so it flips the SAME flag — a consumer that only reads `truncated` is
      # not lied to. `truncation_reason` keeps whichever bound the BFS hit (a
      # walk that also blew its node budget is still a node-budget walk); when
      # the walk itself was complete, `:corpus_cap` is the reason.
      truncated: state.truncated or corpus_truncation != nil,
      truncation_reason: state.reason || if(corpus_truncation != nil, do: :corpus_cap, else: nil),
      corpus_truncation: corpus_truncation
    }
  end

  # Fold the FULL edge extraction — core `extract_edges/2` PLUS the plugin
  # `resolve_extract_edges` chain (lvw-t12 / wire §7(2)) — over the drafts
  # corpus, build slug-keyed adjacency indexes (filtered by the requested
  # kinds/sources), and keep the full edge list for the phantom pass. Plugin
  # edges carry their `plugin_source` (e.g. "bulldocs"); core live-extracted
  # edges carry nil — matching their materialised rows, whose plugin_source
  # column is NULL. `weight` renders nil for every live-extracted edge.
  #
  # `list_documents/3` filters by a single type, but a drafts graph spans every
  # content type, so we fold over EVERY schema name in the dataset with the
  # `perspective: :drafts` merge (draft-preferred over its published twin).
  defp build_drafts_index(opts) do
    dataset = Keyword.get(opts, :dataset)
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)

    # THE SCHEMA LIST IS HOISTED, ONCE (task-051a87de9a085e4d). It is invariant
    # across the whole fold, and `Content.Edges.extract_edges/2` reads it
    # `Keyword.get_lazy(:schemas, fn -> Content.list_schemas(dataset, opts) end)`
    # — so WITHOUT this prefetch the fold issued ONE schema query PER DOCUMENT.
    # That is the cost `extract_edges/2`'s own doc names ("a 4096-document
    # corpus issued 4096 identical schema queries … measured live: a 34s first
    # paint") and the one `corpus_edges/3` already hoists on the published side.
    # Here it was the difference between a bounded read and a request that never
    # returned on guerrilla: the drafts fold walks the WHOLE dataset corpus on
    # every `?drafts=true` call, so its per-document round-trips are unbounded
    # by depth, by `@node_budget` and by `@fan_out` alike — every bound the
    # drafts walk owns sits DOWNSTREAM of this fold.
    #
    # Prefetching cannot change what any document extracts: every doc in the
    # fold comes from THIS dataset (the `collect_all_documents(schema.name,
    # dataset, …)` reads below), so the list handed down is byte-identical to
    # the one each per-document call would have read for itself.
    schemas =
      if is_binary(dataset) and dataset != "", do: Content.list_schemas(dataset, opts), else: []

    # ── THE HYBRID READ (task graph-endpoint-latency) ──────────────────────
    #
    # This used to read EVERY document of EVERY type and extract its edges. On
    # guerrilla that is 8,597 tasks (~9.5 KB each) + 1,048 papers (~62 KB each)
    # = ~150 MB of `content` jsonb off disk, over the wire, JSON-decoded into
    # the BEAM and then recursively walked by the plugin extractors — on EVERY
    # `?drafts=true` request. Reproduced locally at that exact shape: 241 MB
    # decoded, 1,027 ms end to end (SQL 811 ms + BEAM 216 ms); live 11.8 s.
    #
    # A PROJECTION CANNOT FIX IT, and the arithmetic is why. Measured on the
    # same corpus: reading with `content` 810 ms, `doc_id`+`type` only 56 ms,
    # plus one server-side jsonb key 93 ms. So projection works — but
    # `Plugins.Bulldocs.extract_edges/2` runs `BodyWalk.collect` over the WHOLE
    # content (ref / href / wikilink / valueref at ANY depth) and has NO type
    # guard, so a paper IS its body and a task must keep `brief.blocks`.
    # Projecting buys ~150 MB -> ~85 MB: 1.7x, not the 12x needed.
    #
    # SO THE ROWS GO, NOT THE BYTES. Of guerrilla's 10,528 documents, 882
    # (8.4%) have a `drafts.` twin. The other 91.6% are published-only and
    # their edges are ALREADY in `content_edges` — the narrow, indexed table
    # `traverse_published/2` walks in 0.46 s.
    #
    # THREE BOUNDED READS, each reporting its own cap:
    #   1. the LIVE-EXTRACT SET, with content — draft twins plus anything
    #      written inside the projector-lag window;
    #   2. the corpus SLUG SET, without content — the phantom lens;
    #   3. the MATERIALISED edges of everything else.
    #
    # TWO CLASSES PER READ, NOT ONE QUERY: `Content.Query.base_query/4` appends
    # the row-ownership ACL only for a type whose schema says
    # `owner_scoped: true`. One query cannot carry a per-type ACL, so the types
    # are split by that flag — the hoisted `schemas` list already holds it, so
    # the split costs no extra read — and each class is read under its OWN
    # lens. Folding them would apply one type's ACL to another type's rows.
    {owned_schemas, plain_schemas} = Enum.split_with(schemas, & &1.owner_scoped)
    owned_types = Enum.map(owned_schemas, & &1.name)
    plain_types = Enum.map(plain_schemas, & &1.name)

    corpus_opts = [
      limit: Keyword.get(opts, :corpus_limit, corpus_limit()),
      workspace_id: workspace_id,
      project_id: project_id,
      caller_context: Keyword.get(opts, :caller_context)
    ]

    both_classes = fn read ->
      {plain, plain_trunc} = read.(plain_types, corpus_opts)
      {owned, owned_trunc} = read.(owned_types, Keyword.put(corpus_opts, :owner_scoped, true))
      {plain ++ owned, plain_trunc || owned_trunc}
    end

    dataset? = is_binary(dataset) and dataset != ""

    # READ 1 — the live-extract set, WITH content. Bounded by the number of
    # draft twins plus the lag window, never by the corpus.
    live_since = DateTime.add(DateTime.utc_now(), -projection_lag_window_s(), :second)

    {live_docs, live_trunc} =
      if dataset? do
        both_classes.(fn types, o ->
          Content.collect_live_extract_documents(
            types,
            dataset,
            Keyword.put(o, :live_since, live_since)
          )
        end)
      else
        {[], nil}
      end

    # READ 2 — the corpus SLUG set, WITHOUT content. `corpus_slugs` decides
    # whether a plugin edge's target is a real document or a phantom, and that
    # question is membership, not content: 56 ms instead of 810 ms.
    {slug_rows, slug_trunc} =
      if dataset? do
        both_classes.(fn types, o -> Content.collect_corpus_slugs(types, dataset, o) end)
      else
        {[], nil}
      end

    corpus_slugs =
      slug_rows
      |> Enum.map(fn row ->
        Content.published_id(Map.get(row, :doc_id) || Map.get(row, "doc_id"))
      end)
      |> MapSet.new()

    live_slugs =
      live_docs
      |> Enum.map(fn doc ->
        Content.published_id(Map.get(doc, :doc_id) || Map.get(doc, "doc_id"))
      end)
      |> MapSet.new()

    # READ 3 — the MATERIALISED arm. Every edge whose SOURCE is not in the
    # live-extract set, read from `content_edges` and rendered into the same
    # slug-keyed shape the live fold produces.
    {materialised, mat_trunc} =
      if dataset? do
        both_classes.(fn types, o ->
          if types == [],
            do: {[], nil},
            else: materialised_drafts_edges(types, live_slugs, dataset, Keyword.merge(opts, o))
        end)
      else
        {[], nil}
      end

    truncated = live_trunc || slug_trunc || mat_trunc
    corpus_capped? = truncated == :cap

    corpus_truncation =
      if corpus_capped?,
        do: %{
          truncated: true,
          limit: Keyword.get(opts, :corpus_limit, corpus_limit()),
          # `read` is THE MEMBERSHIP SET's size, not a sum of three arms. The
          # number a consumer needs is "how many documents the phantom lens
          # saw", because that is the set whose truncation turns a real target
          # into a reported phantom — the exact lie `corpus_truncation` exists
          # to deny. The live-extract and materialised arms have their own
          # bounds and flip the same flag, but their sizes answer a different
          # question and summing them would answer none.
          read: length(slug_rows)
        },
        else: nil

    if corpus_capped? do
      Logger.warning(
        "Content.Graph: drafts graph read for dataset=#{dataset} hit a bound " <>
          "(live_extract=#{inspect(live_trunc)} slugs=#{inspect(slug_trunc)} " <>
          "materialised=#{inspect(mat_trunc)}) — the index is built from a PREFIX, so " <>
          "edges to documents beyond it may render as DANGLING even though their targets " <>
          "exist."
      )
    end

    # THE TWO HOISTS, TOGETHER — they are the whole fix (task-051a87de9a085e4d).
    #
    #   `:schemas`  — the invariant schema list, read ONCE above instead of once
    #                 per document inside `extract_edges/2`.
    #   `dangling:` — `:skip` here, then ONE batched pass over the DISTINCT
    #                 `{to_id, refType}` targets of the whole fold
    #                 (`resolve_core_dangling/3`), instead of one un-batched
    #                 round-trip per reference value per document.
    #
    # Both are pure round-trip removals: `Content.Edges.resolvable_targets/3`
    # runs `resolve_target_existence/4`'s OWN two predicates (typed via
    # `get_document/4`'s scoping pipeline, untyped via the type-agnostic
    # published-lens existence query), so every edge's `dangling` boolean is the
    # value it had before — computed once for a target instead of once per
    # occurrence.
    edge_opts = opts |> Keyword.put(:schemas, schemas) |> Keyword.put(:dangling, :skip)

    edge_list =
      live_docs
      |> Enum.flat_map(fn doc ->
        drafts_edges_for_doc(doc, corpus_slugs, corpus_capped?, edge_opts)
      end)
      |> resolve_core_dangling(dataset, opts)
      |> Kernel.++(materialised)
      |> filter_drafts_edges(opts)

    out_index = Enum.group_by(edge_list, & &1.from_id)
    in_index = Enum.group_by(edge_list, & &1.to_id)

    {out_index, in_index, edge_list, corpus_truncation}
  end

  # ── THE MATERIALISED ARM ───────────────────────────────────────────────────
  #
  # Every edge in `content_edges` whose SOURCE document is NOT in the
  # live-extract set, rendered into the same slug-keyed map shape the live fold
  # produces so the BFS cannot tell the two apart.
  #
  # `dangling: false`, ALWAYS, and it is a fact rather than an assumption:
  # `Content.Edge`'s moduledoc — "the `to_id` FK rejects any `to_id` that is
  # not a real `documents.id`, so a dangling edge is UNSTORABLE — this table
  # holds ONLY resolvable edges. There is deliberately NO `:dangling` field."
  # That is exactly why the visited-set recovery pass in `traverse_drafts/2`
  # exists: a published-only document's BROKEN reference is in no table, so it
  # has to be re-extracted from the document at render time.
  #
  # `field`/`refType` are nil. They are read ONLY when rendering a phantom
  # (`via_field`, `refType`), and a materialised edge is never dangling and so
  # never a phantom. `kind` IS the source field's name on a core edge
  # (graph-edge-seam), which is what live extraction emits too, so kind-filtering
  # behaves identically across both arms.
  #
  # SCOPE. `content_edges` carries no tenancy columns — an edge is scoped by its
  # endpoints. Scoping the FROM document is sufficient: `Content.Edges.add_edge/4`
  # resolves both endpoint slugs under one writer scope, so a stored edge cannot
  # straddle two scopes. The TO document is joined only to recover its slug.
  defp materialised_drafts_edges(types, live_slugs, dataset, opts) do
    limit = Keyword.get(opts, :materialised_edge_limit, materialised_edge_limit())
    scoped_ids = Content.corpus_scope_ids_query(types, dataset, opts)

    rows =
      from(e in Edge,
        join: f in Document,
        on: f.id == e.from_id,
        join: t in Document,
        on: t.id == e.to_id,
        where: e.from_id in subquery(scoped_ids),
        select: %{
          from_id: f.doc_id,
          to_id: t.doc_id,
          kind: e.kind,
          plugin_source: e.plugin_source
        },
        limit: ^(limit + 1)
      )
      |> Repo.all()

    {rows, truncated} =
      if length(rows) > limit, do: {Enum.take(rows, limit), :cap}, else: {rows, nil}

    edges =
      rows
      |> Enum.map(fn row ->
        %{
          from_id: Content.published_id(row.from_id),
          to_id: Content.published_id(row.to_id),
          kind: row.kind,
          field: nil,
          refType: nil,
          plugin_source: row.plugin_source,
          dangling: false
        }
      end)
      # THE OVERRIDE. A document in the live-extract set has just been extracted
      # from its CURRENT content; its materialised rows are the previous
      # published state and would double-count or resurrect a removed reference.
      # Keyed on the SOURCE only — an edge INTO a live doc is still that other
      # document's edge and stays.
      |> Enum.reject(fn e -> MapSet.member?(live_slugs, e.from_id) end)

    {edges, truncated}
  end

  # ── PHANTOM RECOVERY ───────────────────────────────────────────────────────
  #
  # The dangling out-edges of the VISITED nodes, re-extracted from those
  # documents. This is the pass the row cut makes necessary: `content_edges`
  # cannot hold a dangling edge (the `to_id` FK forbids it), so a published-only
  # document's broken reference is invisible to the materialised arm — the edge
  # would vanish AND its phantom node with it, silently.
  #
  # WHY POST-BFS IS EXACT. The pre-hybrid code built the whole corpus edge list,
  # walked it, and then kept `e.dangling and e.from_id in visited` — so the
  # phantom set was ALWAYS "the dangling out-edges of the visited nodes" and
  # nothing else survived that filter. A dangling edge's target is BY DEFINITION
  # not a document, so `drafts_bfs/7` can never expand through one; adding these
  # edges after the walk therefore cannot change `visited`, `distance`,
  # `dependents` or the BFS truncation flags. Same set, computed from the ≤
  # `@node_budget` documents that render instead of from the whole corpus.
  #
  # ONE STATED DIVERGENCE: a dangling neighbour used to consume `@fan_out`
  # budget during the walk and no longer does, so a node with more than 200
  # dangling references could report `:fan_out` before and not now. That is the
  # honest direction — the hybrid truncates LESS — and the depth trip-wire
  # already excludes dangling neighbours from its boundary test.
  #
  # KEYED ON VISITED, NOT ON TWIN STATUS. A published-only document that the
  # walk reached is re-extracted exactly like a draft twin, which is what keeps
  # the published arm of the phantom contract alive.
  defp recover_visited_dangling(visited, already, dataset, opts) do
    docs = hydrate_slugs(visited, dataset, opts)

    if docs == [] do
      []
    else
      schemas =
        if is_binary(dataset) and dataset != "", do: Content.list_schemas(dataset, opts), else: []

      edge_opts = opts |> Keyword.put(:schemas, schemas) |> Keyword.put(:dangling, :skip)

      docs
      |> Enum.flat_map(fn doc ->
        drafts_edges_for_doc(doc, MapSet.new(visited), false, edge_opts)
      end)
      |> resolve_core_dangling(dataset, opts)
      |> Enum.filter(fn e -> e.dangling end)
      |> filter_drafts_edges(opts)
      |> Enum.reject(fn e -> MapSet.member?(already, {e.from_id, e.to_id, e.kind}) end)
    end
  end

  # The visited slugs' documents, drafts-preferred, in ONE keyed read bounded by
  # `@node_budget`. Never the corpus.
  defp hydrate_slugs([], _dataset, _opts), do: []

  defp hydrate_slugs(slugs, dataset, opts) do
    prefixed = Enum.map(slugs, fn slug -> DraftId.drafts_prefix() <> slug end)
    wanted = Enum.take(slugs ++ prefixed, 2 * @node_budget)

    Document
    |> where([d], d.doc_id in ^wanted)
    |> scope_query(opts)
    |> then(fn q ->
      if is_binary(dataset) and dataset != "", do: where(q, [d], d.dataset == ^dataset), else: q
    end)
    |> Repo.all()
    |> prefer_draft_twin()
  end

  # Draft-preferred, mirroring the corpus read's DISTINCT ON tiebreaker: when
  # both twins came back, the `drafts.` row wins.
  defp prefer_draft_twin(docs) do
    docs
    |> Enum.group_by(fn d -> {d.type, Content.published_id(d.doc_id)} end)
    |> Enum.map(fn {_key, group} ->
      Enum.find(group, fn d -> DraftId.draft?(d.doc_id) end) || hd(group)
    end)
  end

  # THE BATCHED DANGLING PASS. Core edges leave `drafts_edges_for_doc/3` with
  # `dangling: nil` — `extract_edges/2`'s documented "NOT COMPUTED" marker under
  # `dangling: :skip`. On a COMPLETE corpus read plugin edges never carry nil:
  # `normalize_plugin_drafts_edge/3` already decided theirs from `corpus_slugs`
  # (the deliberate lens difference documented there), so the `nil` test is then
  # exactly "a core edge still owing an answer". On a CAPPED read a plugin edge
  # whose target missed the prefix hands its verdict here too — deliberately,
  # because a prefix cannot prove an absence — and it joins the same batch.
  #
  # ONE `resolvable_targets/3` call for the whole fold: bounded by the number of
  # DISTINCT `refType`s, never by the number of documents or reference values.
  defp resolve_core_dangling(edges, dataset, opts) do
    pending = Enum.filter(edges, fn e -> Map.get(e, :dangling) == nil end)

    case pending do
      [] ->
        edges

      _ ->
        resolvable =
          pending
          |> Enum.map(fn e -> {e.to_id, Map.get(e, :refType)} end)
          |> Content.Edges.resolvable_targets(dataset, opts)

        Enum.map(edges, fn e ->
          if Map.get(e, :dangling) == nil do
            %{e | dangling: not MapSet.member?(resolvable, {e.to_id, Map.get(e, :refType)})}
          else
            e
          end
        end)
    end
  end

  # The per-doc union, mirroring `EdgeProjector.Projector.edges_for_doc/2`
  # (lvw-t12 / wire §7(2)): core reference-field edges seed the baseline, then
  # the `resolve_extract_edges` chain unions every plugin's projected edges —
  # so a DRAFT paper's valueref/wikilink/ref edges (Bulldocs) appear in the
  # drafts graph without waiting for publish. Plugin extractors are
  # contractually PURE (no DB — plugin.ex), so folding them into this LIVE
  # per-request path adds no queries beyond the existing core pass.
  #
  # Boundary (documented, NOT folded): extractors that depend on
  # projector-side resolution context still under-emit here. Concretely, the
  # Tasks plugin's dependency edges ("blocks"/"discovered-from") require
  # `doc.task_edges` hydrated by the EdgeProjector worker
  # (`Tasks.hydrate_edges/1`); the drafts corpus is unhydrated, so the live
  # drafts graph sees a task's `parent` edge but its dependency edges stay
  # published-graph-only. Hydrating here would be a per-doc query over the
  # whole corpus — exactly the per-request storm this path must avoid.
  defp drafts_edges_for_doc(doc, corpus_slugs, corpus_capped?, opts) do
    dataset = Map.get(doc, :dataset) || Map.get(doc, "dataset") || Keyword.get(opts, :dataset)
    core = Content.extract_edges(doc, opts)

    core
    |> collect_plugin_edges(%{doc: doc, dataset: dataset})
    |> Enum.map(fn
      # Core edges arrive fully formed (dangling/field/refType resolved).
      %{dangling: _} = edge -> edge
      edge -> normalize_plugin_drafts_edge(edge, corpus_slugs, corpus_capped?)
    end)
  end

  # ── The inverted extractor seam ────────────────────────────────────────────
  # Reads the collector the composition root installed under
  # `:edge_extractor_collector` and drives it with the SAME `[baseline:, ctx:]`
  # contract `Barkpark.Plugins.Registry.collect_edge_extractors/1` publishes —
  # the kernel just never names that module. Two installable shapes:
  #
  #   * a 1-arity fun (what the boot installer captures), and
  #   * a `{module, function}` pair, so a release/config can wire the seam
  #     without the app having booted.
  #
  # UNSET (a fresh install, a plugin-free host, a script or a test that never
  # started the OTP app) returns the core baseline UNCHANGED — core edges only,
  # never a crash. Same for a garbage value: the seam degrades, it does not
  # take the drafts graph down with it.
  defp collect_plugin_edges(core, ctx) do
    case Application.get_env(:barkpark, @edge_extractor_collector_key) do
      collector when is_function(collector, 1) ->
        collector.(baseline: core, ctx: ctx)

      {mod, fun} when is_atom(mod) and is_atom(fun) ->
        apply(mod, fun, [[baseline: core, ctx: ctx]])

      _ ->
        core
    end
  end

  # Plugin edges arrive as `%{from_id, to_id, kind, plugin_source}` —
  # slug-keyed, with no dangling/field/refType (on the published path the
  # WRITE-side resolution in `add_edges/2` decides what materialises). The
  # drafts BFS needs `dangling`, so resolve it against the in-memory SCOPED
  # drafts corpus. NOTE the deliberate lens difference vs core edges: core
  # resolves dangling per target under the `:published` DB lens; plugin edges
  # use drafts-corpus membership — the natural lens for a drafts surface (a
  # draft-only valueref target is a real drafts node, not a phantom), and free
  # of per-target DB reads (constraint: no per-request storms).
  #
  # WHEN THE CORPUS READ CAPPED, `corpus_slugs` IS A PREFIX AND ITS ABSENCES
  # MEAN NOTHING. "Not in the corpus set" then conflates "no such document"
  # with "past the bound", and the second one rendered as a PHANTOM — a
  # truncation reported as a broken reference. So under a cap the membership
  # test may only CONFIRM (a hit is still a real drafts node), never DENY: a
  # miss becomes `nil` — `extract_edges/2`'s "not computed" marker — and the
  # ALREADY-BATCHED `resolve_core_dangling/3` pass settles it against the DB.
  # That costs no extra round-trip per edge (the pass runs either way, bounded
  # by DISTINCT `{to_id, refType}`), so the no-per-request-storm constraint
  # holds. The lens under a cap is therefore the UNION of the two: dangling
  # only when the target is in neither the read prefix nor the published DB.
  defp normalize_plugin_drafts_edge(edge, corpus_slugs, corpus_capped?) do
    dangling =
      cond do
        MapSet.member?(corpus_slugs, edge.to_id) -> false
        corpus_capped? -> nil
        true -> true
      end

    %{
      from_id: edge.from_id,
      to_id: edge.to_id,
      kind: edge.kind,
      field: Map.get(edge, :field),
      refType: Map.get(edge, :refType),
      plugin_source: Map.get(edge, :plugin_source),
      dangling: dangling
    }
  end

  # kinds + sources parity with the published path's `filter_edges/2`. Core
  # live-extracted edges have no plugin_source key (nil via Map.get — matching
  # their materialised rows' NULL column); plugin edges carry their producer.
  defp filter_drafts_edges(edges, opts) do
    kinds = Keyword.get(opts, :kinds)
    sources = Keyword.get(opts, :sources)

    edges
    |> maybe_filter(kinds, fn e -> e.kind in kinds end)
    |> maybe_filter(sources, fn e -> Map.get(e, :plugin_source) in sources end)
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

          not edge.dangling and not is_nil(neighbor) and
            not MapSet.member?(state.visited, neighbor)
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
    %{
      from_id: e.from_id,
      to_id: e.to_id,
      kind: e.kind,
      weight: nil,
      plugin_source: Map.get(e, :plugin_source)
    }
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
  defp neighbor_edges(id, :out, _persp, opts),
    do: Content.list_outbound_edges(id, edge_opts(opts))

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
  defp hydrate_docs([], _opts), do: []

  defp hydrate_docs(ids, opts) do
    Document
    |> where([d], d.id in ^ids)
    |> scope_query(opts)
    |> Repo.all()
  end

  defp node_map(%Document{} = d) do
    %{
      id: d.id,
      doc_id: d.doc_id,
      type: d.type,
      title: d.title,
      phantom: false
    }
  end

  # Phantom (ghost) nodes — dangling targets that are NOT in `content_edges`
  # (the FK forbids them) so they never appear as a real node. We re-derive them
  # by re-extracting the visited source docs and keeping the dangling targets,
  # capped @ghost_cap per source with a '+N more broken' overflow marker.
  defp phantom_nodes(hydrated_docs, _edges, _perspective, opts) do
    dataset = Keyword.get(opts, :dataset)

    if is_nil(dataset) do
      []
    else
      # `hydrated_docs` are the SAME rows `hydrate_docs/2` just read (already
      # tenancy-scoped by `scope_query/2`), so the per-node keyed re-read is
      # gone. `:schemas` is hoisted per distinct dataset — the
      # prefetch contract `edges.ex` documents at its `:schemas` note.
      edge_opts_for = schema_prefetch_fun(hydrated_docs, opts)

      hydrated_docs
      |> Enum.flat_map(fn %Document{} = doc ->
        doc
        |> Content.extract_edges(edge_opts_for.(doc))
        |> Enum.filter(& &1.dangling)
        |> cap_ghosts(doc.doc_id)
      end)
      |> Enum.uniq_by(& &1.broken_id)
    end
  end

  # Hoist ONE `Content.list_schemas/2` per DISTINCT dataset above a
  # per-document `extract_edges/2` fold, and return the per-doc opts builder.
  #
  # This is the contract `edges.ex` records at its `:schemas` note — "a
  # 4096-document corpus issued 4096 identical schema queries (the dominant
  # cost in the /v1/graph derivation — measured live: a 34s first paint)" —
  # and `Edges.corpus_edges_for_docs/3` honors with the same
  # `Keyword.put_new_lazy(:schemas, ...)` shape. `graph.ex` is the call site
  # that fix never reached.
  #
  # Keyed by the DOCUMENT's dataset, not `opts[:dataset]`: the graph traversal
  # is not dataset-filtered, so a fold can span datasets and a single hoisted
  # list would resolve the wrong schema for an out-of-dataset row. Grouping
  # keeps `extract_edges/2` byte-identical per document while making the query
  # count O(distinct datasets) instead of O(documents). A caller that already
  # supplies `:schemas` is passed through untouched.
  defp schema_prefetch_fun(docs, opts) do
    if Keyword.has_key?(opts, :schemas) do
      fn _doc -> opts end
    else
      by_dataset =
        docs
        |> Enum.map(& &1.dataset)
        |> Enum.uniq()
        |> Map.new(fn ds -> {ds, Content.list_schemas(ds, opts)} end)

      fn %Document{dataset: ds} -> Keyword.put(opts, :schemas, Map.fetch!(by_dataset, ds)) end
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

  defp render_edge(%Edge{} = e) do
    # `weight` is emitted for the Canvas2D force-sim LAYOUT ONLY — it is NEVER read by
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

  NEVER sort by weight — weight is Canvas2D-force-sim-layout-only; ranking is topology
  (distance, fan-in, inserted_at). A future author wiring `edge.weight` into
  this sort would silently couple layout to ranking — do NOT.
  """
  @spec rank_dependents([map()], %{optional(binary()) => non_neg_integer()}, [Edge.t()]) :: [
          map()
        ]
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

        # Fail-closed hydration (MEDIUM-5): a source that did NOT hydrate under
        # the caller's scope — owner_scoped + owned by another user (now dropped
        # by `docs_by_id/2`'s `scope_to_owner`), or out-of-tenant — is REJECTED
        # entirely. Emitting a stub (its UUID as `from_id`/`title`) would leak
        # the existence of an inbound link the caller may not see; dropping it
        # matches `hydrate_docs/2`'s "hydrates to NOTHING" tenancy posture and
        # `PaperBacklinks.section_html`, which already renders nil-source rows
        # as empty.
        inbound
        |> Enum.flat_map(fn %Edge{} = e ->
          case Map.get(docs_by_id, e.from_id) do
            nil ->
              []

            src ->
              [
                %{
                  from_id: e.from_id,
                  from_doc_id: src.doc_id,
                  title: src.title || e.from_id,
                  description: Map.get(src.content || %{}, "description"),
                  event_type: Map.get(src.content || %{}, "event_type"),
                  rev: src.rev,
                  updated_at: src.updated_at,
                  type: src.type,
                  kind: e.kind,
                  via_field: e.kind,
                  plugin_source: e.plugin_source
                }
              ]
          end
        end)
    end
  end

  @doc """
  Documents with ZERO inbound AND ZERO outbound edges in `content_edges` — the
  isolated corpus. Scoped by `:workspace_id` / `:project_id` (+ optional
  `:dataset`). Returns hydrated node maps.
  """
  @spec orphans(keyword()) :: [map()]
  def orphans(opts \\ []), do: orphans_bounded(opts).orphans

  @doc """
  `orphans/1` with the BOUND REPORTED — `%{orphans: rows, count: n, limit: l,
  truncated: bool}`.

  The scan bound (`@corpus_scan_limit`) has always been there; what was missing
  was any way for a caller to know it FIRED. A bare list that stops at 5,000 is
  indistinguishable from a corpus that happens to hold exactly 5,000 orphans,
  and `/v1/graph/orphans` shipped that ambiguity to clients as if it were the
  whole answer. This reads `limit + 1` rows and drops the probe row, so
  `truncated` is a MEASUREMENT, not a guess — the same honesty contract
  `/v1/graph` already holds for its node budget.
  """
  @spec orphans_bounded(keyword()) :: %{
          orphans: [map()],
          count: non_neg_integer(),
          limit: pos_integer(),
          truncated: boolean()
        }
  def orphans_bounded(opts \\ []) do
    # The connected-set is a correlated NOT EXISTS against the SCOPED document
    # subquery, not a UNION of every `content_edges` endpoint in the instance.
    #
    # The old shape read `select from_id UNION select to_id` over the WHOLE
    # table with no tenancy predicate and no LIMIT, then built a MapSet in the
    # BEAM — so a five-document workspace materialised every edge endpoint UUID
    # belonging to every OTHER tenant on the box, and its cost scaled with the
    # largest tenant's edge count. `content_edges` carries no scope column BY
    # DESIGN (migration 20260614230000: scope is inherited from the endpoints),
    # so the tenancy filter cannot be a `where` on the edge — it has to be this
    # correlation to the already-scoped document row.
    connected =
      from(e in Edge,
        where: e.from_id == parent_as(:doc).id or e.to_id == parent_as(:doc).id,
        select: 1
      )

    rows =
      from(d in subquery(scoped_docs_query(opts)),
        as: :doc,
        where: not exists(connected),
        order_by: [asc: d.inserted_at, asc: d.id],
        # +1 PROBE ROW: read one past the bound so a full page can be told
        # apart from an exactly-full corpus. The probe is dropped below.
        limit: ^(corpus_scan_limit() + 1)
      )
      |> Repo.all()
      |> Enum.map(fn d ->
        %{id: d.id, doc_id: d.doc_id, type: d.type, title: d.title}
      end)

    limit = corpus_scan_limit()
    truncated = length(rows) > limit
    rows = Enum.take(rows, limit)

    %{orphans: rows, count: length(rows), limit: limit, truncated: truncated}
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
  def dangling(opts \\ []), do: dangling_bounded(opts).dangling

  @doc """
  `dangling/1` with the BOUND REPORTED — `%{dangling: rows, count: n, limit: l,
  truncated: bool}`. See `orphans_bounded/1` for why the bare list was dishonest.

  TWO ceilings here, and `truncated` goes true when EITHER fires: the document
  SCAN bound (the corpus walk stops at `limit` docs — the pre-existing one) and
  the ROW bound (one document can emit many broken references, so the folded
  output was unbounded even though its input was not).
  """
  @spec dangling_bounded(keyword()) :: %{
          dangling: [map()],
          count: non_neg_integer(),
          limit: pos_integer(),
          truncated: boolean()
        }
  def dangling_bounded(opts \\ []) do
    scanned =
      scoped_docs_query(opts)
      |> order_by([d], asc: d.inserted_at, asc: d.id)
      # +1 probe row, exactly as in `orphans_bounded/1`.
      |> limit(^(corpus_scan_limit() + 1))
      |> Repo.all()

    limit = corpus_scan_limit()
    scan_truncated = length(scanned) > limit
    docs = Enum.take(scanned, limit)

    # ONE schema read for the whole fold (per distinct dataset) instead of one
    # per document — see `schema_prefetch_fun/2` and the `edges.ex` `:schemas`
    # contract it restores.
    edge_opts_for = schema_prefetch_fun(docs, opts)

    rows =
      Enum.flat_map(docs, fn doc ->
        doc
        |> Content.extract_edges(edge_opts_for.(doc))
        |> Enum.filter(& &1.dangling)
        |> Enum.map(fn e ->
          %{from_id: e.from_id, to_id: e.to_id, via_field: e.field, refType: e.refType}
        end)
      end)

    row_truncated = length(rows) > limit
    rows = Enum.take(rows, limit)

    %{
      dangling: rows,
      count: length(rows),
      limit: limit,
      truncated: scan_truncated or row_truncated
    }
  end

  # ── Internal scope helpers ──────────────────────────────────────────────────

  # All published docs in the caller's scope. Used by orphans/dangling — both
  # emit a document's title + doc_id + existence, so they carry the SAME
  # row/ownership ACL as the keyed hydration reads (MEDIUM-5): `scope_to_owner/2`
  # is applied UNCONDITIONALLY (typeless corpus read; non-owner_scoped rows have
  # a NULL `owner_id` and pass unchanged), dropping an owner_scoped doc owned by
  # another user from a non-owner's orphans/dangling listing. nil caller_context
  # fails CLOSED to unowned-only (LOW-12).
  defp scoped_docs_query(opts) do
    dataset = Keyword.get(opts, :dataset)
    workspace_id = Keyword.get(opts, :workspace_id)
    project_id = Keyword.get(opts, :project_id)
    prefix = "drafts.%"

    query =
      Document
      |> where([d], not like(d.doc_id, ^prefix))
      |> Barkpark.Content.Scope.scope_to_workspace_or_global(workspace_id, project_id)
      |> Barkpark.Content.Scope.scope_to_owner(Keyword.get(opts, :caller_context))
      |> maybe_scope_to_types(Keyword.get(opts, :types))

    query =
      if is_binary(dataset) and dataset != "" do
        where(query, [d], d.dataset == ^dataset)
      else
        query
      end

    # Layer-2 grant narrowing, defense-in-depth (airdrop-grants,
    # ag-backlinks-grant-leak). Inert today — `/v1/graph` orphans/dangling is
    # `:require_token` with no grant fold, so no live caller sets `grant_scoped`
    # here — but the seam keeps the corpus read fail-closed the moment a
    # grant-derived surface ever calls `orphans/1` / `dangling/1`. Byte-identical
    # for every current caller (flag absent; no-op inside the wrapper).
    Scope.maybe_scope_to_grants(query, opts)
  end

  # SCHEMA-VISIBILITY narrowing for the derived corpus reads (orphans/dangling).
  #
  # These two endpoints emit a document's `type` and `title`, so they answer the
  # same question `/v1/graph` answers — "what lives in this corpus?" — and must
  # honour the same clamp. `/v1/graph` runs it as
  # `Content.list_schemas/2 |> Schema.visible_schemas/2`; the caller passes the
  # surviving type NAMES down here as `:types` rather than this module reaching
  # for the schema table itself (`Content.Graph` is kernel-side and has no
  # principal). The clamp's canonical owner stays
  # `Content.Schema.visible_schemas/2` — one predicate, not a hand-copy.
  #
  # `nil` means "no clamp requested" (every direct caller inside the kernel and
  # the test suite), NOT "no types" — the narrowing is opt-in at the seam that
  # knows the principal. An EMPTY list is a real clamp and fails CLOSED: a
  # caller that may see no schemas sees no orphans.
  #
  # OBSERVABLE DELTA TODAY: ~zero, and deliberately so. `/v1/graph/orphans` and
  # `/v1/graph/dangling` are `:require_token`, and `PublicRead.allowed_route?/1`
  # admits only the EXACT two-segment `/v1/graph` — so the one tier the clamp
  # narrows (public-read) is already 403 at the route. This is the same
  # defense-in-depth posture `graph_perspective/2` documents: the route gate is
  # load-bearing today, and this makes the derived reads safe the moment the
  # route gate widens.
  defp maybe_scope_to_types(query, nil), do: query

  defp maybe_scope_to_types(query, types) when is_list(types),
    do: where(query, [d], d.type in ^types)

  defp maybe_scope_to_types(query, _), do: query

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

  RAISES `Barkpark.Tasks.AmbiguousTwinError` (409 `ambiguous_dataset`) when the
  id is a `type: "task"` whose winning-tier rows span more than one dataset in
  scope and no `dataset` was named — `Barkpark.Tasks.TwinResolver` rule 3, the
  same refusal `GET /v1/tasks/:doc_id` gives. Non-task types never raise.
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

    # Layer-2 grant narrowing (airdrop-grants, ag-backlinks-grant-leak). Inert
    # unless `opts[:grant_scoped]` (only AssignGrantScope / ResolveWorkspace /
    # LiveScope ever set it), so members/tokens/anonymous stay byte-identical;
    # when set, a grant-derived caller's slug resolution is narrowed to the union
    # of its grant scopes, failing CLOSED (`where: false` → nil) on an uncovered
    # target — that nil is what makes `reverse_referencers` return `[]` for a doc
    # outside the grant ladder instead of leaking its referencers.
    query = Scope.maybe_scope_to_grants(query, opts)

    rows = Repo.all(query)

    # THE ONE RULE (`Barkpark.Tasks.TwinResolver` — read that moduledoc; this
    # resolver writes no second rule). This is the canonical slug resolver for
    # EVERY type, so the refusal is TASK-SCOPED: a `type == "task"` id whose
    # winning-tier rows span more than one dataset of the caller's
    # workspace/project, with no `dataset` named, RAISES
    # `Barkpark.Tasks.AmbiguousTwinError` (409 `ambiguous_dataset`, naming both)
    # instead of letting `List.first` pick a dataset the caller never named.
    # Every other type is untouched — a second copy of a non-task document in
    # another dataset is content replication working as designed.
    #
    # Why RAISE and not `nil`: all three callers (`resolve_pk/2`,
    # `Content.Related`, the Studio `PaneBuilder`) collapse `nil` into "not
    # found"/empty, so a nil would recreate the silent-wrong-answer family one
    # level up — an empty backlinks pane reading as truth. The raise reaches
    # every door identically and already renders as the task doors' own 409.
    #
    # `limit(1) |> Repo.one()` became `Repo.all` + `List.first` for the same
    # reason `choose/3` takes rows: the rule cannot decide from a row the query
    # already dropped. The `where` is an exact doc_id match on two spellings, so
    # the read stays bounded by (types x datasets) for one id.
    Barkpark.Tasks.TwinResolver.refuse_ambiguous_task!(rows, pub_id, dataset)

    List.first(rows)
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
  #
  # Row/ownership ACL (MEDIUM-5, core-auth). The graph hydration reads
  # (`hydrate_docs/2`, `docs_by_id/2`) emit a document's
  # title + doc_id + existence to the caller — the backlinks pane, the Studio
  # graph, the public papers backlinks. Like `Query.get_documents_by_ids/3`,
  # this read is TYPELESS (a graph spans many types), so `scope_to_owner/2` is
  # applied UNCONDITIONALLY: non-owner_scoped rows carry a NULL `owner_id` and
  # always satisfy the clause (byte-identical), while an owner_scoped node owned
  # by another user is dropped from a non-owner's hydration. The
  # `:caller_context` is threaded from the graph's callers via `scope_opts/1`;
  # a caller that threads none (nil) now fails CLOSED to unowned-only rows
  # (LOW-12) instead of leaking every owner's nodes.
  defp scope_query(query, opts) do
    # Layer-2 grant narrowing (airdrop-grants, ag-backlinks-grant-leak) rides
    # last: inert unless `opts[:grant_scoped]` — the flag ONLY AssignGrantScope /
    # ResolveWorkspace / LiveScope set — so every existing caller (members,
    # tokens, anonymous, the graph_test suite's plain `[dataset: ...]` opts) is
    # byte-identical. When set, the keyed graph hydration reads (`docs_by_id/2`,
    # `hydrate_docs/2`) are restricted to the union of the
    # caller's grant scopes, failing CLOSED (`where: false`) on an
    # absent/uncovering grant — so a grant-derived socket's graph/blast-radius
    # pane can never hydrate a node outside its grant ladder.
    query
    |> Scope.scope_to_workspace_or_global(
      Keyword.get(opts, :workspace_id),
      Keyword.get(opts, :project_id)
    )
    |> Scope.scope_to_owner(Keyword.get(opts, :caller_context))
    |> Scope.maybe_scope_to_grants(opts)
  end
end
