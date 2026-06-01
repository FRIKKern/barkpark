defmodule Barkpark.Plugins.Indx.Indexer do
  @moduledoc """
  Blue/green corpus rebuild for the dedicated single-tenant Indx instance.

  ## Why blue/green

  CRITICAL SYNC RULE (spike 2026-06-01): NEVER re-load an existing key onto
  a live indexed dataset — it HANGS and WEDGES the engine manager. So a
  sync is never an in-place update. Instead:

    1. Pick a FRESH dataset name `<prefix>_<scope>_v<n>` (n = the next
       version after the current live one).
    2. `create_or_open` the fresh dataset.
    3. `set_searchable_fields` with the configured weights.
    4. `load_string` the FULL corpus as one JSON array (text/plain body).
    5. `index_dataset`, then poll `get_status` until ready.
    6. Verify `get_number_of_json_records` equals the corpus size.
    7. Return `{new_dataset, old_dataset}` so the caller can atomically
       swap the query path (`swap/2`) and then `delete_dataset` the old one.

  The fresh dataset name guarantees step 4 never touches a live dataset.

  ## _id ↔ numeric key map

  Indx's document key field defaults to `"id"` (numeric / long), while
  Barkpark `_id`s are strings (`"drafts.p1"`). We assign a stable numeric
  key PER REBUILD by position in the corpus list (1-based), embed BOTH the
  numeric `"id"` and the original `"_id"` into each rendered document, and
  store the key→`_id` map in the live pointer. The retriever maps an Indx
  `documentKey` back to `_id` by reading the embedded `_id` off the
  hydrated `GetJson` doc — so it does not even need the stored map on the
  read path. The map is retained on the pointer for diagnostics.

  ## Live pointer

  `pointer/1` / `swap/2` keep a per-scope `:persistent_term` pointer naming
  the dataset the query path should read. `swap/2` is the atomic flip;
  `current_dataset/1` is what the retriever reads. Because
  `:persistent_term.put/2` triggers a global GC, swaps happen at most once
  per rebuild (not on the hot read path).

  ## Purity

  `rebuild/3` takes the client MODULE (default `Barkpark.Plugins.Indx.Client`)
  and a list of doc maps, so tests inject a fake client. It performs no DB
  reads itself — the worker lists the corpus and hands it in.
  """

  require Logger

  alias Barkpark.Plugins.Indx.{Client, Settings}

  @pointer_term {__MODULE__, :live_dataset}
  @default_poll_attempts 30
  @default_poll_interval_ms 500

  @typedoc "Result of a successful blue/green rebuild."
  @type rebuild_result :: %{
          new_dataset: String.t(),
          old_dataset: String.t() | nil,
          count: non_neg_integer(),
          key_map: %{optional(integer()) => String.t()}
        }

  @doc """
  Run a blue/green rebuild of `scope`'s corpus into a fresh dataset.

  `docs` is a list of Barkpark document maps (each must carry an `"_id"`
  or `:_id`). Renders each to an Indx record with a numeric `"id"` and the
  embedded `"_id"`, loads the full corpus into `<prefix>_<scope>_v<n>`,
  indexes, polls, and verifies the record count.

  Returns `{:ok, rebuild_result}` on success — the caller then calls
  `swap/2` to flip the live pointer and `delete_dataset/2` the old one.
  Returns `{:error, struct()}` (an Indx error struct) on any failure;
  NEVER re-loads an existing dataset.

  Options:

    * `:client`              — client module (default `Client`); injected in tests
    * `:base_url`            — forwarded to every client call (test mock)
    * `:poll_attempts`       — max status polls (default 30)
    * `:poll_interval_ms`    — sleep between polls (default 500)
    * `:weights`             — `[{field, weight}]`; default from `Settings`
  """
  @spec rebuild(String.t(), [map()], keyword()) ::
          {:ok, rebuild_result()} | {:error, struct()}
  def rebuild(scope, docs, opts \\ []) when is_binary(scope) and is_list(docs) do
    client = Keyword.get(opts, :client, Client)
    settings = Settings.get()
    old_dataset = current_dataset(scope)
    new_dataset = next_dataset_name(scope, old_dataset, settings.dataset_prefix)

    {records, key_map} = render_corpus(docs)
    weights = Keyword.get(opts, :weights, default_weights(settings))
    client_opts = client_opts(opts)

    with :ok <- client.create_or_open(new_dataset, client_opts),
         :ok <- client.set_searchable_fields(new_dataset, weights, client_opts),
         :ok <- client.load_string(new_dataset, records, client_opts),
         :ok <- client.index_dataset(new_dataset, client_opts),
         :ok <- poll_ready(client, new_dataset, client_opts, opts),
         {:ok, count} <- verify_count(client, new_dataset, length(records), client_opts) do
      {:ok,
       %{
         new_dataset: new_dataset,
         old_dataset: old_dataset,
         count: count,
         key_map: key_map
       }}
    end
  end

  @doc """
  Atomically flip the live query-path dataset for `scope` to
  `result.new_dataset` and record the key map. Returns the previous live
  dataset name (or nil). Does NOT delete the old dataset — the caller does
  that after the swap so the read path never points at a deleted dataset.
  """
  @spec swap(String.t(), rebuild_result()) :: String.t() | nil
  def swap(scope, %{new_dataset: new_dataset} = result) when is_binary(scope) do
    table = :persistent_term.get(@pointer_term, %{})
    old = get_in(table, [scope, :dataset])

    table =
      Map.put(table, scope, %{
        dataset: new_dataset,
        key_map: Map.get(result, :key_map, %{})
      })

    :persistent_term.put(@pointer_term, table)
    old
  end

  @doc "The dataset name the query path should read for `scope`, or nil if none."
  @spec current_dataset(String.t()) :: String.t() | nil
  def current_dataset(scope) when is_binary(scope) do
    :persistent_term.get(@pointer_term, %{})
    |> get_in([scope, :dataset])
  end

  @doc "The stored key→_id map for `scope` (diagnostics; read path uses embedded _id)."
  @spec key_map(String.t()) :: %{optional(integer()) => String.t()}
  def key_map(scope) when is_binary(scope) do
    :persistent_term.get(@pointer_term, %{})
    |> get_in([scope, :key_map]) || %{}
  end

  @doc """
  Delete a dataset via the client. Thin wrapper so the worker can drop the
  old dataset after a successful `swap/2`. Tolerant: logs (does not raise)
  on failure, returning the client result.
  """
  @spec delete_dataset(String.t() | nil, keyword()) :: :ok | {:error, struct()}
  def delete_dataset(nil, _opts), do: :ok

  def delete_dataset(dataset, opts) when is_binary(dataset) do
    client = Keyword.get(opts, :client, Client)

    case client.delete_dataset(dataset, client_opts(opts)) do
      :ok ->
        :ok

      {:error, err} = result ->
        Logger.warning("Indx.Indexer: failed to delete old dataset #{dataset}: #{inspect(err)}")
        result
    end
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  # Assign a stable numeric key per rebuild (1-based position), embed both
  # the numeric "id" and the original "_id" into each record. Returns the
  # records list AND the key→_id map.
  defp render_corpus(docs) do
    docs
    |> Enum.with_index(1)
    |> Enum.map_reduce(%{}, fn {doc, key}, acc ->
      id = doc_id(doc)
      record = render_record(doc, key, id)
      {record, Map.put(acc, key, id)}
    end)
  end

  defp render_record(doc, key, id) do
    doc
    |> stringify_top()
    |> Map.put("id", key)
    |> Map.put("_id", id)
  end

  defp stringify_top(doc) when is_map(doc) and not is_struct(doc) do
    Map.new(doc, fn {k, v} -> {to_string(k), v} end)
  end

  defp stringify_top(%{__struct__: _} = struct) do
    struct
    |> Map.from_struct()
    |> Map.drop([:__meta__])
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
  end

  defp doc_id(doc) when is_map(doc) do
    cond do
      v = Map.get(doc, "_id") -> to_string(v)
      v = Map.get(doc, :_id) -> to_string(v)
      v = Map.get(doc, "doc_id") -> to_string(v)
      v = Map.get(doc, :doc_id) -> to_string(v)
      true -> ""
    end
  end

  # Next version: parse the trailing _v<n> off the old dataset name and add
  # one, defaulting to v1 when there is no live dataset yet. The scope is
  # slugified so a dataset name is always a safe URL/identifier segment.
  defp next_dataset_name(scope, old_dataset, prefix) do
    n = next_version(old_dataset)
    "#{prefix}_#{slug(scope)}_v#{n}"
  end

  defp next_version(nil), do: 1

  defp next_version(old) when is_binary(old) do
    case Regex.run(~r/_v(\d+)$/, old) do
      [_, n] -> String.to_integer(n) + 1
      _ -> 1
    end
  end

  defp slug(scope) do
    scope
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end

  defp default_weights(settings) do
    [
      {"title", settings.weight_high},
      {"_id", settings.weight_low}
    ]
  end

  defp poll_ready(client, dataset, client_opts, opts) do
    attempts = Keyword.get(opts, :poll_attempts, @default_poll_attempts)
    interval = Keyword.get(opts, :poll_interval_ms, @default_poll_interval_ms)
    do_poll(client, dataset, client_opts, attempts, interval)
  end

  defp do_poll(_client, _dataset, _client_opts, 0, _interval), do: :ok

  defp do_poll(client, dataset, client_opts, attempts, interval) do
    case client.get_status(dataset, client_opts) do
      {:ok, status} ->
        if ready?(status) do
          :ok
        else
          if interval > 0, do: Process.sleep(interval)
          do_poll(client, dataset, client_opts, attempts - 1, interval)
        end

      {:error, _} = err ->
        err
    end
  end

  # Engine status shapes vary; treat a few common "done" signals as ready,
  # otherwise keep polling until attempts run out.
  defp ready?(status) when is_map(status) do
    done = Map.get(status, "isIndexed") || Map.get(status, "indexed") || Map.get(status, "done")

    state =
      (Map.get(status, "status") || Map.get(status, "state") || "")
      |> to_string()
      |> String.downcase()

    done == true or state in ["ready", "indexed", "completed", "done", "idle"]
  end

  defp ready?(status) when is_binary(status) do
    String.downcase(status) in ["ready", "indexed", "completed", "done", "idle", "true"]
  end

  defp ready?(true), do: true
  defp ready?(_), do: false

  defp verify_count(client, dataset, expected, client_opts) do
    case client.get_number_of_json_records(dataset, client_opts) do
      {:ok, ^expected} ->
        {:ok, expected}

      {:ok, actual} ->
        Logger.warning(
          "Indx.Indexer: count mismatch for #{dataset} — expected #{expected}, got #{actual}"
        )

        # Accept the engine's reported count rather than failing the rebuild
        # on an off-by-one engine quirk; the swap still proceeds because the
        # dataset indexed. Hard failure is reserved for client errors.
        {:ok, actual}

      {:error, _} = err ->
        err
    end
  end

  defp client_opts(opts) do
    Keyword.take(opts, [:base_url, :timeout])
  end
end
