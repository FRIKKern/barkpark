defmodule Barkpark.Plugins.Indx.Recovery do
  @moduledoc """
  Boot-time live-pointer recovery for the Indx plugin.

  The per-scope live dataset pointer + key_map live in `:persistent_term`
  (see `Barkpark.Plugins.Indx.Indexer`), which is wiped on every Barkpark
  restart. With `incremental_upsert` ON this is fatal: after a restart
  `Indexer.current_dataset(scope)` is `nil`, so an upsert has no dataset to
  write to and engine `"indx"` queries come back empty until a manual
  reseed. This GenServer self-heals the pointer at boot so Indx can run
  always-on.

  ## What it does (asynchronously, never blocks boot)

  Started under the host supervision tree via the plugin's
  `register_workers/1` (alongside `Indx.Auth`). `init/1` returns
  immediately and schedules the recovery via `handle_continue/2`, so a slow
  or unreachable Indx never delays boot and a failure never crashes the
  supervision tree (the whole pass is wrapped in `try/rescue`).

  The recovery:

    1. `Client.get_user_datasets/1` to list the datasets the Indx user owns.
       On `{:error, _}` (Indx down / unconfigured) it is a no-op + debug log
       — the upsert rebuild-fallback in `IndexerWorker` is the backstop.
    2. Parse names of the form `<prefix>_<index_key>_v<n>` (prefix from
       `Settings.dataset_prefix`, default `"bp"`), group by index key, and
       pick the MAX version `n` per index key.
    3. For each index key, `Indexer.restore_pointer/2` seats the live pointer
       to that dataset with an EMPTY key_map — but ONLY when that index has no
       live pointer yet (so a rebuild that already ran is never clobbered).

  ## The parsed segment IS the index key

  `Indexer.next_dataset_name/3` names a dataset `<prefix>_<index_key>_v<n>`,
  and an index key from `Indexer.index_key/2` is already slug-safe
  (`<slugified-scope>_t<16 hex>`), so the segment this module parses out is the
  pointer key verbatim — no slug→scope reverse map is needed, and the tenancy
  partition survives a restart.

  Names whose parsed segment is NOT a well-formed index key are SKIPPED with a
  debug log rather than passed on. That covers a dataset left behind by a
  release that named datasets `<prefix>_<scope>_v<n>` (tenant-blind), plus any
  unrelated dataset in the same Indx account: seating a pointer from one would
  re-establish exactly the shared, tenant-blind slot this partition removes.
  Skipping costs nothing — the first save re-enqueues a rebuild, which creates
  the correctly-keyed dataset.
  """

  use GenServer

  require Logger

  alias Barkpark.Plugins.Indx.{Client, Indexer, Persistence, Settings}

  # `Indexer.is_index_key/1` is a defguard (a macro), so it must be required
  # before `parse/2` can use it to reject a tenant-blind dataset name.
  require Barkpark.Plugins.Indx.Indexer

  @doc "Start the recovery GenServer. Registered under the module name."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    # Return immediately; do the (network-touching) recovery off the boot
    # path via handle_continue so a slow/unreachable Indx never delays boot.
    {:ok, %{opts: opts}, {:continue, :recover}}
  end

  @impl true
  def handle_continue(:recover, state) do
    recover(state.opts)
    {:noreply, state}
  end

  @doc """
  Run one recovery pass. Listed datasets are grouped by parsed index key and
  the MAX-version dataset per index key re-seats that index's live pointer
  (only when it has no live pointer). Tolerant: any failure is logged, never
  raised, and an Indx-down client error is a quiet no-op (the upsert
  rebuild-fallback is the backstop).

  Injectable for unit tests: `:client` (default `Client`) and `:base_url`.
  Returns `:ok` always.
  """
  @spec recover(keyword()) :: :ok
  def recover(opts \\ []) do
    client = Keyword.get(opts, :client, Client)
    client_opts = Keyword.take(opts, [:base_url, :timeout])
    prefix = Settings.get().dataset_prefix

    # P4b Hardening B: rehydrate the persisted key_map for each index BEFORE
    # the live-dataset rediscovery seats the pointer. `Indexer.restore_pointer/2`
    # reads from the persisted file and uses that key_map verbatim when its
    # `dataset` matches what the engine reports — so a fresh boot now arrives
    # at the EXACT same {dataset, key_map} state as before the restart, and
    # `delete_target_keys/2`'s bare-hash branch never fires in normal
    # operation.
    persisted = Persistence.load_all()

    case client.get_user_datasets(client_opts) do
      {:ok, names} when is_list(names) ->
        names
        |> latest_per_index(prefix)
        |> Enum.each(fn {index_key, dataset} ->
          case Indexer.restore_pointer(index_key, dataset) do
            :ok ->
              size = persisted |> Map.get(index_key, %{}) |> Map.get(:key_map, %{}) |> map_size()

              Logger.info(
                "Indx.Recovery: restored pointer index=#{index_key} dataset=#{dataset} key_map=#{size} entries"
              )

            :noop ->
              :ok
          end
        end)

        :ok

      {:error, reason} ->
        # Indx down / unconfigured. The first edit after a restart triggers
        # the IndexerWorker upsert → rebuild self-heal, so this is benign.
        Logger.debug(
          "Indx.Recovery: get_user_datasets failed, skipping recovery: #{inspect(reason)}"
        )

        :ok
    end
  rescue
    e ->
      Logger.warning("Indx.Recovery: recovery pass failed (ignored): #{Exception.message(e)}")
      :ok
  end

  # Group `<prefix>_<index_key>_v<n>` dataset names by parsed index key, keeping
  # the MAX version's full dataset name per index key. Names that don't match
  # the shape are dropped. Returns a list of {index_key, dataset}.
  defp latest_per_index(names, prefix) do
    names
    |> Enum.flat_map(fn name -> parse(name, prefix) end)
    |> Enum.group_by(fn {index_key, _ver, _name} -> index_key end)
    |> Enum.map(fn {index_key, entries} ->
      {_key, _ver, dataset} = Enum.max_by(entries, fn {_k, ver, _n} -> ver end)
      {index_key, dataset}
    end)
  end

  # Parse one `<prefix>_<index_key>_v<n>` name → [{index_key, version, name}]
  # or []. The parsed segment IS the pointer key (see moduledoc). A segment
  # that is not a well-formed index key — a tenant-blind name from an older
  # release, or a foreign dataset in the same Indx account — is SKIPPED, not
  # seated: seating it would recreate the shared, tenant-blind pointer slot.
  defp parse(name, prefix) when is_binary(name) do
    case Regex.run(~r/^#{Regex.escape(prefix)}_(.+)_v(\d+)$/, name) do
      [_, index_key, ver] when index_key != "" ->
        if Indexer.is_index_key(index_key) do
          [{index_key, String.to_integer(ver), name}]
        else
          Logger.debug(
            "Indx.Recovery: skipping dataset #{name} — `#{index_key}` is not a " <>
              "tenant-partitioned index key (pre-partition or foreign dataset)"
          )

          []
        end

      _ ->
        []
    end
  end

  defp parse(_name, _prefix), do: []
end
