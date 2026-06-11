defmodule Barkpark.Plugins.OnixEdit.Lifecycle do
  @moduledoc """
  Lifecycle-hook callbacks for OnixEdit (Goal `barkpark-9lq`).

  These functions are registered via `OnixEdit.lifecycle_hooks/0` and
  fired by `Barkpark.Plugins.Hooks` at the matching point in
  `Barkpark.Content.*`.

  Today the publisher clicks Publish in Studio and then has to click
  "Publish to Bokbasen" as a separate action. With the `after_publish`
  hook in place a normal Publish is enough — Studio writes the
  published document, `Content.publish_document/4` fires `:after_publish`,
  this module's hook fn inspects the doc, and (for `book` documents
  only) enqueues `Bokbasen.PublishWorker` to do the actual submission.
  The manual "Publish to Bokbasen" action stays on the editor header
  because it is still the way to run a dry-run preview and to retry
  after a rejection.

  The recursion guard is the most important behaviour here:
  `PublishWorker` writes published state back through
  `Content.publish_document/4` itself, which would otherwise re-fire
  `:after_publish` and re-enqueue the worker forever. The hook bails
  on `ctx.source == :worker` to break that loop.
  """

  require Logger

  alias Barkpark.Plugins.OnixEdit.Bokbasen.PublishWorker

  @doc """
  `after_publish` hook entry-point. Always returns `:ok` — hook
  failures must not crash downstream `after_*` hooks (the
  `Hooks` dispatcher discards return values for `after_*`, but
  treating every failure as a logged `:ok` keeps the contract honest
  and prevents accidental raises from killing the supervised task).

  Behaviour:

    * `ctx.source == :worker` → no-op. The PublishWorker writes the
      final `published` state back via `Content.publish_document/4`;
      without this guard each worker run would re-enqueue itself.
    * doc is not a `book` → no-op. Non-book documents do not go to
      Bokbasen.
    * otherwise → enqueue `PublishWorker` via `Oban.insert/1` with
      `%{"document_id" => id, "type" => "book", "dataset" => ds}` —
      the same arg shape `Actions.publish_to_bokbasen/3` already uses
      for the manual `:real` path.

  Oban-insert failures log at error level and still return `:ok`.
  """
  @spec publish_to_bokbasen_if_book(map()) :: :ok
  def publish_to_bokbasen_if_book(%{event: :after_publish, doc: doc, dataset: dataset, ctx: ctx}) do
    cond do
      Map.get(ctx || %{}, :source) == :worker ->
        :ok

      not is_book?(doc) ->
        :ok

      true ->
        enqueue(doc, dataset)
    end
  end

  def publish_to_bokbasen_if_book(_other), do: :ok

  # ── internals ────────────────────────────────────────────────────────────

  defp enqueue(doc, dataset) do
    id = doc_id(doc)

    # barkpark-zdvi — capture the published doc's tenancy scope into the job
    # args so the worker re-reads THIS tenant's book (not a same-dataset book
    # in another workspace). The `after_publish` payload hands us the
    # `%Document{}`, which carries workspace_id/project_id. Nil-safe: a doc
    # without scope (pre-tenancy / shapeless map) adds nothing.
    args =
      %{"document_id" => id, "type" => "book", "dataset" => dataset}
      |> PublishWorker.put_scope_args(scope_of(doc))

    case args |> PublishWorker.new() |> Oban.insert() do
      {:ok, job} ->
        Logger.info("OnixEdit.Lifecycle: enqueued Bokbasen PublishWorker job #{job.id} for #{id}")

        :ok

      {:error, reason} ->
        Logger.error(
          "OnixEdit.Lifecycle: failed to enqueue Bokbasen for #{id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  # Match both shapes Content callers hand us:
  #
  #   * `%Document{}` struct (atom keys) — what `Content.publish_document/4`
  #     hands the `after_publish` payload via `fire_after/3`.
  #   * plain map with string `"_type"` — defensive; mirrors
  #     `OnixEdit.resolve_doc_actions/2`, which reads string + atom keys.
  defp is_book?(%{type: "book"}), do: true
  defp is_book?(%{"_type" => "book"}), do: true
  defp is_book?(%{_type: "book"}), do: true
  defp is_book?(_), do: false

  defp doc_id(%{doc_id: id}) when is_binary(id), do: id
  defp doc_id(%{"_id" => id}) when is_binary(id), do: id
  defp doc_id(%{_id: id}) when is_binary(id), do: id
  defp doc_id(%{"id" => id}) when is_binary(id), do: id
  defp doc_id(%{id: id}) when is_binary(id), do: id
  defp doc_id(_), do: nil

  # Pull the tenancy scope off the published `%Document{}` (atom keys). The
  # `after_publish` payload always hands a struct, but we read defensively so
  # a string-keyed map / scope-less doc yields `[]` (no scope, Default
  # resolution — the pre-fix behaviour).
  defp scope_of(%{workspace_id: ws, project_id: proj}) do
    []
    |> maybe_scope(:workspace_id, ws)
    |> maybe_scope(:project_id, proj)
  end

  defp scope_of(_), do: []

  defp maybe_scope(opts, _key, nil), do: opts
  defp maybe_scope(opts, key, value), do: Keyword.put(opts, key, value)
end
