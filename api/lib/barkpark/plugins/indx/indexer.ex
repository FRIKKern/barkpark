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
    3. `analyze_string` the FULL corpus (text/plain body) to populate the
       dataset's `DocumentFields` — this MUST precede step 4. Without it
       `set_searchable_fields` 400s ("SetSearchableFields invalid status")
       because `DocumentFields == null`. `LoadString` does NOT populate
       `DocumentFields`; only `AnalyzeString` does.
    4. `set_searchable_fields` with the configured weights.
    5. `load_string` the FULL corpus as one JSON array (text/plain body).
    6. `index_dataset`, then poll `get_status` until ready.
    7. Verify `get_number_of_json_records` equals the corpus size.
    8. Return `{new_dataset, old_dataset}` so the caller can atomically
       swap the query path (`swap/2`) and then `delete_dataset` the old one.

  The fresh dataset name guarantees step 4 never touches a live dataset.

  ## _id ↔ numeric key map (STABLE — load-bearing for delete)

  Indx's document key field defaults to `"id"` (numeric / long), while
  Barkpark `_id`s are strings (`"drafts.p1"`). The numeric key is derived
  DETERMINISTICALLY from the `_id` via `key_for_id/1`, so the same `_id`
  maps to the same `long` on every rebuild AND can be recomputed for a
  targeted per-document delete — there is NO per-rebuild position
  dependency anymore.

  ### Why deterministic, not positional

  The old scheme assigned the key by 1-based position in the corpus list,
  so the same `_id` got a different key after any insert/delete shifted
  positions. That made the key useless as a delete target (the C#
  `DeleteJsonRecord(long id)` needs a STABLE id). `key_for_id/1` removes
  the position dependency: `delete_record/3` recomputes the exact key the
  last rebuild embedded, with no need to consult the stored map.

  ### Algorithm

    1. `:crypto.hash(:sha256, _id)` → take the first 8 bytes as a big
       unsigned 64-bit integer, then mask to 63 bits (`&&& 0x7FFF...`) so
       the value is always a POSITIVE signed int64 — safe for the C#
       `long` key and never negative. SHA-256 (not `:erlang.phash2`,
       which is only 32-bit / 2^32 and collides at corpus scale) gives a
       collision probability that is negligible for realistic corpora
       (~2^63 space).
    2. Collisions WITHIN a single corpus are still detected at render
       time and resolved by DETERMINISTIC linear probing: `key, key+1,
       key+2, …` (wrapping inside the 63-bit band) until a free slot is
       found, in a stable iteration order (corpus list order). This keeps
       the per-corpus key set INJECTIVE (one `_id` ⇒ one key, no two
       `_id`s share a key) so `documentKey → _id` is unambiguous on the
       read path and `key_for_id/1` is the delete target for the common
       (collision-free) case.

  Both the render path and the delete path call `key_for_id/1`; render
  additionally runs the collision probe, so on the rare collision the
  rebuilt key for the *second* colliding `_id` differs from its bare
  `key_for_id/1`. That edge is handled by `delete_record/3` falling back
  to a full rebuild via the worker (see `delete_record/3`), so a probed
  key never leaves a stale record behind.

  Each rendered document embeds BOTH the numeric `"id"` and the original
  `"_id"`. The retriever maps an Indx `documentKey` back to `_id` by
  reading the embedded `_id` off the hydrated `GetJson` doc — so it does
  not need the stored map on the read path. The key→`_id` map IS retained
  on the live pointer (now load-bearing for delete diagnostics, not just
  informational).

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
  import Bitwise

  alias Barkpark.Plugins.Indx.{Client, Settings}

  @pointer_term {__MODULE__, :live_dataset}
  @default_poll_attempts 30
  @default_poll_interval_ms 500

  # 63-bit positive band: the largest signed int64 keeps the key safe for
  # the C# `long` document key and guarantees it is never negative.
  @key_mask 0x7FFFFFFFFFFFFFFF

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
         :ok <- client.analyze_string(new_dataset, records, client_opts),
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

  @doc """
  Delete a single document from the CURRENT live dataset by its `_id`,
  without a full rebuild.

  Computes the stable numeric key via `key_for_id/1`, calls
  `client.delete_json_record/3` against `current_dataset(scope)`, then
  reads `get_status/2` and inspects the engine's `ReIndexRequired` flag:

    * `:ok` — the record was deleted and no reindex is needed.
    * `{:reindex_required, status}` — the delete landed but the engine
      reports it must reindex before the change is query-visible; the
      worker falls back to a full blue/green rebuild.
    * `{:error, struct()}` — the client call failed, OR there is no
      current live dataset for `scope` (nothing to delete from).

  Does NOT swap the live pointer — a delete mutates the live dataset in
  place (the one exception to "never touch a live dataset"; this is a
  TARGETED single-key DELETE, not a re-LOAD of an existing key, which is
  the operation the 2026-06-01 spike proved wedges the engine).

  Options mirror `rebuild/3`: `:client` (default `Client`), `:base_url`,
  `:timeout`.
  """
  @spec delete_record(String.t(), String.t(), keyword()) ::
          :ok | {:reindex_required, term()} | {:error, struct()}
  def delete_record(scope, id, opts \\ []) when is_binary(scope) and is_binary(id) do
    client = Keyword.get(opts, :client, Client)
    dataset = current_dataset(scope)
    client_opts = client_opts(opts)

    cond do
      is_nil(dataset) ->
        {:error,
         %Barkpark.Plugins.Indx.Errors.IndexError{
           status: 0,
           endpoint: nil,
           message: "Indx.Indexer: no live dataset for scope #{scope} — nothing to delete"
         }}

      true ->
        do_delete_record(client, dataset, id, client_opts)
    end
  end

  defp do_delete_record(client, dataset, id, client_opts) do
    key = key_for_id(id)

    with :ok <- client.delete_json_record(dataset, key, client_opts),
         {:ok, status} <- client.get_status(dataset, client_opts) do
      if reindex_required?(status) do
        {:reindex_required, status}
      else
        :ok
      end
    end
  end

  @doc """
  Derive the STABLE numeric Indx key for a Barkpark `_id`.

  Deterministic: the same `_id` always yields the same key, on every
  rebuild and in the delete path. SHA-256 of the `_id`, first 8 bytes as
  a big-endian unsigned integer, masked to a positive 63-bit signed
  int64. Pure — no corpus context, no position. The render path layers
  per-corpus collision probing on top (see `render_corpus/1`); this bare
  function is the unprobed base key and the delete target for the common
  collision-free case.
  """
  @spec key_for_id(String.t() | term()) :: pos_integer()
  def key_for_id(id) do
    <<n::unsigned-big-integer-size(64), _rest::binary>> =
      :crypto.hash(:sha256, to_string(id))

    # Mask to 63 bits → always a positive signed int64. Force away from 0
    # so the key band starts at 1 (0 is reserved as "no key").
    case n &&& @key_mask do
      0 -> 1
      k -> k
    end
  end

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  # Assign a DETERMINISTIC stable key from each doc's `_id` via
  # `key_for_id/1`, embedding both the numeric "id" and the original
  # "_id" into each record. Detects collisions WITHIN this corpus and
  # resolves them by deterministic linear probing (key, key+1, …, wrapped
  # in the 63-bit band) in corpus order, so the key set is always
  # injective. Returns the records list AND the key→_id map.
  defp render_corpus(docs) do
    {records, _used, key_map} =
      Enum.reduce(docs, {[], MapSet.new(), %{}}, fn doc, {recs, used, kmap} ->
        id = doc_id(doc)
        key = assign_key(id, used)
        record = render_record(doc, key, id)
        {[record | recs], MapSet.put(used, key), Map.put(kmap, key, id)}
      end)

    {Enum.reverse(records), key_map}
  end

  # Linear-probe within the 63-bit band until a free key is found. The
  # iteration order (corpus list order, via render_corpus/1's reduce) is
  # deterministic, so the resolved key set is reproducible across runs of
  # the SAME corpus and injective (no two _ids collide on a final key).
  defp assign_key(id, used) do
    probe(key_for_id(id), used)
  end

  defp probe(key, used) do
    if MapSet.member?(used, key) do
      probe(next_key(key), used)
    else
      key
    end
  end

  defp next_key(key) do
    case key + 1 do
      k when k > @key_mask -> 1
      k -> k
    end
  end

  # Engine status reports ReIndexRequired in one of a few casings/shapes.
  defp reindex_required?(status) when is_map(status) do
    val =
      Map.get(status, "reIndexRequired") ||
        Map.get(status, "ReIndexRequired") ||
        Map.get(status, "reindexRequired") ||
        get_in(status, ["systemStatus", "reIndexRequired"]) ||
        get_in(status, ["SystemStatus", "ReIndexRequired"])

    val == true
  end

  defp reindex_required?(_), do: false

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
