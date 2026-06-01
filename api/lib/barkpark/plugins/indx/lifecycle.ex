defmodule Barkpark.Plugins.Indx.Lifecycle do
  @moduledoc """
  Lifecycle-hook callbacks for the Indx plugin (mirrors the
  OnixEdit lifecycle-hook precedent).

  Registered via `Barkpark.Plugins.Indx.lifecycle_hooks/0` and fired by
  `Barkpark.Plugins.Hooks` at the matching point in `Barkpark.Content.*`.

  Every hook is the SAME fast (<100ms) function: it reads the doc's scope
  (dataset + type) and enqueues a DEBOUNCED `IndexerWorker` job for that
  scope. It never indexes inline — the actual blue/green rebuild happens
  in the Oban worker, off the request path. Four events bracket the four
  mutating Content ops:

    * `:after_save`      — a doc was created/updated
    * `:after_publish`   — a draft was published
    * `:after_unpublish` — a published doc went back to draft
    * `:after_delete`    — a doc was removed

  All four want the same thing: the scope's corpus changed, so rebuild it.

  ## Recursion guard

  `IndexerWorker` does NOT write documents back through `Content.*`, so it
  cannot re-fire these hooks the way a Content-writing worker can. The
  guard is kept anyway as defense-in-depth: any hook firing with
  `ctx.source == :worker` is a no-op, so a future worker that touches
  Content can never trigger an index-rebuild storm.
  """

  require Logger

  alias Barkpark.Plugins.Indx.IndexerWorker

  @after_events [:after_save, :after_publish, :after_unpublish, :after_delete]

  @doc """
  The single fast hook fn registered for all four `after_*` events.
  Always returns `:ok` — a hook failure must never crash the mutating
  Content op or sibling hooks.

  No-ops on:
    * `ctx.source == :worker` (recursion guard)
    * a payload with no resolvable dataset

  Otherwise enqueues a debounced `IndexerWorker` rebuild for the doc's
  scope, passing the doc's `type` so the worker lists the right corpus.
  """
  @spec enqueue_rebuild(map()) :: :ok
  def enqueue_rebuild(%{event: event, doc: doc, dataset: dataset, ctx: ctx})
      when event in @after_events do
    cond do
      Map.get(ctx || %{}, :source) == :worker ->
        :ok

      not is_binary(dataset) or dataset == "" ->
        :ok

      true ->
        do_enqueue(doc, dataset)
    end
  end

  def enqueue_rebuild(_other), do: :ok

  defp do_enqueue(doc, dataset) do
    opts =
      [types: types_of(doc)]
      |> maybe_scope(:workspace_id, scope_field(doc, :workspace_id))
      |> maybe_scope(:project_id, scope_field(doc, :project_id))

    case IndexerWorker.enqueue(dataset, opts) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "Indx.Lifecycle: failed to enqueue rebuild for dataset=#{dataset}: #{inspect(reason)}"
        )

        :ok
    end
  end

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
