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

  ## perform/1

    1. List the scope's corpus via `Barkpark.Content.list_documents/3`
       for each declared `type` at the requested `perspective`.
    2. Hand the corpus to `Indexer.rebuild/3` (blue/green: loads into a
       fresh `<prefix>_<scope>_v<n>`, NEVER re-loads a live dataset).
    3. On success, `Indexer.swap/2` flips the live pointer, then
       `Indexer.delete_dataset/2` drops the old dataset.

  ## Job args (string-keyed, Oban-serialised)

      %{
        "scope"       => "production",          # dataset string (required)
        "types"       => ["post", "page"],      # doc types to index (required)
        "perspective" => "published",           # default "published"
        "workspace_id"=> "...",                 # optional tenancy scope
        "project_id"  => "..."                   # optional tenancy scope
      }

  ## Indx-down tolerance

  A `NetworkError` from the client (Indx unreachable) → `{:snooze, N}` so
  the rebuild retries later without burning an Oban attempt. Other Indx
  errors (`IndexError` / `SearchError` / `AuthError`) → `{:error, reason}`
  so Oban applies its normal backoff. A missing/empty `types` list →
  `{:cancel, reason}` (nothing to index, not a transient failure).
  """

  use Oban.Worker,
    queue: :indx,
    max_attempts: 5,
    unique: [
      keys: [:scope],
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
  Build a debounced `:indx` job for `scope`. The lifecycle hooks call this
  with a fast (<100ms) hand-off — it only constructs and inserts the job.

  Schedules the job `@debounce_seconds` in the future so a burst of saves
  to the same scope collapses (combined with the `unique` clause keyed on
  `scope`). `opts` may carry `:types`, `:perspective`, `:workspace_id`,
  `:project_id`.
  """
  @spec enqueue(String.t(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(scope, opts \\ []) when is_binary(scope) do
    %{
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

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    scope = Map.get(args, "scope")
    types = Map.get(args, "types", [])
    perspective = perspective_atom(Map.get(args, "perspective", "published"))

    cond do
      not is_binary(scope) or scope == "" ->
        {:cancel, :missing_scope}

      not is_list(types) or types == [] ->
        {:cancel, :no_types}

      true ->
        run_rebuild(scope, types, perspective, args)
    end
  end

  defp run_rebuild(scope, types, perspective, args) do
    list_opts =
      [perspective: perspective, limit: 1000]
      |> maybe_put(:workspace_id, Map.get(args, "workspace_id"))
      |> maybe_put(:project_id, Map.get(args, "project_id"))

    docs =
      Enum.flat_map(types, fn type ->
        Content.list_documents(type, scope, list_opts)
      end)

    case Indexer.rebuild(scope, docs) do
      {:ok, result} ->
        old = Indexer.swap(scope, result)
        Indexer.delete_dataset(old, [])

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
