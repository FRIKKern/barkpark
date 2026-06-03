defmodule Barkpark.Plugins.Indx.IndexerWorker do
  @moduledoc """
  Oban worker that drives a debounced BLUE/GREEN rebuild of one scope's
  search corpus into the dedicated Indx instance.

  ## Queue + uniqueness

  Runs on the `:indx` queue. Unique on the `scope` partition key over a
  debounce window (`@debounce_seconds`) across `:available` / `:scheduled`
  / `:executing` — so a burst of saves to the same scope collapses into a
  single rebuild instead of one rebuild per document. This is the whole
  reason the lifecycle hooks enqueue a SCOPE rebuild rather than touching
  the index per-document (and it dovetails with the spike's serialise-loads
  rule).

  ## Two ops

  The job carries an `"op"` discriminator:

    * `"op" => "rebuild"` (default) — today's BLUE/GREEN full rebuild of
      the whole scope corpus. Routed by `:after_save` / `:after_publish`.
    * `"op" => "delete"` — INCREMENTAL per-document delete of a single
      `"_id"` from the CURRENT live dataset, no rebuild. Routed by
      `:after_delete` / `:after_unpublish`.

  ## perform/1 — rebuild op

    1. List the scope's corpus via `Barkpark.Content.list_documents/3`
       for each declared `type` at the requested `perspective`.
    2. Hand the corpus to `Indexer.rebuild/3` (blue/green: loads into a
       fresh `<prefix>_<scope>_v<n>`, NEVER re-loads a live dataset).
    3. On success, `Indexer.swap/2` flips the live pointer, then
       `Indexer.delete_dataset/2` drops the old dataset.

  ## perform/1 — delete op

    1. `Indexer.delete_record/3` computes the stable key for `"_id"` and
       DELETEs it from the live dataset.
    2. `:ok` → done. `{:reindex_required, _}` → fall back to a FULL
       rebuild (enqueue + await a rebuild-op job for the same scope) so
       the change becomes query-visible. `{:error, _}` → normal Oban
       error/backoff (NetworkError still snoozes).

  ## Job args (string-keyed, Oban-serialised)

      %{
        "op"          => "rebuild" | "delete",  # default "rebuild"
        "scope"       => "production",          # dataset string (required)
        "types"       => ["post", "page"],      # doc types to index (rebuild)
        "perspective" => "published",           # default "published"
        "_id"         => "drafts.p1",           # delete op only (required)
        "workspace_id"=> "...",                 # optional tenancy scope
        "project_id"  => "...",                  # optional tenancy scope
        "indexer"     => "..."                   # TEST-ONLY indexer module override
      }

  The `"indexer"` arg is a test seam (a module name string) — never set by
  the lifecycle enqueue paths, so production always uses the real
  `Indexer`.

  ## Indx-down tolerance

  A `NetworkError` from the client (Indx unreachable) → `{:snooze, N}` so
  the rebuild retries later without burning an Oban attempt. Other Indx
  errors (`IndexError` / `SearchError` / `AuthError`) → `{:error, reason}`
  so Oban applies its normal backoff. A missing/empty `types` list →
  `{:cancel, reason}` (nothing to index, not a transient failure).
  """

  # Uniqueness keyed on `(op, scope, _id)`:
  #   * rebuild jobs carry NO `_id` → they dedup on `(rebuild, scope, nil)`,
  #     i.e. unique per scope (today's behaviour, preserved).
  #   * delete jobs carry an `_id` → they dedup on `(delete, scope, _id)`,
  #     i.e. unique per (scope, _id) — many distinct deletes in a burst all
  #     enqueue, repeated deletes of the SAME doc collapse.
  use Oban.Worker,
    queue: :indx,
    max_attempts: 5,
    unique: [
      keys: [:op, :scope, :_id],
      states: [:available, :scheduled, :executing],
      period: 30
    ]

  require Logger

  alias Barkpark.Content
  alias Barkpark.Plugins.Indx.Errors.NetworkError
  alias Barkpark.Plugins.Indx.Indexer

  @debounce_seconds 5
  @snooze_seconds 60

  @doc """
  Build a debounced REBUILD job for `scope` (the default op). The
  lifecycle hooks call this with a fast (<100ms) hand-off — it only
  constructs and inserts the job.

  Schedules the job `@debounce_seconds` in the future so a burst of saves
  to the same scope collapses (combined with the `unique` clause). `opts`
  may carry `:types`, `:perspective`, `:workspace_id`, `:project_id`.
  """
  @spec enqueue(String.t(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(scope, opts \\ []) when is_binary(scope) do
    %{
      "op" => "rebuild",
      "scope" => scope,
      "types" => Keyword.get(opts, :types, []),
      "perspective" => to_string(Keyword.get(opts, :perspective, "published")),
      "workspace_id" => Keyword.get(opts, :workspace_id),
      "project_id" => Keyword.get(opts, :project_id)
    }
    |> drop_nil()
    |> new(schedule_in: @debounce_seconds)
    |> Oban.insert()
  end

  @doc """
  Build a debounced DELETE job removing a single `id` from `scope`'s live
  dataset. Routed by `:after_delete` / `:after_unpublish`. Unique per
  `(scope, id)` so repeated deletes of the same doc collapse while
  distinct deletes in a burst all enqueue. `opts` may carry `:types`,
  `:workspace_id`, `:project_id` (forwarded to the reindex-fallback
  rebuild).
  """
  @spec enqueue_delete(String.t(), String.t(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_delete(scope, id, opts \\ []) when is_binary(scope) and is_binary(id) do
    %{
      "op" => "delete",
      "scope" => scope,
      "_id" => id,
      "types" => Keyword.get(opts, :types, []),
      "perspective" => to_string(Keyword.get(opts, :perspective, "published")),
      "workspace_id" => Keyword.get(opts, :workspace_id),
      "project_id" => Keyword.get(opts, :project_id)
    }
    |> drop_nil()
    |> new(schedule_in: @debounce_seconds)
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    scope = Map.get(args, "scope")
    op = Map.get(args, "op", "rebuild")

    cond do
      not is_binary(scope) or scope == "" ->
        {:cancel, :missing_scope}

      op == "delete" ->
        run_delete(scope, args)

      true ->
        run_rebuild_op(scope, args)
    end
  end

  defp run_rebuild_op(scope, args) do
    types = Map.get(args, "types", [])
    perspective = perspective_atom(Map.get(args, "perspective", "published"))

    if not is_list(types) or types == [] do
      {:cancel, :no_types}
    else
      run_rebuild(scope, types, perspective, args)
    end
  end

  # Per-document incremental delete. Reindex-required → fall back to a full
  # rebuild for the scope (await it inline so this job's success reflects a
  # query-visible result). NetworkError snoozes; other errors backoff.
  defp run_delete(scope, args) do
    id = Map.get(args, "_id")

    if not is_binary(id) or id == "" do
      {:cancel, :missing_id}
    else
      case indexer_mod(args).delete_record(scope, id) do
        :ok ->
          Logger.info("Indx.IndexerWorker: deleted _id=#{id} from scope=#{scope}")
          :ok

        {:reindex_required, _status} ->
          Logger.info(
            "Indx.IndexerWorker: delete of _id=#{id} on scope=#{scope} requires reindex — " <>
              "falling back to full rebuild"
          )

          rebuild_fallback(scope, args)

        {:error, %NetworkError{} = err} ->
          Logger.warning(
            "Indx.IndexerWorker: Indx unreachable on delete scope=#{scope}, snoozing: #{inspect(err)}"
          )

          {:snooze, @snooze_seconds}

        {:error, err} ->
          Logger.error(
            "Indx.IndexerWorker: delete of _id=#{id} failed for scope=#{scope}: #{inspect(err)}"
          )

          {:error, err}
      end
    end
  end

  # Reindex-required fallback: run the SAME blue/green rebuild the rebuild
  # op runs, inline, for the affected scope. Needs the doc types — the
  # delete job carries them so the corpus listing is correct. With no types
  # we cancel (nothing to rebuild) rather than fail the job forever.
  defp rebuild_fallback(scope, args) do
    types = Map.get(args, "types", [])
    perspective = perspective_atom(Map.get(args, "perspective", "published"))

    if not is_list(types) or types == [] do
      {:cancel, :no_types_for_reindex_fallback}
    else
      run_rebuild(scope, types, perspective, args)
    end
  end

  defp run_rebuild(scope, types, perspective, args) do
    list_opts =
      [perspective: perspective, limit: 1000]
      |> maybe_put(:workspace_id, Map.get(args, "workspace_id"))
      |> maybe_put(:project_id, Map.get(args, "project_id"))

    indexer = indexer_mod(args)

    docs =
      Enum.flat_map(types, fn type ->
        Content.list_documents(type, scope, list_opts)
      end)

    case indexer.rebuild(scope, docs) do
      {:ok, result} ->
        old = indexer.swap(scope, result)
        indexer.delete_dataset(old, [])

        Logger.info(
          "Indx.IndexerWorker: rebuilt scope=#{scope} dataset=#{result.new_dataset} " <>
            "count=#{result.count} (dropped #{inspect(old)})"
        )

        :ok

      {:error, %NetworkError{} = err} ->
        Logger.warning(
          "Indx.IndexerWorker: Indx unreachable for scope=#{scope}, snoozing: #{inspect(err)}"
        )

        {:snooze, @snooze_seconds}

      {:error, err} ->
        Logger.error("Indx.IndexerWorker: rebuild failed for scope=#{scope}: #{inspect(err)}")
        {:error, err}
    end
  end

  # The indexer module is `Indexer` in production. Tests pass an
  # `"indexer"` arg naming a fake module so the worker's op branching +
  # reindex fallback can be exercised without a live Indx engine. The arg
  # is never set by the lifecycle enqueue paths, so prod always uses the
  # real Indexer.
  defp indexer_mod(args) do
    case Map.get(args, "indexer") do
      mod when is_binary(mod) -> String.to_existing_atom("Elixir." <> mod)
      mod when is_atom(mod) and not is_nil(mod) -> mod
      _ -> Indexer
    end
  end

  defp perspective_atom("drafts"), do: :drafts
  defp perspective_atom("raw"), do: :raw
  defp perspective_atom("published"), do: :published
  defp perspective_atom(other) when is_atom(other), do: other
  defp perspective_atom(_), do: :published

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp drop_nil(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
