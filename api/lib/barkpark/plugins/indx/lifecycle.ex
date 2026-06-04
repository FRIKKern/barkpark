defmodule Barkpark.Plugins.Indx.Lifecycle do
  @moduledoc """
  Lifecycle-hook callbacks for the Indx plugin (mirrors the
  OnixEdit lifecycle-hook precedent).

  Registered via `Barkpark.Plugins.Indx.lifecycle_hooks/0` and fired by
  `Barkpark.Plugins.Hooks` at the matching point in `Barkpark.Content.*`.

  Every hook is the SAME fast (<100ms) function: it reads the doc's scope
  (dataset + type) and enqueues a DEBOUNCED `IndexerWorker` job for that
  scope. It never indexes inline — the actual index work happens in the
  Oban worker, off the request path. Four events bracket the four mutating
  Content ops, routed by the `incremental_upsert` feature flag:

    * `:after_save`      — a doc was created/updated → REBUILD op (flag OFF,
      default) | UPSERT op (flag ON)
    * `:after_publish`   — a draft was published     → REBUILD op (flag OFF,
      default) | UPSERT op (flag ON)
    * `:after_unpublish` — a published doc went back to draft → DELETE op
      (always — delete is already incremental)
    * `:after_delete`    — a doc was removed          → DELETE op (always)

  ## The feature flag (default OFF → prod byte-identical)

  `Settings.get().incremental_upsert` gates the add/update path ONLY:

    * OFF (the DEFAULT) → add/update take the safe blue/green REBUILD path —
      TODAY's behaviour exactly. With the flag off the entire incremental
      add/update path is INERT; prod behaviour is unchanged.
    * ON → add/update route to the per-document incremental UPSERT op
      (`Indexer.upsert_record/3`), carrying the doc's `_id` + type. This
      mutates a LIVE dataset and is UNPROVEN until spiked against a real v5
      Indx instance.

  delete/unpublish are ALWAYS incremental (no flag): they only need the
  doc's row GONE from the live index — a targeted per-document DELETE
  (`Indexer.delete_record/3`), no full rebuild. The delete op carries the
  doc's `_id` (and its type, for the reindex-required rebuild fallback).
  Unpublish is modelled as a delete because the default `published`
  perspective should stop returning a doc the moment it leaves published
  state; the next publish re-adds it (via rebuild when the flag is off, via
  upsert when on).

  ## Recursion guard

  `IndexerWorker` does NOT write documents back through `Content.*`, so it
  cannot re-fire these hooks the way a Content-writing worker can. The
  guard is kept anyway as defense-in-depth: any hook firing with
  `ctx.source == :worker` is a no-op, so a future worker that touches
  Content can never trigger an index-rebuild storm.
  """

  require Logger

  alias Barkpark.Plugins.Indx.IndexerWorker
  alias Barkpark.Plugins.Indx.Settings

  @after_events [:after_save, :after_publish, :after_unpublish, :after_delete]
  @rebuild_events [:after_save, :after_publish]
  @delete_events [:after_unpublish, :after_delete]

  @doc """
  The single fast hook fn registered for all four `after_*` events.
  Always returns `:ok` — a hook failure must never crash the mutating
  Content op or sibling hooks.

  No-ops on:
    * `ctx.source == :worker` (recursion guard)
    * a payload with no resolvable dataset

  Routes by event:
    * `:after_save` / `:after_publish` → debounced REBUILD job (flag OFF,
      default) or debounced UPSERT job carrying the doc `_id` (flag ON);
      falls through to a rebuild when ON if the doc has no resolvable `_id`.
    * `:after_unpublish` / `:after_delete` → debounced DELETE job (carries
      the doc `_id`); falls through to a rebuild only if the doc has no
      resolvable `_id`.
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

      event in @rebuild_events ->
        route_save(doc, dataset)

      true ->
        :ok
    end
  end

  def enqueue_rebuild(_other), do: :ok

  # add/update routing gated by the incremental_upsert flag. OFF (default) →
  # the blue/green REBUILD op (today's behaviour, byte-identical). ON → the
  # per-document UPSERT op carrying the doc _id; with no resolvable _id we
  # cannot target a key, so fall back to a rebuild (never leave the index
  # stale).
  defp route_save(doc, dataset) do
    if incremental_upsert?() do
      do_enqueue_upsert(doc, dataset)
    else
      do_enqueue_rebuild(doc, dataset)
    end
  end

  defp incremental_upsert? do
    Settings.get().incremental_upsert == true
  rescue
    # Settings.get/0 never raises by contract, but a misconfigured DB read
    # must never crash a lifecycle hook — degrade to the safe rebuild path.
    _ -> false
  end

  defp do_enqueue_upsert(doc, dataset) do
    case doc_id(doc) do
      id when is_binary(id) and id != "" ->
        finish(IndexerWorker.enqueue_upsert(dataset, id, scope_opts(doc)), dataset, "upsert")

      _ ->
        do_enqueue_rebuild(doc, dataset)
    end
  end

  defp do_enqueue_rebuild(doc, dataset) do
    finish(IndexerWorker.enqueue(dataset, scope_opts(doc)), dataset, "rebuild")
  end

  # Delete by the doc's _id. The type is still forwarded so the worker's
  # reindex-required fallback can list the corpus. If the doc has no
  # resolvable _id we cannot target a key → fall back to a rebuild so the
  # live index is never left stale.
  defp do_enqueue_delete(doc, dataset) do
    case doc_id(doc) do
      id when is_binary(id) and id != "" ->
        finish(IndexerWorker.enqueue_delete(dataset, id, scope_opts(doc)), dataset, "delete")

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
      "Indx.Lifecycle: failed to enqueue #{op} for dataset=#{dataset}: #{inspect(reason)}"
    )

    :ok
  end

  # The doc's Barkpark _id. A %Document{} carries it as :doc_id; map
  # shapes use "_id"/:_id. Mirrors Indexer.doc_id/1's key precedence.
  defp doc_id(%{doc_id: id}) when is_binary(id) and id != "", do: id
  defp doc_id(%{"_id" => id}) when is_binary(id) and id != "", do: id
  defp doc_id(%{_id: id}) when is_binary(id) and id != "", do: id
  defp doc_id(%{"doc_id" => id}) when is_binary(id) and id != "", do: id
  defp doc_id(_), do: nil

  # Read the doc's type from either struct (atom `:type`) or map
  # (string `"_type"`) shape. Returns a single-element list so the worker
  # rebuilds just the changed type's slice of the corpus.
  defp types_of(%{type: t}) when is_binary(t) and t != "", do: [t]
  defp types_of(%{"_type" => t}) when is_binary(t) and t != "", do: [t]
  defp types_of(%{_type: t}) when is_binary(t) and t != "", do: [t]
  defp types_of(_), do: []

  defp scope_field(%{} = doc, key) do
    Map.get(doc, key) || Map.get(doc, Atom.to_string(key))
  end

  defp scope_field(_, _), do: nil

  defp maybe_scope(opts, _key, nil), do: opts
  defp maybe_scope(opts, key, value), do: Keyword.put(opts, key, value)
end
