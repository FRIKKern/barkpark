defmodule Barkpark.EdgeProjector.Lifecycle do
  @moduledoc """
  Routes the four `after_*` Content events to the right `ProjectorWorker` op,
  mirroring `Barkpark.Plugins.Indx.Lifecycle`.

  ## Invoked from TWO places

    1. The CORE wiring in `Barkpark.Content.fire_after/3` — called DIRECTLY
       (not through the plugin Hooks dispatch) on every mutating Content op, so
       the content graph projects even with ALL plugins off. This is the
       load-bearing fresh-install hook: `Barkpark.Plugins.Hooks.fire/2`
       dispatches only to plugins' `lifecycle_hooks/0`, and core is not a
       plugin, so without the direct call a plugins-`[]` install never projects.
    2. (Future) a plugin's `lifecycle_hooks/0` MAY also register this if a
       plugin wants graph projection on its own non-core event surface.

  ## Event → op routing

    * `:after_save`      — a doc was created/updated → REBUILD op (flag OFF,
      default) | UPSERT op (flag ON) — debounced (autosave bursts collapse).
    * `:after_publish`   — a draft was published      → SYNCHRONOUS per-doc
      UPSERT, inline, before this hook returns (task-3fd3c0c53d08a6bd — see
      below). Falls back to the debounced path (same as `:after_save`) on any
      failure, so the graph is never left stale.
    * `:after_unpublish` — a published doc went back to draft → DELETE op
      (always — the published graph must stop showing it the moment it leaves
      published state; the next publish re-projects it). Modelled as a delete,
      mirroring Indx.
    * `:after_delete`    — a doc was removed          → DELETE op (always)

  ## The feature flag (default OFF)

  `Settings.get().incremental_project` gates the `:after_save` add/update path
  ONLY:

    * OFF (the DEFAULT) → save takes the deterministic full per-scope REBUILD
      path. Inert incremental path.
    * ON  → save routes to the per-document incremental UPSERT op. A mis-diff
      strands stale edges in the durable table (no blue/green to discard,
      unlike Indx) — UNPROVEN, spike-gated.

  `:after_publish` no longer reads this flag (see below) — it always runs the
  bounded per-doc upsert, synchronously. delete/unpublish are ALWAYS
  incremental (no flag): the doc's edges just need to be GONE.

  ## Why `:after_publish` is synchronous (task-3fd3c0c53d08a6bd)

  Both `:after_save` and `:after_publish` used to share the SAME 5-second
  debounced `ProjectorWorker` job (`@debounce_seconds` there). That gave
  neither direction of an edge change (add OR remove) any promptness
  GUARANTEE: `publish_document/4` — and the broadcast/listen-frame it fires —
  returned the instant the job was *enqueued*, long before the job *ran*.

  Measured (barkpark-studio, guerrilla e2e-sanity, 2026-10-09): a reference
  change looked "prompt" (visible in well under 50ms) on some docs and
  "laggy" (3-6s) on others. The difference was never the write path (`patch`
  vs `createOrReplace` — both resolve to the SAME stable published-row PK;
  `Projector.upsert_record/2` diffs and prunes correctly either way, confirmed
  directly). It was purely Oban's own unique-job dedup: `ProjectorWorker`
  dedups `(op, …, _id, types)` across `:available`/`:scheduled`/`:executing`,
  so repeated writes to the same doc within the SAME 5s window are silently
  swallowed (no new schedule) — meaning the APPARENT latency any later read
  observes is just "however much of some EARLIER job's window happened to be
  left," which can look anywhere from instant (a stale, nearly-due job) to a
  full fresh 5s (a job that just (re)armed on the most recent write). A doc
  that received an extra write shortly before the one under test (e.g. a
  `createOrReplace` re-save) simply re-armed a fresh window right before the
  measurement, while a doc with only one prior write often had an already-due
  job by the time it was measured — same mechanism, different luck.

  The fix makes `:after_publish` NOT rely on that luck: it runs
  `Projector.upsert_record/2` for the one just-published doc inline, so by the
  time `publish_document/4` returns, `content_edges` already reflects both the
  new edge and the pruned stale one. This is safe to always run (regardless of
  the `incremental_project` flag) because it is bounded to ONE document's own
  extract + diff — not a corpus-wide rebuild.

  ## Recursion guard

  `ctx.source == :worker` is a no-op. The projector writes the `content_edges`
  table, not documents through `Content.*`, so it cannot re-fire these hooks
  today. The guard is defense-in-depth: if a future projector path EVER
  re-saves a doc it MUST stamp `ctx.source == :worker`, or `fire_after/3` will
  re-enqueue indefinitely (see the invariant note at `Content.fire_after/3`).
  When the payload has no `:ctx`, `source` is treated as nil → enqueue.
  """

  require Logger

  alias Barkpark.EdgeProjector.Projector
  alias Barkpark.EdgeProjector.ProjectorWorker
  alias Barkpark.EdgeProjector.Settings
  alias Barkpark.Tenancy

  @after_events [:after_save, :after_publish, :after_unpublish, :after_delete]
  @save_events [:after_save]
  @delete_events [:after_unpublish, :after_delete]

  @doc """
  The single fast hook fn for all four `after_*` events. Always returns `:ok`
  — a projection-enqueue failure must never crash the mutating Content op.

  No-ops on:
    * `ctx.source == :worker` (recursion guard)
    * a payload with no resolvable dataset

  Routes:
    * `:after_save` → debounced REBUILD job (flag OFF, default) or debounced
      UPSERT job carrying the doc `_id` (flag ON); falls through to a rebuild
      when ON if the doc has no resolvable `_id`.
    * `:after_publish` → SYNCHRONOUS per-doc upsert, inline (see moduledoc);
      falls back to the same debounced path as `:after_save` on any failure
      or a doc with no resolvable `_id`.
    * `:after_unpublish` / `:after_delete` → debounced DELETE job (carries the
      doc `_id`); falls through to a rebuild only if the doc has no resolvable
      `_id`.
  """
  @spec enqueue_rebuild(map()) :: :ok
  def enqueue_rebuild(%{event: event, doc: doc, dataset: dataset, ctx: ctx})
      when event in @after_events do
    cond do
      Map.get(ctx || %{}, :source) == :worker ->
        :ok

      not is_binary(dataset) or dataset == "" ->
        :ok

      event in @delete_events ->
        do_enqueue_delete(doc, dataset)

      event == :after_publish ->
        route_publish(doc, dataset)

      event in @save_events ->
        route_save(doc, dataset)

      true ->
        :ok
    end
  end

  # The Content payload may omit :dataset/:ctx (e.g. the bare fire_after map).
  # Resolve the dataset off the doc when the payload key is absent, and treat a
  # missing :ctx as source nil → enqueue.
  def enqueue_rebuild(%{event: event, doc: doc} = payload) when event in @after_events do
    dataset = Map.get(payload, :dataset) || dataset_of(doc)
    ctx = Map.get(payload, :ctx)
    enqueue_rebuild(%{event: event, doc: doc, dataset: dataset, ctx: ctx})
  end

  def enqueue_rebuild(_other), do: :ok

  # add/update routing gated by the incremental_project flag. OFF (default) →
  # the full per-scope REBUILD op. ON → the per-document UPSERT op carrying the
  # doc _id; with no resolvable _id we cannot target a doc, so fall back to a
  # rebuild (never leave the graph stale).
  defp route_save(doc, dataset) do
    if incremental_project?() do
      do_enqueue_upsert(doc, dataset)
    else
      do_enqueue_rebuild(doc, dataset)
    end
  end

  # PUBLISH: a bounded, synchronous per-doc upsert — no flag, no debounce (see
  # moduledoc, task-3fd3c0c53d08a6bd). A doc with no resolvable `_id` cannot be
  # targeted at all, so it takes the same debounced-rebuild fallback `:after_save`
  # uses. A resolvable doc that fails to upsert synchronously (a raised
  # exception, or `{:error, _}` from the projector) falls back to the
  # debounced per-doc upsert job rather than losing the write outright — the
  # graph ends up correct a little late instead of not at all.
  defp route_publish(doc, dataset) do
    case doc_id(doc) do
      id when is_binary(id) and id != "" ->
        case upsert_now(doc, id, dataset) do
          :ok -> :ok
          :fallback -> do_enqueue_upsert(doc, dataset)
        end

      _ ->
        do_enqueue_rebuild(doc, dataset)
    end
  end

  defp upsert_now(doc, id, dataset) do
    ws = scope_field(doc, :workspace_id)

    project_opts =
      [dataset: dataset]
      |> maybe_scope(:workspace_id, ws)
      |> maybe_scope(:project_id, scope_field(doc, :project_id))
      |> maybe_scope(:require_workspace, require_workspace?(ws))

    case Projector.upsert_record(doc, project_opts) do
      {:ok, %{added: added, removed: removed}} ->
        Logger.info(
          "EdgeProjector.Lifecycle: synchronous publish-upsert _id=#{id} dataset=#{dataset} " <>
            "added=#{added} removed=#{removed}"
        )

        :ok

      {:error, reason} ->
        Logger.error(
          "EdgeProjector.Lifecycle: synchronous publish-upsert FAILED for _id=#{id} " <>
            "dataset=#{dataset}: #{inspect(reason)} — falling back to the debounced path"
        )

        :fallback
    end
  rescue
    e ->
      Logger.error(
        "EdgeProjector.Lifecycle: synchronous publish-upsert RAISED for _id=#{id} " <>
          "dataset=#{dataset}, falling back to the debounced path: " <> Exception.message(e)
      )

      :fallback
  end

  # Mirrors `ProjectorWorker`'s own `require_workspace?/1`: a nil workspace in
  # a multi-tenant install fails the endpoint resolution closed rather than
  # resolving across tenants; a single-tenant install (or a resolved
  # workspace) keeps the or-global back-compat resolution.
  defp require_workspace?(nil), do: Tenancy.multi_tenant?()
  defp require_workspace?(ws) when is_binary(ws), do: false

  defp incremental_project? do
    Settings.get().incremental_project == true
  rescue
    # Settings.get/0 never raises by contract, but a misconfigured DB read must
    # never crash a lifecycle hook — degrade to the safe rebuild path.
    _ -> false
  end

  defp do_enqueue_upsert(doc, dataset) do
    case doc_id(doc) do
      id when is_binary(id) and id != "" ->
        finish(ProjectorWorker.enqueue_upsert(dataset, id, scope_opts(doc)), dataset, "upsert")

      _ ->
        do_enqueue_rebuild(doc, dataset)
    end
  end

  defp do_enqueue_rebuild(doc, dataset) do
    finish(ProjectorWorker.enqueue(dataset, scope_opts(doc)), dataset, "rebuild")
  end

  defp do_enqueue_delete(doc, dataset) do
    case doc_id(doc) do
      id when is_binary(id) and id != "" ->
        finish(ProjectorWorker.enqueue_delete(dataset, id, scope_opts(doc)), dataset, "delete")

      _ ->
        do_enqueue_rebuild(doc, dataset)
    end
  end

  defp scope_opts(doc) do
    [types: types_of(doc)]
    |> maybe_scope(:workspace_id, scope_field(doc, :workspace_id))
    |> maybe_scope(:project_id, scope_field(doc, :project_id))
  end

  defp finish({:ok, _job}, _dataset, _op), do: :ok

  defp finish({:error, reason}, dataset, op) do
    Logger.error(
      "EdgeProjector.Lifecycle: failed to enqueue #{op} for dataset=#{dataset}: #{inspect(reason)}"
    )

    :ok
  end

  # The doc's Barkpark _id. A %Document{} carries it as :doc_id; map shapes use
  # "_id"/:_id. Mirrors Indexer.doc_id/1's key precedence.
  defp doc_id(%{doc_id: id}) when is_binary(id) and id != "", do: id
  defp doc_id(%{"_id" => id}) when is_binary(id) and id != "", do: id
  defp doc_id(%{_id: id}) when is_binary(id) and id != "", do: id
  defp doc_id(%{"doc_id" => id}) when is_binary(id) and id != "", do: id
  defp doc_id(_), do: nil

  # Read the doc's type from either struct (atom `:type`) or map (string
  # `"_type"`/`"type"`) shape. Single-element list so the worker rebuilds just
  # the changed type's slice of the corpus.
  defp types_of(%{type: t}) when is_binary(t) and t != "", do: [t]
  defp types_of(%{"_type" => t}) when is_binary(t) and t != "", do: [t]
  defp types_of(%{_type: t}) when is_binary(t) and t != "", do: [t]
  defp types_of(%{"type" => t}) when is_binary(t) and t != "", do: [t]
  defp types_of(_), do: []

  defp dataset_of(%{dataset: d}) when is_binary(d) and d != "", do: d
  defp dataset_of(%{"dataset" => d}) when is_binary(d) and d != "", do: d
  defp dataset_of(_), do: nil

  defp scope_field(%{} = doc, key) do
    Map.get(doc, key) || Map.get(doc, Atom.to_string(key))
  end

  defp scope_field(_, _), do: nil

  defp maybe_scope(opts, _key, nil), do: opts
  defp maybe_scope(opts, key, value), do: Keyword.put(opts, key, value)
end
