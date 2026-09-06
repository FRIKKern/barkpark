defmodule Barkpark.EdgeProjector.Projector do
  @moduledoc """
  Materialise the content graph into the durable `content_edges` table.

  The projection is the union of TWO sources per document:

    1. CORE reference-field edges — `Barkpark.Content.extract_edges/2` over the
       doc's schema reference fields (scalar + arrayOf). This is the
       fresh-install floor: it emits edges with ALL plugins off.
    2. PLUGIN-projected edges — `Barkpark.Plugins.Registry.collect_edge_extractors/1`
       runs every plugin's `resolve_extract_edges/2` over the doc (Tasks projects
       `blocks`/`discovered-from`/`parent`; Bulldocs projects paper `references`).
       With plugins `[]` this contributes nothing.

  ## Purity (matches `Indexer.rebuild/3`)

  `project/3` performs NO DB reads — the worker lists the corpus and hands it
  in, exactly like the Indx blue/green rebuild. It folds the two extractors,
  unions, and dedups by `{from_id, to_id, kind}`. Dangling resolution is NOT
  done here — `Content.extract_edges/2` carries a read-time `:dangling` signal
  but a dangling edge is UNSTORABLE (the `to_id` FK forbids a non-existent
  target), so the write paths simply let `add_edge/4` reject it as
  `{:error, :no_target}`. The graph stores only resolvable edges.

  ## Endpoint identity is (doc_id, TYPE), never doc_id alone

  `documents.doc_id` is unique per (scope, type), so a `tag` and a `task` can
  share a name. Every edge's `from_id` is therefore bound to a pk of the SOURCE
  DOC'S OWN TYPE before it is written (`stamp_from_type/2` + `bind_from_ids/3`),
  and the prune-side `doc_pk/2` is type-pinned to match. An edge whose typed
  source does not exist under the scope is DROPPED WITH A LOG, never re-bound
  to a same-named row of another type. See `stamp_from_type/2` for the measured
  failure this closes (task-464b89f30e3f8e41).

  ## Write paths (these DO touch the durable table)

  Unlike Indx there is NO blue/green dataset and NO `:persistent_term` live
  pointer — `content_edges` is a durable Postgres table, so a "rebuild" is an
  atomic in-transaction DELETE-then-bulk-add over the scope's source rows, not
  a swap of an external engine. There is therefore no boot recovery (gap #6 —
  nothing to re-seat).

    * `rebuild_scope/3` — DELETE the scope's outbound edges for the corpus, then
      bulk `add_edges/2`, all inside one transaction (atomic swap).
    * `upsert_record/2` — re-extract ONE doc's outbound edges, diff against
      stored, apply add (via the `add_edge/4` replace-on-conflict) / remove.
    * `delete_record/2` — remove ALL `content_edges` rows touching a doc's PK
      (both `from_id` and `to_id`), so an unpublished/deleted doc leaves no
      stale inbound or outbound edges.
  """

  require Logger
  import Ecto.Query

  alias Barkpark.Content
  alias Barkpark.Content.{Document, Edge, Scope}
  alias Barkpark.Plugins.Registry
  alias Barkpark.Repo

  @typedoc "Pure projection result — the union of core + plugin edges for a doc list."
  @type projection :: %{
          edges: [map()],
          key_map: %{}
        }

  @doc """
  PURE projection of `docs` into edge maps. Folds `Content.extract_edges/2`
  (core) AND `Registry.collect_edge_extractors/1` (plugins) over each doc,
  unions, dedups by `{from_id, to_id, kind}`.

  No DB reads — the caller (worker) lists the corpus and passes it in. `opts`
  carries the resolution `dataset` + tenancy scope so the core extractor's
  dangling pass uses the right lens; the edges themselves are slug-keyed and
  resolved to PKs only on the WRITE paths (`add_edges/2`).

  Returns `{:ok, %{edges: [...], key_map: %{}}}`. `key_map` is an empty map —
  carried for shape-parity with `Indexer.rebuild/3`'s result; the content
  graph needs no numeric key map (Postgres rows are keyed by their own UUID).
  """
  @spec project(String.t(), [map()], keyword()) :: {:ok, projection()}
  def project(_scope, docs, opts \\ []) when is_list(docs) do
    opts = prefetch_schemas(docs, opts)

    edges =
      docs
      |> Enum.flat_map(fn doc -> edges_for_doc(doc, opts) end)
      |> dedup()

    {:ok, %{edges: edges, key_map: %{}}}
  end

  # SCHEMAS PREFETCH — `Content.extract_edges/2` re-reads the dataset's schema
  # list once PER DOCUMENT unless a `:schemas` prefetch is threaded through its
  # opts (see its `:schemas` note: the exact N+1 already measured and fixed on
  # /v1/graph — 4096 identical schema queries, 34s first paint — which the
  # projector never adopted). The schema list is invariant across one rebuild,
  # so compute it ONCE here and pass it into every `edges_for_doc/2` call,
  # mirroring `Content.Edges.corpus_edges_for_docs/3`. `put_new_lazy` keeps any
  # caller-supplied prefetch.
  defp prefetch_schemas([], opts), do: opts

  defp prefetch_schemas([doc | _], opts) do
    dataset =
      Keyword.get(opts, :dataset) || Map.get(doc, :dataset) || Map.get(doc, "dataset")

    Keyword.put_new_lazy(opts, :schemas, fn -> Content.list_schemas(dataset, opts) end)
  end

  # The per-doc union: core reference-field edges + every plugin's projected
  # edges. `collect_edge_extractors/1` seeds its baseline with the core edges
  # and threads the ctx (carrying the doc) through each plugin's
  # `resolve_extract_edges/2`. With plugins [] the baseline is returned
  # unchanged — the fresh-install floor.
  defp edges_for_doc(doc, opts) do
    dataset = Map.get(doc, :dataset) || Map.get(doc, "dataset") || Keyword.get(opts, :dataset)
    core = Content.extract_edges(doc, opts)

    Registry.collect_edge_extractors(
      baseline: core,
      ctx: %{doc: doc, dataset: dataset}
    )
    |> stamp_from_type(doc_type(doc))
  end

  # `documents.doc_id` is unique per (scope, TYPE) — a `tag` document and a
  # `task` document can carry the SAME doc_id, and epic roots routinely do
  # because the epic's name is also its tag. Both extractors emit `from_id` as
  # a bare doc_id STRING, and every downstream resolution of that string
  # (`Content.Edges.resolve_doc_pks/3` on the write, `doc_pk/2` on the prune)
  # is TYPE-BLIND: it takes whichever row the scope returns first.
  #
  # MEASURED on prod 2026-09-06 (task-464b89f30e3f8e41): the `wave_paper` and
  # `papers` citations of the TASK `api-read-path-security-sweep` are stored
  # with `from_id` = the pk of the same-named `tag` document. The edges exist,
  # `GET /v1/graph/<paper>` renders them — and every task-side reader rightly
  # refuses them, because their source is not a task. Two citations were
  # invisible for two weeks and were filed as a missing-edge/rebuild gap.
  #
  # The emitter always knows its OWN type, so stamp it here (pure — reads the
  # doc map, no DB) and let the write paths resolve `from_id` type-pinned. The
  # key is `:from_type`; `Content.add_edges/2` builds its items from a fixed
  # key list and ignores extras, so this rides along harmlessly.
  #
  # `to_id` is NOT pinned: neither extractor declares the target's type (a
  # `wave_paper` value is a bare slug), so there is nothing truthful to pin it
  # with. That half stays as it was.
  defp stamp_from_type(edges, nil), do: edges

  defp stamp_from_type(edges, type) when is_binary(type) do
    Enum.map(edges, fn e -> Map.put(e, :from_type, type) end)
  end

  defp stamp_from_type(edges, _), do: edges

  defp doc_type(doc), do: Map.get(doc, :type) || Map.get(doc, "type")

  defp edge_from_id(e), do: e[:from_id] || e["from_id"]
  defp edge_from_type(e), do: e[:from_type] || e["from_type"]

  # Dedup by the storage triple {from_id, to_id, kind}. The first occurrence
  # wins its metadata (the on_conflict replace at write time makes the final
  # stored value deterministic by corpus order anyway).
  defp dedup(edges) do
    edges
    |> Enum.uniq_by(fn e ->
      {e[:from_id] || e["from_id"], e[:to_id] || e["to_id"], e[:kind] || e["kind"]}
    end)
  end

  @doc """
  FULL per-scope rebuild — the safe default path (flag OFF). Lists nothing
  itself (the corpus `docs` is handed in), projects the union, then atomically
  swaps the scope's edges in ONE transaction: DELETE every outbound edge from
  the corpus's resolved PKs, then bulk `add_edges/2`.

  Atomic without blue/green — `content_edges` is a durable table, so the
  transaction IS the swap (no external engine, no live pointer). Returns
  `{:ok, %{added: n, deleted: m}}`.
  """
  @spec rebuild_scope(String.t(), [map()], keyword()) ::
          {:ok, %{added: non_neg_integer(), deleted: non_neg_integer()}}
          | {:error, term()}
  def rebuild_scope(scope, docs, opts \\ []) when is_binary(scope) and is_list(docs) do
    {:ok, %{edges: raw_edges}} = project(scope, docs, opts)
    edges = bind_from_ids(raw_edges, Keyword.get(opts, :dataset, scope), opts)
    from_pks = corpus_from_pks(docs, opts)

    Repo.transaction(
      fn ->
        deleted = delete_outbound_for(from_pks)
        results = Content.add_edges(edges, add_opts(scope, opts))
        added = Enum.count(results, &match?({:ok, _}, &1))
        %{added: added, deleted: deleted}
      end,
      # EXPLICIT transaction budget — a CHOSEN bound, not the inherited 15s
      # adapter default. The batched write path (one endpoint-resolve query,
      # chunked insert_all, one reload) clears the largest measured corpus
      # (~4k docs) well inside this; a rebuild that cannot finish in 60s is
      # poisoned and must FAIL LOUDLY — the timeout raises, the worker returns
      # {:error, e}, Oban backs off and discards at max_attempts — rather than
      # hold the connection forever.
      timeout: 60_000
    )
  end

  @doc """
  Re-extract ONE doc's outbound edges and reconcile them against what is
  stored: ADD/replace the freshly-extracted set (via the `add_edge/4`
  on-conflict replace), then REMOVE any stored outbound edge of this doc that
  is no longer in the fresh set. The flag-ON incremental path.

  Operates on the doc's resolved PK; a doc with no resolvable PK (brand-new
  draft-only) projects no `from_id` and is a no-op. Returns
  `{:ok, %{added: n, removed: m}}`.
  """
  @spec upsert_record(map(), keyword()) ::
          {:ok, %{added: non_neg_integer(), removed: non_neg_integer()}}
          | {:error, term()}
  def upsert_record(doc, opts \\ []) when is_map(doc) do
    {:ok, %{edges: raw_edges}} = project("upsert", [doc], opts)
    edges = bind_from_ids(raw_edges, opts_scope(doc, opts), opts)

    case doc_pk(doc, opts) do
      nil ->
        {:ok, %{added: 0, removed: 0}}

      from_pk ->
        Repo.transaction(fn ->
          results = Content.add_edges(edges, add_opts(opts_scope(doc, opts), opts))
          added = Enum.count(results, &match?({:ok, _}, &1))

          kept_pks =
            results
            |> Enum.flat_map(fn
              {:ok, %Edge{to_id: to, kind: k}} -> [{to, k}]
              _ -> []
            end)
            |> MapSet.new()

          removed = remove_stale_outbound(from_pk, kept_pks)
          %{added: added, removed: removed}
        end)
    end
  end

  @doc """
  Delete EVERY `content_edges` row touching `doc` — both the outbound
  (`from_id`) and inbound (`to_id`) direction — so an unpublished/deleted doc
  leaves no stale edge on either side. Resolves the doc's PK first; with no
  resolvable PK there is nothing stored to delete. Returns
  `{:ok, deleted_count}`.
  """
  @spec delete_record(map(), keyword()) :: {:ok, non_neg_integer()}
  def delete_record(doc, opts \\ []) when is_map(doc) do
    case doc_pk(doc, opts) do
      nil ->
        {:ok, 0}

      pk ->
        {count, _} =
          Edge
          |> where([e], e.from_id == ^pk or e.to_id == ^pk)
          |> Repo.delete_all()

        {:ok, count}
    end
  end

  # ── Internals ──────────────────────────────────────────────────────────────

  # Rewrite each edge's slug `from_id` into the PK of a row of the SOURCE
  # DOC'S OWN TYPE, so a same-named document of another type can never claim
  # the edge (see `stamp_from_type/2`). `Content.add_edges/2`'s endpoint
  # resolution accepts a raw `documents.id` UUID as an endpoint by contract, so
  # a pre-bound `from_id` passes through it untouched.
  #
  # REFUSES LOUDLY. An edge whose typed source has no row under this scope is
  # DROPPED and named in the log — never re-bound to a same-named row of
  # another type, which is the exact silent mis-binding this closes.
  #
  # Edges carrying no `:from_type` (a plugin that bypassed `edges_for_doc/2`,
  # or a hand-built list in a test) are passed through UNCHANGED — byte-identical
  # to the pre-fix behaviour for every untyped caller.
  #
  # ONE query for the whole batch (`typed_pks/3`); the pre-fix path already
  # paid one batched resolve inside `add_edges/2`, so this adds a single
  # statement per rebuild, not an N+1.
  defp bind_from_ids([], _dataset, _opts), do: []

  defp bind_from_ids(edges, dataset, opts) do
    pairs =
      edges
      |> Enum.flat_map(fn e ->
        case {edge_from_id(e), edge_from_type(e)} do
          {from, type} when is_binary(from) and is_binary(type) ->
            [{Content.published_id(from), type}]

          _ ->
            []
        end
      end)
      |> Enum.uniq()

    pk_by_pair = typed_pks(pairs, dataset, opts)

    Enum.flat_map(edges, fn e ->
      case {edge_from_id(e), edge_from_type(e)} do
        {from, type} when is_binary(from) and is_binary(type) ->
          case Map.get(pk_by_pair, {Content.published_id(from), type}) do
            pk when is_binary(pk) ->
              [e |> Map.delete("from_id") |> Map.put(:from_id, pk)]

            nil ->
              Logger.warning(
                "EdgeProjector.Projector: REFUSING edge #{inspect(e[:kind] || e["kind"])} from " <>
                  "#{inspect(from)} — no #{inspect(type)} document under this scope. The edge is " <>
                  "DROPPED rather than bound to a same-named document of another type."
              )

              []
          end

        _ ->
          [e]
      end
    end)
  end

  # Batched, TYPE-PINNED slug -> pk resolution. Same contract as `doc_pk/2`
  # otherwise: the published row wins over its `drafts.` twin (the order_by),
  # the dataset + tenancy scope is the caller's, and an unresolvable pair is
  # simply absent from the map.
  defp typed_pks([], _dataset, _opts), do: %{}

  defp typed_pks(pairs, dataset, opts) do
    slugs = pairs |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    ids = slugs ++ Enum.map(slugs, &Content.draft_id/1)
    types = pairs |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

    Document
    |> where([d], d.doc_id in ^ids and d.type in ^types)
    |> maybe_scope_dataset(dataset)
    |> scope_doc_pk_to_workspace(opts)
    |> order_by([d], asc: fragment("CASE WHEN ? LIKE 'drafts.%' THEN 1 ELSE 0 END", d.doc_id))
    |> Repo.all()
    |> Enum.reduce(%{}, fn d, acc ->
      Map.put_new(acc, {Content.published_id(d.doc_id), d.type}, d.id)
    end)
  end

  # Resolve the corpus's published PKs so the rebuild can DELETE exactly the
  # outbound edges this corpus owns before re-adding. Drops docs whose PK can't
  # be resolved (nothing stored under them).
  defp corpus_from_pks(docs, opts) do
    docs
    |> Enum.map(fn doc -> doc_pk(doc, opts) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp delete_outbound_for([]), do: 0

  defp delete_outbound_for(pks) do
    {count, _} =
      Edge
      |> where([e], e.from_id in ^pks)
      |> Repo.delete_all()

    count
  end

  # Remove this doc's stored outbound edges that are NOT in the freshly-kept
  # set (the {to_id, kind} pairs the upsert just wrote). The diff that prunes
  # edges removed from the source doc.
  defp remove_stale_outbound(from_pk, kept_pairs) do
    stored = Content.list_outbound_edges(from_pk)

    stale =
      stored
      |> Enum.reject(fn e -> MapSet.member?(kept_pairs, {e.to_id, e.kind}) end)
      |> Enum.map(& &1.id)

    case stale do
      [] ->
        0

      ids ->
        {count, _} = Edge |> where([e], e.id in ^ids) |> Repo.delete_all()
        count
    end
  end

  # Resolve a doc to its published `documents.id` PK (publish-preferred), or nil.
  # Pure-ish read used ONLY on the write paths (never inside project/3).
  #
  # TENANCY FAIL-CLOSED (FIX 3). This PK resolution feeds the DELETE/prune side
  # of the projector — `corpus_from_pks/2 -> delete_outbound_for/1` (rebuild) and
  # `remove_stale_outbound/2` (upsert) and `delete_record/2`. Resolving by
  # `doc_id` + `dataset` ALONE ignores the workspace, so a colliding slug shared
  # across two tenants on the same dataset string could resolve to ANOTHER
  # tenant's row and DELETE its outbound edges (cross-tenant destruction). Thread
  # the caller's workspace scope through, mirroring `Content.scope_edge_endpoint`:
  # with `require_workspace: true` (the multi-tenant projector) use the STRICT
  # `Scope.scope_to_workspace/3` — a nil workspace FAILS CLOSED (`where: false`),
  # so a nil/unresolvable scope resolves to NOTHING rather than crossing tenants;
  # without the flag (single-tenant / unflagged callers) it is the documented
  # or-global back-compat resolution, byte-identical to before.
  defp doc_pk(doc, opts) do
    doc_id = Map.get(doc, :doc_id) || Map.get(doc, "doc_id")
    dataset = Map.get(doc, :dataset) || Map.get(doc, "dataset") || Keyword.get(opts, :dataset)

    if is_binary(doc_id) do
      pub = Content.published_id(doc_id)
      draft = Content.draft_id(pub)

      Document
      |> where([d], d.doc_id == ^pub or d.doc_id == ^draft)
      |> maybe_scope_dataset(dataset)
      |> maybe_scope_type(doc_type(doc))
      |> scope_doc_pk_to_workspace(opts)
      |> order_by([d], asc: fragment("CASE WHEN ? LIKE 'drafts.%' THEN 1 ELSE 0 END", d.doc_id))
      |> Repo.all()
      |> case do
        [%Document{id: pk} | _] -> pk
        _ -> nil
      end
    else
      nil
    end
  end

  defp maybe_scope_dataset(query, dataset) when is_binary(dataset) and dataset != "" do
    where(query, [d], d.dataset == ^dataset)
  end

  defp maybe_scope_dataset(query, _), do: query

  # The PRUNE half of the same type-blindness. `doc_pk/2` feeds
  # `corpus_from_pks/2 -> delete_outbound_for/1` (rebuild),
  # `remove_stale_outbound/2` (upsert) and `delete_record/2` — so an untyped
  # resolution could DELETE a same-named other-type document's edges and then
  # re-add the corpus's under a different pk, which is how a mis-binding
  # survives rebuild after rebuild. A doc always knows its own type; a doc map
  # carrying none (hand-built test input) resolves exactly as before.
  defp maybe_scope_type(query, type) when is_binary(type) and type != "" do
    where(query, [d], d.type == ^type)
  end

  defp maybe_scope_type(query, _), do: query

  # Tenancy scope for a write-path PK resolution. Mirrors
  # `Content.scope_edge_endpoint/2`: strict (fail-closed-on-nil) under
  # `require_workspace: true`, else the or-global back-compat resolution.
  defp scope_doc_pk_to_workspace(query, opts) do
    ws = Keyword.get(opts, :workspace_id)
    proj = Keyword.get(opts, :project_id)

    if Keyword.get(opts, :require_workspace, false) do
      Scope.scope_to_workspace(query, ws, proj)
    else
      Scope.scope_to_workspace_or_global(query, ws, proj)
    end
  end

  defp add_opts(scope, opts) do
    [dataset: Keyword.get(opts, :dataset, scope)]
    |> maybe_put(:workspace_id, Keyword.get(opts, :workspace_id))
    |> maybe_put(:project_id, Keyword.get(opts, :project_id))
    # FAIL-CLOSED tenancy (FIX 3) — forwarded to Content.add_edges/2 so a
    # multi-tenant projection refuses to resolve a nil-workspace endpoint
    # across tenants. The worker sets `:require_workspace` per Tenancy.multi_tenant?/0.
    |> maybe_put(:require_workspace, Keyword.get(opts, :require_workspace))
  end

  defp opts_scope(doc, opts) do
    Map.get(doc, :dataset) || Map.get(doc, "dataset") || Keyword.get(opts, :dataset, "production")
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
