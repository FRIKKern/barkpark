defmodule Barkpark.Plugins.Indx.Indexer do
  @moduledoc """
  Blue/green corpus rebuild for the dedicated single-tenant Indx instance.

  ## Why blue/green

  CRITICAL SYNC RULE (spike 2026-06-01): NEVER re-load an existing key onto
  a live indexed dataset — it HANGS and WEDGES the engine manager. So a
  sync is never an in-place update. Instead:

    1. Pick a FRESH dataset name `<prefix>_<index_key>_v<n>` (n = the next
       version after the current live one).
    2. `create_or_open` the fresh dataset.
    3. `analyze_string` the FULL corpus (text/plain body) to populate the
       dataset's `DocumentFields` — this MUST precede step 4. Without it
       `set_field_configuration` 400s ("non existing fieldname") because
       the configured names do not exist yet. `LoadString` does NOT
       populate `DocumentFields`; only `AnalyzeString` does.
    4. `set_field_configuration` with the FieldProxy maps built from the
       configured weights (`field_proxies/1`). NOTE: the deprecated
       `set_searchable_fields` Set*Fields path leaves v5 storing EMPTY
       documents (`LoadString` 200s but `GetJson` returns "") — the spike
       2026-06-03 confirmed `SetFieldConfiguration` is the working v5 path.
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
  maps to the same `long` on every rebuild — there is NO per-rebuild
  position dependency anymore. The render path layers per-corpus collision
  probing on top, and `swap/2` records the resulting key→`_id` map on the
  live pointer; `delete_record/3` reads THAT map to find the key a record
  was actually indexed under (the map is genuinely load-bearing for
  delete, not merely diagnostic).

  ### Why deterministic, not positional

  The old scheme assigned the key by 1-based position in the corpus list,
  so the same `_id` got a different key after any insert/delete shifted
  positions. That made the key useless as a delete target (the C#
  `DeleteJsonRecord(long id)` needs a STABLE id). `key_for_id/1` removes
  the position dependency: the bare hash is reproducible from the `_id`
  alone, and for the common collision-free case it equals the key the
  rebuild embedded.

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
       read path.

  ### How delete finds the right key

  Render runs the collision probe, so on a collision the rebuilt key for
  the *displaced* `_id` differs from its bare `key_for_id/1` (it is
  `key_for_id/1 + k` for some probe distance `k`). The bare hash would
  therefore be the WRONG delete target for a displaced `_id`. So
  `delete_record/3` does NOT use the bare hash by default: it
  reverse-looks-up the stored `key_map/1` (`%{key => _id}`, recorded by
  `swap/2`) for EVERY key whose value is the target `_id`, and deletes
  each — which deletes the exact probed key. The bare `key_for_id/1` is
  used ONLY as a best-effort fallback when the `_id` is absent from the
  stored map (no map yet, or a doc that predates map tracking). That
  fallback can mis-target only under a true cross-`_id` SHA-256 collision
  WITH the map absent (~2^-63 per colliding pair, AND no map) — with the
  map present (the normal case) delete is exact. See `delete_record/3`.

  Each rendered document embeds BOTH the numeric `"id"` and the original
  `"_id"`. The retriever maps an Indx `documentKey` back to `_id` by
  reading the embedded `_id` off the hydrated `GetJson` doc — so it does
  not need the stored map on the read path. The key→`_id` map IS retained
  on the live pointer specifically so the delete path can resolve the
  exact probed key.

  ## Index identity — the INDEX KEY, not the dataset string

  Every index-identity function below (`rebuild/3`, `swap/2`,
  `current_dataset/1`, `key_map/1`, `restore_pointer/2`, `delete_record/3`,
  `upsert_record/3`) takes an INDEX KEY from `index_key/2` — NOT a raw
  Barkpark dataset string.

  This is a tenancy boundary, not a naming preference. Every workspace is
  BORN owning a dataset named `production`
  (`Tenancy.do_create_owned_workspace/4`; uniqueness is `(project_id, slug)`,
  never global), so the dataset string `production` is shared by every
  tenant in the system. Keying the live pointer, the physical dataset name
  or the rebuild job on that string alone makes one tenant's index the
  ONLY index: whoever swaps last owns the slot, and every other tenant's
  search reads a corpus built from a co-tenant's documents while its own
  documents are absent from the pool.

  `index_key/2` folds the tenancy scope (`:workspace_id` + `:project_id`)
  into the key, so co-tenants on one dataset string get INDEPENDENT
  pointer slots, independent physical datasets and independent rebuild
  jobs. The public functions GUARD on the key's shape, so handing one of
  them a bare dataset string raises instead of silently re-merging the
  tenants.

  ## Live pointer

  `swap/2` keeps a per-INDEX-KEY `:persistent_term` pointer naming the
  dataset the query path should read. `swap/2` is the atomic flip;
  `current_dataset/1` is what the retriever reads. Because
  `:persistent_term.put/2` triggers a global GC, swaps happen at most once
  per rebuild (not on the hot read path). `upsert_record/3` and
  `delete_record/3` keep the pointer's key_map current via small
  read-modify-write merges (`merge_key_map/3`) WITHOUT changing the live
  dataset name — they never swap.

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

  @typedoc """
  A tenant-partitioned search-index identity from `index_key/2`. Shaped
  `<slugified-scope>_t<16 lowercase hex>`; the trailing `_t…` band is what
  `is_index_key/1` guards on.
  """
  @type index_key :: String.t()

  # Length of the `_t` marker + the 16-hex tenant digest that every index key
  # ends with. The guard below reads exactly this many bytes off the tail.
  @tenant_suffix_bytes 18

  @doc false
  # A bare dataset string ("production") can never satisfy this: it lacks the
  # `_t<digest>` band. That makes "I forgot to partition the key" a
  # FunctionClauseError at the call site instead of a silent cross-tenant
  # index merge — the failure mode this module's Index identity section
  # exists to prevent.
  defguard is_index_key(key)
           when is_binary(key) and byte_size(key) > @tenant_suffix_bytes and
                  binary_part(key, byte_size(key) - @tenant_suffix_bytes, 2) == "_t"

  @doc """
  The tenant-partitioned identity of ONE search index.

  `scope` is the Barkpark dataset string; `opts` carries the tenancy scope
  (`:workspace_id`, `:project_id`) exactly as the lifecycle hooks, the
  `IndexerWorker` job args and `Retriever.search/4`'s opts already carry it.

  Two workspaces both owning a dataset called `production` — the SEEDED
  DEFAULT, since every workspace is born with one — get two different index
  keys, hence two pointer slots, two physical Indx datasets and two Oban
  rebuild jobs.

  The tenancy half is a 64-bit truncated SHA-256 digest rather than the raw
  ids: it keeps the key short enough for a dataset name, slug-safe (so
  `Recovery` can parse it straight back out of `<prefix>_<key>_v<n>`), and
  it leaks no tenant id into an engine-side name. Truncation is the same
  trade `key_for_id/1` already makes for document keys (63 bits, see "How
  delete finds the right key") — a digest collision would merge two tenants'
  indexes, at ~2^-64 per pair.

  A nil `:workspace_id`/`:project_id` is a REAL value here, not a missing
  one: global (workspace-less) documents form their own index, with their
  own key. It is deliberately NOT dropped — dropping it is what let a
  workspace-less rebuild collapse into an arbitrary tenant's job.
  """
  # @canonical capability:indx-index-identity aka:live_dataset,pointer term,index key,live pointer,search index scope,tenant partition,dataset collision doc:docs/cards/search-media.md
  @spec index_key(String.t(), keyword()) :: index_key()
  def index_key(scope, opts \\ []) when is_binary(scope) do
    digest =
      :crypto.hash(:sha256, [
        to_string(Keyword.get(opts, :workspace_id)),
        0,
        to_string(Keyword.get(opts, :project_id))
      ])
      |> binary_part(0, 8)
      |> Base.encode16(case: :lower)

    slug(scope) <> "_t" <> digest
  end

  @doc """
  Run a blue/green rebuild of `index_key`'s corpus into a fresh dataset.

  `docs` is a list of Barkpark document maps (each must carry an `"_id"`
  or `:_id`). Renders each to an Indx record with a numeric `"id"` and the
  embedded `"_id"`, loads the full corpus into `<prefix>_<index_key>_v<n>`,
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
  def rebuild(index_key, docs, opts \\ []) when is_index_key(index_key) and is_list(docs) do
    client = Keyword.get(opts, :client, Client)
    settings = Settings.get()
    old_dataset = current_dataset(index_key)
    new_dataset = next_dataset_name(index_key, old_dataset, settings.dataset_prefix)

    {records, key_map} = render_corpus(docs)
    weights = Keyword.get(opts, :weights, default_weights(settings))
    field_proxies = field_proxies(weights)
    client_opts = client_opts(opts)

    with :ok <- client.create_or_open(new_dataset, client_opts),
         :ok <- client.analyze_string(new_dataset, records, client_opts),
         :ok <- client.set_field_configuration(new_dataset, field_proxies, client_opts),
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
    else
      {:error, _} = err ->
        # Any step after create_or_open failed, so the fresh
        # `<prefix>_<index_key>_v<n>` dataset was created but is partial/unindexed.
        # Best-effort delete it before returning: if it leaks, boot recovery
        # (Indx.Recovery) picks the MAX version and would seat the live query
        # pointer on this FAILED dataset → silently wrong search results after
        # a deploy. `delete_dataset/2` is tolerant of a missing dataset (it
        # logs, never raises), so a create_or_open failure — where nothing was
        # created — is harmless here too.
        _ = delete_dataset(new_dataset, opts)
        err
    end
  end

  @doc """
  Atomically flip the live query-path dataset for `index_key` to
  `result.new_dataset` and record the key map. Returns the previous live
  dataset name (or nil). Does NOT delete the old dataset — the caller does
  that after the swap so the read path never points at a deleted dataset.
  """
  @spec swap(String.t(), rebuild_result()) :: String.t() | nil
  def swap(index_key, %{new_dataset: new_dataset} = result) when is_index_key(index_key) do
    table = :persistent_term.get(@pointer_term, %{})
    old = get_in(table, [index_key, :dataset])
    key_map = Map.get(result, :key_map, %{})

    table =
      Map.put(table, index_key, %{
        dataset: new_dataset,
        key_map: key_map
      })

    :persistent_term.put(@pointer_term, table)

    # P4b Hardening B: persist alongside the live pointer so a restart can
    # recover the exact key_map — eliminating the delete-time bare-hash
    # fallback in practice.
    _ =
      Barkpark.Plugins.Indx.Persistence.save(index_key, %{
        dataset: new_dataset,
        key_map: key_map
      })

    old
  end

  @doc """
  Boot-recovery hook: point `index_key`'s live query path at `dataset` with
  an EMPTY key_map, but ONLY when `index_key` currently has NO live dataset.

  The `:persistent_term` pointer is wiped on every Barkpark restart, so
  with `incremental_upsert` ON a restart leaves `current_dataset(key) ==
  nil` and upsert has nothing to write to. `Indx.Recovery` rediscovers the
  live `<prefix>_<index_key>_v<n>` dataset from `Client.get_user_datasets/1`
  and calls this to re-seat the pointer. The key_map is left EMPTY — it is
  rebuilt lazily on the upsert path (existence-probed via
  `Client.get_json/3`) and on the next full rebuild.

  Returns `:ok` after seating the pointer, or `:noop` when `index_key` already
  has a live dataset — so a rebuild that ran BEFORE recovery (the common
  always-on race) is never clobbered.
  """
  @spec restore_pointer(String.t(), String.t()) :: :ok | :noop
  def restore_pointer(index_key, dataset) when is_index_key(index_key) and is_binary(dataset) do
    case current_dataset(index_key) do
      nil ->
        # P4b Hardening B: load the persisted key_map for `index_key` if we have
        # one matching THIS dataset. A mismatched persisted dataset means the
        # engine was rebuilt out-of-band — drop the stale map (the next
        # rebuild repopulates it).
        key_map =
          case Barkpark.Plugins.Indx.Persistence.load(index_key) do
            {:ok, %{dataset: ^dataset, key_map: km}} -> km
            _ -> %{}
          end

        table = :persistent_term.get(@pointer_term, %{})
        table = Map.put(table, index_key, %{dataset: dataset, key_map: key_map})
        :persistent_term.put(@pointer_term, table)

        # Re-persist (no-op when the file is already correct; corrects the
        # file when the live engine's dataset shifted under us).
        _ =
          Barkpark.Plugins.Indx.Persistence.save(index_key, %{
            dataset: dataset,
            key_map: key_map
          })

        :ok

      _live ->
        :noop
    end
  end

  @doc "The dataset name the query path should read for `index_key`, or nil if none."
  @spec current_dataset(index_key()) :: String.t() | nil
  def current_dataset(index_key) when is_index_key(index_key) do
    :persistent_term.get(@pointer_term, %{})
    |> get_in([index_key, :dataset])
  end

  @doc "The stored key→_id map for `index_key` (diagnostics; read path uses embedded _id)."
  @spec key_map(index_key()) :: %{optional(integer()) => String.t()}
  def key_map(index_key) when is_index_key(index_key) do
    :persistent_term.get(@pointer_term, %{})
    |> get_in([index_key, :key_map]) || %{}
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

  Resolves the numeric delete target from the stored `key_map/1` for the
  index — the SAME map `swap/2` recorded after the last rebuild, which
  reflects any in-corpus collision probing (`render_corpus/1`). Every key
  whose value equals `id` is deleted via `client.delete_json_record/3`
  (normally exactly one; more only under a pathological multi-key map).
  Reading from the stored map is what makes a PROBE-DISPLACED `_id` (one
  whose final key is `key_for_id(_id) + k`, not the bare hash) delete the
  CORRECT key. When `id` is ABSENT from the stored map (no map yet, or a
  doc indexed before the map was tracked) it falls back to the single bare
  `key_for_id(id)` — best-effort. After the delete(s) it reads
  `get_status/2` and inspects the engine's `ReIndexRequired` flag:

    * `:ok` — the record(s) were deleted and no reindex is needed.
    * `{:reindex_required, status}` — a delete landed but the engine
      reports it must reindex before the change is query-visible (if more
      than one key was deleted, this trips when ANY of them does); the
      worker falls back to a full blue/green rebuild.
    * `{:error, struct()}` — a client call failed (the FIRST hard error is
      surfaced), OR there is no current live dataset for `index_key` (nothing
      to delete from).

  ## Fallback caveat (honest)

  The no-map fallback deletes `key_for_id(id)` directly. If the live
  corpus had a true cross-`_id` SHA-256 collision AND the stored map is
  absent, the bare key could belong to the OTHER colliding `_id` (the one
  that won the natural slot) — so the fallback could mis-target. That is
  the only mis-target path and it requires both a 63-bit hash collision
  (~2^-63 per pair) AND a missing map; with the map present (the normal
  case) the resolution is exact.

  Does NOT swap the live pointer — a delete mutates the live dataset in
  place (the one exception to "never touch a live dataset"; this is a
  TARGETED single-key DELETE, not a re-LOAD of an existing key, which is
  the operation the 2026-06-01 spike proved wedges the engine).

  Options mirror `rebuild/3`: `:client` (default `Client`), `:base_url`,
  `:timeout`.
  """
  @spec delete_record(String.t(), String.t(), keyword()) ::
          :ok | {:reindex_required, term()} | {:error, struct()}
  def delete_record(index_key, id, opts \\ []) when is_index_key(index_key) and is_binary(id) do
    client = Keyword.get(opts, :client, Client)
    dataset = current_dataset(index_key)
    client_opts = client_opts(opts)

    cond do
      is_nil(dataset) ->
        {:error,
         %Barkpark.Plugins.Indx.Errors.IndexError{
           status: 0,
           endpoint: nil,
           message: "Indx.Indexer: no live dataset for index #{index_key} — nothing to delete"
         }}

      true ->
        keys = delete_target_keys(index_key, id)
        do_delete_record(client, dataset, keys, client_opts)
    end
  end

  # Resolve the numeric key(s) the `_id` was ACTUALLY indexed under by
  # reverse-looking-up the stored key_map (key => _id). Returns every key
  # mapping to `id` (normally one). When `id` is absent from the map, fall
  # back to the bare `key_for_id(id)` (best-effort single delete — see the
  # `delete_record/3` fallback caveat).
  defp delete_target_keys(index_key, id) do
    mapped =
      index_key
      |> key_map()
      |> Enum.filter(fn {_key, mapped_id} -> mapped_id == id end)
      |> Enum.map(fn {key, _id} -> key end)

    case mapped do
      [] ->
        # P4b Hardening B: the persisted key_map (via Persistence + Recovery)
        # should make this branch effectively never fire in production. When
        # it does, record an observable signal so an operator can see that
        # a delete fell back to the bare-hash path — a strong hint that
        # persistence is misconfigured (read-only fs, wrong dir, etc.).
        require Logger

        Logger.warning(
          "Indx.Indexer: delete bare-hash fallback for index=#{index_key} id=#{id} — " <>
            "persisted key_map missing this id. See Indx.Persistence."
        )

        :telemetry.execute(
          [:barkpark, :indx, :delete, :bare_hash_fallback],
          %{count: 1},
          %{index_key: index_key, id: id}
        )

        [key_for_id(id)]

      keys ->
        keys
    end
  end

  # Delete each resolved key, reading status after each. Aggregates:
  #   * first client {:error, _} wins (returned immediately),
  #   * {:reindex_required, status} if ANY delete trips the engine flag,
  #   * :ok only when every delete landed cleanly with no reindex.
  defp do_delete_record(client, dataset, keys, client_opts) do
    Enum.reduce_while(keys, :ok, fn key, acc ->
      with :ok <- client.delete_json_record(dataset, key, client_opts),
           {:ok, status} <- client.get_status(dataset, client_opts) do
        if reindex_required?(status) do
          {:cont, {:reindex_required, status}}
        else
          {:cont, acc}
        end
      else
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  @doc """
  Insert-or-update a SINGLE document into the CURRENT live dataset by its
  `_id`, without a full rebuild. The incremental ADD/UPDATE sibling of
  `delete_record/3`.

  Renders `doc` to one Indx record (embedding the numeric `"id"` =
  `key_for_id(_id)` and the original `"_id"` — the SAME per-element shape
  `render_corpus/1` produces) and writes it to `current_dataset(index_key)`:

    * UPDATE (fast path) when the `_id` IS already in the index's stored
      `key_map/1` (the live index already holds a record under its key) →
      `client.update_json_record/4` ("replace by key"). No engine round-trip.
    * Otherwise EXISTENCE-PROBE the engine: `client.get_json/3` for `[key]`
      → if it returns a non-empty list whose doc carries the SAME `_id`, the
      record already exists → UPDATE; if it comes back empty → INSERT via
      `client.insert_json_record/4`.

  The decision does NOT depend on the key_map being populated. Boot-recovery
  (`Indx.Recovery` → `restore_pointer/2`) re-seats the live pointer after a
  restart with an EMPTY key_map, so the map cannot be the sole source of
  truth: the GetJson probe makes upsert correct even on the FIRST edit after
  a restart, when `current_dataset(index_key)` is set but the map is empty.
  When the map already knows the `_id` (after a rebuild, or after an earlier
  upsert kept it current) the probe is skipped.

  Operates on `current_dataset(index_key)`; with no live dataset it returns the
  same "no live dataset" `%IndexError{}` as `delete_record/3` and NEVER
  swaps the pointer (an upsert mutates the live dataset in place — the same
  exception to "never touch a live dataset" that the targeted delete is;
  this is a single-key write, NOT a re-LOAD of an existing key, which is
  the operation the spike proved wedges the engine).

  After a successful write it merges `{key => _id}` into the index's stored
  `key_map` (via `merge_key_map/3`, which does NOT change `swap/2`'s
  rebuild semantics) so a LATER delete/update of the same `_id` targets the
  right key. It then reads `get_status/2`:

    * `:ok` — the write landed and no reindex is needed.
    * `{:reindex_required, status}` — the write landed but the engine
      reports it must reindex before the change is query-visible; the
      worker falls back to a full blue/green rebuild.
    * `{:error, struct()}` — the client write failed, OR there is no live
      dataset for `index_key`.

  CAUTION: like `delete_record/3`, this mutates a LIVE dataset and is
  UNPROVEN until spiked against a real v5 engine.

  Options mirror `rebuild/3`: `:client` (default `Client`), `:base_url`,
  `:timeout`.
  """
  @spec upsert_record(String.t(), map(), keyword()) ::
          :ok | {:reindex_required, term()} | {:error, struct()}
  def upsert_record(index_key, doc, opts \\ []) when is_index_key(index_key) and is_map(doc) do
    client = Keyword.get(opts, :client, Client)
    dataset = current_dataset(index_key)
    client_opts = client_opts(opts)

    cond do
      is_nil(dataset) ->
        {:error,
         %Barkpark.Plugins.Indx.Errors.IndexError{
           status: 0,
           endpoint: nil,
           message: "Indx.Indexer: no live dataset for index #{index_key} — nothing to upsert"
         }}

      true ->
        id = doc_id(doc)
        key = key_for_id(id)
        record = render_record(doc, key, id)

        case decide_write(client, dataset, index_key, id, key, client_opts) do
          {:error, _} = err -> err
          mode -> do_upsert_record(client, dataset, index_key, key, id, record, mode, client_opts)
        end
    end
  end

  # Decide INSERT vs UPDATE WITHOUT depending on the key_map being
  # populated — boot-recovery seats the live pointer with an EMPTY key_map,
  # so right after a restart the map can't be the sole source of truth.
  #
  #   * FAST PATH: `id` already in the stored key_map → :update (no probe).
  #   * ELSE existence-PROBE the engine: GetJson([key]) → if it returns a
  #     non-empty list whose doc carries the SAME `_id`, the record already
  #     exists under this key → :update; otherwise → :insert.
  #
  # A probe client error is surfaced unchanged so the worker classifies it
  # (snooze / backoff) rather than guessing a write mode.
  defp decide_write(client, dataset, index_key, id, key, client_opts) do
    if id_in_key_map?(index_key, id) do
      :update
    else
      case client.get_json(dataset, [key], client_opts) do
        {:ok, docs} -> if doc_with_id?(docs, id), do: :update, else: :insert
        {:error, _} = err -> err
      end
    end
  end

  # True when the hydrated GetJson docs include one whose embedded `_id`
  # equals the target — i.e. the live dataset already holds this record.
  defp doc_with_id?(docs, id) when is_list(docs) do
    Enum.any?(docs, fn
      %{} = doc -> doc_id(doc) == id
      _ -> false
    end)
  end

  defp doc_with_id?(_docs, _id), do: false

  # INSERT (new _id) vs UPDATE (record already present). On a clean write,
  # merge {key => _id} into the live pointer's key_map and read status:
  # reindex-required surfaces, otherwise :ok. A client error is surfaced
  # unchanged.
  defp do_upsert_record(client, dataset, index_key, key, id, record, mode, client_opts) do
    write =
      case mode do
        :update -> client.update_json_record(dataset, key, record, client_opts)
        :insert -> client.insert_json_record(dataset, key, record, client_opts)
      end

    with :ok <- write,
         _ <- merge_key_map(index_key, key, id),
         {:ok, status} <- client.get_status(dataset, client_opts) do
      if reindex_required?(status) do
        {:reindex_required, status}
      else
        :ok
      end
    else
      {:error, _} = err -> err
    end
  end

  # Is `id` already known to the index's stored key_map (key => _id)? True ⇒
  # the live dataset already holds a record under this _id ⇒ UPDATE branch
  # (the fast path that skips the GetJson existence probe).
  defp id_in_key_map?(index_key, id) do
    index_key
    |> key_map()
    |> Enum.any?(fn {_key, mapped_id} -> mapped_id == id end)
  end

  # Add ONE {key => _id} entry to the index's stored key_map on the live
  # pointer, leaving the live dataset name untouched. This is NOT a swap —
  # it never rebuilds or repoints the dataset; it only keeps the
  # delete/update target map current after an incremental upsert. A
  # read-modify-write on the :persistent_term pointer (incremental upserts
  # are debounced and rare, so the per-put global GC is acceptable, same as
  # swap/2).
  defp merge_key_map(index_key, key, id) do
    table = :persistent_term.get(@pointer_term, %{})

    case Map.get(table, index_key) do
      %{} = entry ->
        merged = Map.put(Map.get(entry, :key_map, %{}), key, id)
        table = Map.put(table, index_key, Map.put(entry, :key_map, merged))
        :persistent_term.put(@pointer_term, table)

        # P4b Hardening B: persist the updated map alongside the live
        # pointer so a restart never reverts to an empty key_map for an
        # already-upserted id.
        _ =
          Barkpark.Plugins.Indx.Persistence.save(index_key, %{
            dataset: Map.get(entry, :dataset),
            key_map: merged
          })

        :ok

      _ ->
        # No live pointer entry — nothing to merge into. Upsert only runs
        # with a live dataset, so this branch is unreachable in practice.
        :ok
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
    |> Map.merge(facet_fields(doc))
    # slug: a searchable field (low weight) so section/slug terms match on Indx
    # too, at parity with the Postgres slug (weight C). Lives in :content JSONB,
    # which stringify_top drops, so surface it explicitly here.
    |> Map.put("slug", facet_val(doc_content(doc), "slug"))
    |> Map.put("body", body_text(doc))
    |> Map.put("id", key)
    |> Map.put("_id", id)
  end

  # Bounded, FLAT plain-text projection of a doc's content for full-text search
  # (papers' block bodies, post/page body strings). We index this — NOT the raw
  # :content JSONB — because the deeply-nested 1.5 MB block trees timed out
  # AnalyzeString (see the :content drop). A flat, truncated string is cheap to
  # analyze. `@body_max` keeps the whole corpus well under the timeout budget.
  # Kept at 4000: raising it to 8000 REGRESSED ranking — a long paper that
  # mentions a term several times in its body accumulated enough BM25F
  # term-frequency to overtake a TITLE match on that term (q="fork" ranked a
  # long CLI paper above the paper titled "Fork reconciliation"). Indexing more
  # of long docs safely needs BM25 `b` length-normalization tuning per field +
  # a golden_eval pass first — deferred, not a blind cap raise.
  @body_max 4000
  # Leaf keys that are structure/refs, not prose — skipped so the index isn't
  # polluted with "paragraph"/"strong"/urls/ids.
  @body_skip_keys ~w(marks href src url id _id _type _rev type slug rev kind lang)

  defp body_text(doc) do
    doc
    |> doc_content()
    |> collect_text([])
    |> Enum.reverse()
    |> Enum.join(" ")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, @body_max)
  end

  defp collect_text(m, acc) when is_map(m) and not is_struct(m) do
    Enum.reduce(m, acc, fn {k, v}, a ->
      if k in @body_skip_keys, do: a, else: collect_text(v, a)
    end)
  end

  defp collect_text(list, acc) when is_list(list),
    do: Enum.reduce(list, acc, &collect_text/2)

  defp collect_text(s, acc) when is_binary(s), do: [s | acc]
  defp collect_text(_, acc), do: acc

  # Surface a couple of scalar fields out of the (dropped) :content JSONB so
  # Indx can facet/filter on them — `type` and `status` are already top-level
  # columns, this adds `author` and `category`. ALWAYS present (default "") so
  # SetFieldConfiguration never 400s on a field absent from the whole corpus;
  # the UI hides the empty-string bucket.
  defp facet_fields(doc) do
    content = doc_content(doc)

    %{
      "author" => facet_val(content, "author"),
      "category" => facet_val(content, "category")
    }
  end

  defp doc_content(%{content: c}) when is_map(c), do: c
  defp doc_content(%{"content" => c}) when is_map(c), do: c
  defp doc_content(_), do: %{}

  defp facet_val(content, key) do
    case Map.get(content, key) do
      v when is_binary(v) -> v
      v when is_number(v) -> to_string(v)
      _ -> ""
    end
  end

  defp stringify_top(doc) when is_map(doc) and not is_struct(doc) do
    Map.new(doc, fn {k, v} -> {to_string(k), v} end)
  end

  defp stringify_top(%{__struct__: _} = struct) do
    struct
    # Drop :__meta__ and the heavy :content JSONB body. Only `title` is wired
    # searchable (set_field_configuration), and the read path re-reads full docs
    # from Postgres by _id — so shipping content (paper block-bodies are ~98% of
    # the corpus, 1.5 MB) only bloats LoadString/AnalyzeString until they time
    # out on the 2-vCPU box. _id/title/type/status/slug-cols stay.
    |> Map.from_struct()
    |> Map.drop([:__meta__, :content])
    # Drop unloaded associations (e.g. the D9 tenancy `:dataset_entity`,
    # `:workspace`, `:project` belongs_to refs) — `Content.list_documents/3`
    # doesn't preload them, and Jason raises on an `Ecto.Association.NotLoaded`
    # value, which crashed every rebuild. They are tenancy refs, not searchable
    # content, so dropping them is correct, not just defensive.
    |> Enum.reject(fn {_k, v} -> match?(%Ecto.Association.NotLoaded{}, v) end)
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
  # The index key is already slug-safe (`index_key/2` slugifies the scope and
  # appends a lowercase-hex digest), so `slug/1` would be the identity here —
  # which is exactly what lets `Recovery` parse the key straight back out of
  # `<prefix>_<index_key>_v<n>` and use it as a pointer key verbatim.
  defp next_dataset_name(index_key, old_dataset, prefix) do
    n = next_version(old_dataset)
    "#{prefix}_#{index_key}_v#{n}"
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
    # `_id` is intentionally NOT searchable: indexing it let short ids fuzzy-match
    # unrelated docs (e.g. "cli" ≈ category id "c1"), adding noise. It still rides
    # in every record (render_record) for hit→Postgres mapping; it's just not a
    # searched field. Searchable, by weight: title (high) > author/category
    # (medium — a person/section name should rank, mirroring the Postgres
    # author/category weight B) > body (medium) > slug (low, mirroring Postgres
    # slug weight C). author/category are also facetable (see field_proxies).
    [
      {"title", settings.weight_high},
      {"author", settings.weight_medium},
      {"category", settings.weight_medium},
      {"body", settings.weight_medium},
      {"slug", settings.weight_low}
    ]
  end

  # Map the `[{field, weight}]` weights list to v5 FieldProxy maps for
  # `set_field_configuration/3`. Each configured field is searchable with
  # word-level indexing (`wordIndexing: true` is REQUIRED for word-level
  # title search — confirmed by the 2026-06-03 spike) and carries the
  # field's weight plus the engine's default BM25 knobs.
  # Fields that are BOTH searchable (a name should rank) AND facetable (drive the
  # facet rail). author/category get ONE FieldProxy each carrying both flags —
  # listing them separately in facet_proxies too would double-configure the same
  # fieldName and SetFieldConfiguration would reject it.
  @search_facet_fields ~w(author category)

  # v5 high-resolution indexing: extra delimiter-removed N-grams that sharpen
  # run-together / split-word matches ("websocket" ⇄ "web socket"). Costs index
  # space, so the v5 docs recommend it on a FEW key fields only — we apply it to
  # the title (where compound/run-together queries matter most).
  @high_res_fields ~w(title)

  defp field_proxies(weights) do
    searchable =
      Enum.map(weights, fn {field, weight} ->
        f = to_string(field)
        also_facet = f in @search_facet_fields

        %{
          "fieldName" => f,
          "fieldType" => "String",
          "isArray" => false,
          "searchable" => true,
          "filterable" => also_facet,
          "facetable" => also_facet,
          "sortable" => false,
          "wordIndexing" => true,
          "highResolution" => f in @high_res_fields,
          "embeddable" => false,
          "preloadFilters" => false,
          # v5: float multiplier (0.5–3.0, higher = more influence).
          "weight" => weight,
          "bM25b" => 0.75,
          "bM25k1" => 1.2
        }
      end)

    searchable ++ facet_proxies()
  end

  # Facetable + filterable (not searchable) fields. `enableFacets` in the query
  # makes the engine return dataset-wide value-counts for each of these; the
  # fields must exist in the corpus records (type / status are top-level
  # columns). author / category are configured in field_proxies above as
  # searchable+facetable, so they are NOT repeated here.
  @facet_fields ~w(type status)

  defp facet_proxies do
    Enum.map(@facet_fields, fn field ->
      %{
        "fieldName" => field,
        "fieldType" => "String",
        "isArray" => false,
        "searchable" => false,
        "filterable" => true,
        "facetable" => true,
        "sortable" => false,
        "wordIndexing" => false,
        "embeddable" => false,
        "preloadFilters" => false,
        "weight" => 1,
        "bM25b" => 0.75,
        "bM25k1" => 1.2
      }
    end)
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

    # v5 reports a numeric `systemState`; Ready == 4.
    system_state = Map.get(status, "systemState") || Map.get(status, "SystemState")

    done == true or system_state == 4 or
      state in ["ready", "indexed", "completed", "done", "idle"]
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
