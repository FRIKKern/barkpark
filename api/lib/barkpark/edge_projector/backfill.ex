defmodule Barkpark.EdgeProjector.Backfill do
  @moduledoc """
  One-shot content-graph backfill sweep (wire §7.6 —
  `portabledoc-inline-liveref-taskchip-wire`).

  Edge projection is SAVE-EVENT-driven (`Content.fire_after/3` + the paper
  writers' `enqueue_edge_projection`), so a paper that predates the body-walk
  extractor has ZERO valueref / wikilink edges until it is re-touched. This
  sweep materialises them once: it enumerates every DISTINCT
  `(dataset, workspace_id)` scope that owns documents of the swept types
  (default `["paper"]`), lists each scope's PUBLISHED corpus exactly like
  `ProjectorWorker.run_rebuild_scoped/4` does, and hands it to
  `Projector.rebuild_scope/3` — the same atomic DELETE-then-`Content.add_edges`
  transaction the worker runs, so the backfill inherits the identical tenancy
  fail-closed scoping and self-edge/dangling rejection. No hand-rolled inserts.

  ## Safe by default

  `run/1` is a DRY RUN unless `dry_run: false` — it projects each scope's
  edges PURELY (`Projector.project/3`, no writes) and reports what a real run
  would hand to the write path. Prefer the Mix task:

      mix barkpark.edges.backfill            # dry-run: per-scope counts
      mix barkpark.edges.backfill --apply    # rebuild every scope

  ## Tenancy fail-closed

  Mirrors the worker's FIX-3 rule verbatim: in a MULTI-tenant install a scope
  whose `workspace_id` is nil is SKIPPED (a nil-workspace corpus would list —
  and materialise edges — across every tenant sharing the dataset string).
  Skipped scopes are surfaced in the stats, never silently dropped.

  Publish-gated by construction (D1): the corpus is `perspective: :published`,
  so draft-only papers contribute nothing until they publish.
  """

  import Ecto.Query, only: [from: 2, where: 3]

  require Logger

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.EdgeProjector.Projector
  alias Barkpark.Repo
  alias Barkpark.Tenancy

  @default_types ["paper"]
  # Rows per page of the corpus WALK (the server clamps a page to 1000), and the
  # bound on how many pages one scope sweep takes before it reports `:cap`.
  # 50 pages = 50,000 docs — twelve times the largest corpus `Projector`'s own
  # docs measure (~4k) and fifty times the cap this replaces, while still
  # bounding the in-memory fold and the 60s rebuild transaction. A scope past
  # that gets a `:cap` warning, never a silent prefix.
  @corpus_page_size 1000
  @corpus_max_pages 50

  @type scope_result :: %{
          dataset: String.t(),
          workspace_id: String.t() | nil,
          status: :dry_run | :rebuilt | :skipped_nil_workspace_multi_tenant | :error,
          docs: non_neg_integer(),
          truncated: boolean(),
          edges: non_neg_integer(),
          added: non_neg_integer(),
          deleted: non_neg_integer(),
          error: term() | nil
        }

  @type stats :: %{
          dry_run: boolean(),
          types: [String.t()],
          scopes: non_neg_integer(),
          rebuilt: non_neg_integer(),
          skipped: non_neg_integer(),
          errored: non_neg_integer(),
          added: non_neg_integer(),
          deleted: non_neg_integer(),
          results: [scope_result()]
        }

  @doc """
  Sweep every `(dataset, workspace_id)` scope owning docs of `:types`
  (default `["paper"]`) through a full `Projector.rebuild_scope/3`.

  `opts`:

    * `:dry_run` (default `true`) — project purely and count; write nothing.
    * `:types` (default `["paper"]`) — the corpus document types.
    * `:dataset` — narrow the sweep to one dataset string.

  Returns `{:ok, stats}` with per-scope results. Idempotent: `rebuild_scope`
  is an atomic swap of each corpus's outbound edges, so a re-run converges to
  the same rows.
  """
  @spec run(keyword()) :: {:ok, stats()}
  def run(opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, true)
    types = Keyword.get(opts, :types, @default_types)
    dataset_filter = Keyword.get(opts, :dataset)

    results =
      types
      |> distinct_scopes(dataset_filter)
      |> Enum.map(fn {dataset, ws} -> sweep_scope(dataset, ws, types, dry_run?) end)

    stats = %{
      dry_run: dry_run?,
      types: types,
      scopes: length(results),
      rebuilt: Enum.count(results, &(&1.status == :rebuilt)),
      skipped: Enum.count(results, &(&1.status == :skipped_nil_workspace_multi_tenant)),
      errored: Enum.count(results, &(&1.status == :error)),
      added: results |> Enum.map(& &1.added) |> Enum.sum(),
      deleted: results |> Enum.map(& &1.deleted) |> Enum.sum(),
      results: results
    }

    {:ok, stats}
  end

  # Every distinct (dataset, workspace_id) pair owning a doc of the swept
  # types — drafts included, so a scope whose papers are ALL drafts still gets
  # a (no-op) sweep rather than being invisibly missed.
  defp distinct_scopes(types, dataset_filter) do
    query =
      from(d in Document,
        where: d.type in ^types,
        distinct: true,
        select: {d.dataset, d.workspace_id}
      )

    query =
      case dataset_filter do
        ds when is_binary(ds) and ds != "" -> where(query, [d], d.dataset == ^ds)
        _ -> query
      end

    Repo.all(query)
  end

  defp sweep_scope(dataset, nil = _ws, types, dry_run?) do
    if Tenancy.multi_tenant?() do
      Logger.warning(
        "EdgeProjector.Backfill: scope dataset=#{dataset} has NO workspace_id in a " <>
          "multi-tenant install — skipping (fail-closed, mirrors ProjectorWorker FIX 3)"
      )

      scope_result(dataset, nil, :skipped_nil_workspace_multi_tenant)
    else
      do_sweep(dataset, nil, types, dry_run?)
    end
  end

  defp sweep_scope(dataset, ws, types, dry_run?), do: do_sweep(dataset, ws, types, dry_run?)

  defp do_sweep(dataset, ws, types, dry_run?) do
    list_opts =
      [perspective: :published, page_size: @corpus_page_size, max_pages: @corpus_max_pages]
      |> maybe_put(:workspace_id, ws)

    project_opts =
      [dataset: dataset]
      |> maybe_put(:workspace_id, ws)

    # WALK THE WHOLE CORPUS. This was `list_documents(limit: @corpus_limit)`,
    # and `list_documents/3` CLAMPS :limit to 1000 and returns a bare list — so
    # a scope with more than 1000 published docs of a type was swept from a
    # 1000-row PREFIX and `scope_result`'s `docs:` reported the CAP as though it
    # were the corpus size. `collect_all_documents/3` pages past the cap and
    # says `:cap` when its own bound stopped it, so a prefix can never again be
    # reported as a complete sweep.
    {docs, truncated} =
      types
      |> Enum.map_reduce(nil, fn type, trunc_acc ->
        {page, trunc} = Content.collect_all_documents(type, dataset, list_opts)
        {page, trunc_acc || trunc}
      end)
      |> then(fn {per_type, trunc} ->
        {per_type |> Enum.concat() |> Enum.map(&hydrate_task_edges/1), trunc}
      end)

    if truncated == :cap do
      Logger.warning(
        "EdgeProjector.Backfill: dataset=#{dataset} workspace=#{inspect(ws)} corpus walk hit " <>
          "its page cap at #{length(docs)} docs — the corpus is LARGER and this sweep is a " <>
          "PREFIX. Docs beyond the walk keep their pre-sweep edges."
      )
    end

    if dry_run? do
      {:ok, %{edges: edges}} = Projector.project(dataset, docs, project_opts)

      scope_result(dataset, ws, :dry_run,
        docs: length(docs),
        edges: length(edges),
        truncated: truncated == :cap
      )
    else
      case Projector.rebuild_scope(dataset, docs, project_opts) do
        {:ok, %{added: added, deleted: deleted}} ->
          scope_result(dataset, ws, :rebuilt,
            docs: length(docs),
            added: added,
            deleted: deleted,
            truncated: truncated == :cap
          )

        {:error, reason} ->
          Logger.error(
            "EdgeProjector.Backfill: rebuild failed for dataset=#{dataset} " <>
              "workspace=#{inspect(ws)}: #{inspect(reason)}"
          )

          scope_result(dataset, ws, :error, docs: length(docs), error: reason)
      end
    end
  end

  # Same purity seam the worker uses: hydrate a task doc's authoritative
  # `task_edges` rows BEFORE the pure projection (no-op for non-task docs), so
  # a `--types task,paper` sweep projects dependency edges identically.
  defp hydrate_task_edges(doc) when is_map(doc), do: Barkpark.Plugins.Tasks.hydrate_edges(doc)
  defp hydrate_task_edges(doc), do: doc

  defp scope_result(dataset, ws, status, extra \\ []) do
    %{
      dataset: dataset,
      workspace_id: ws,
      status: status,
      docs: Keyword.get(extra, :docs, 0),
      edges: Keyword.get(extra, :edges, 0),
      added: Keyword.get(extra, :added, 0),
      deleted: Keyword.get(extra, :deleted, 0),
      # TRUE when the corpus walk stopped at its page bound, so `docs` is a
      # PREFIX of the scope, not its size. A reader that ignores this field
      # reads a capped sweep as a complete one — the defect this retires.
      truncated: Keyword.get(extra, :truncated, false),
      error: Keyword.get(extra, :error)
    }
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # A truncated scope must never render as a bare doc count — that number is a
  # PREFIX, and reading it as the corpus size is the whole defect.
  defp truncated_note(%{truncated: true}), do: " (TRUNCATED — corpus is larger)"
  defp truncated_note(_), do: ""

  @doc """
  Log a one-line summary plus a per-scope line. Pure (no DB) — the `run/1`
  stats drive reporting; used by the Mix task.
  """
  @spec log_report(stats(), (String.t() -> any())) :: :ok
  def log_report(%{} = stats, emit) when is_function(emit, 1) do
    mode = if stats.dry_run, do: "DRY-RUN (no writes)", else: "APPLY (writes)"

    emit.("content-edge backfill — #{mode} — types #{inspect(stats.types)}")
    emit.("  scopes swept:  #{stats.scopes}")

    if stats.dry_run do
      Enum.each(stats.results, fn r ->
        emit.(
          "    • #{r.dataset} (ws #{r.workspace_id || "-"}) — #{r.docs} doc(s)#{truncated_note(r)}, " <>
            "#{r.edges} projected edge(s)"
        )
      end)
    else
      emit.("  rebuilt:       #{stats.rebuilt}")
      emit.("  edges added:   #{stats.added}")
      emit.("  edges deleted: #{stats.deleted}")

      Enum.each(stats.results, fn r ->
        emit.(
          "    • #{r.dataset} (ws #{r.workspace_id || "-"}) — #{r.status}: " <>
            "#{r.docs} doc(s)#{truncated_note(r)}, +#{r.added}/-#{r.deleted}"
        )
      end)
    end

    truncated = Enum.count(stats.results, &Map.get(&1, :truncated, false))

    if truncated > 0 do
      emit.(
        "  !! #{truncated} scope(s) TRUNCATED — the corpus walk hit its page bound, so the " <>
          "doc counts above are PREFIXES and those scopes were only partially swept"
      )
    end

    if stats.skipped > 0 do
      emit.("  !! skipped #{stats.skipped} nil-workspace scope(s) (multi-tenant fail-closed)")
    end

    if stats.errored > 0 do
      emit.("  !! #{stats.errored} scope(s) ERRORED — see logs")
    end

    :ok
  end
end
