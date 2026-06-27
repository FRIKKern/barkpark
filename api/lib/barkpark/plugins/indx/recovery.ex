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
    2. Parse names of the form `<prefix>_<scope>_v<n>` (prefix from
       `Settings.dataset_prefix`, default `"bp"`), group by scope, and pick
       the MAX version `n` per scope.
    3. For each scope, `Indexer.restore_pointer/2` seats the live pointer to
       that dataset with an EMPTY key_map — but ONLY when the scope has no
       live pointer yet (so a rebuild that already ran is never clobbered).

  ## slug == scope assumption

  The parsed `<scope>` segment is a SLUGIFIED scope (`Indexer.slug/1` lower-
  cases + underscores it). For every current Barkpark scope ("production")
  the slug equals the scope verbatim, so we use the parsed segment directly
  as the pointer key. A future scope whose name slugifies to something else
  would need a slug→scope reverse map; today none does.
  """

  use GenServer

  require Logger

  alias Barkpark.Plugins.Indx.{Client, Indexer, Persistence, Settings}

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
  Run one recovery pass. Listed datasets are grouped by parsed scope and the
  MAX-version dataset per scope re-seats that scope's live pointer (only when
  the scope has no live pointer). Tolerant: any failure is logged, never
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

    # P4b Hardening B: rehydrate the persisted key_map for each scope BEFORE
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
        |> latest_per_scope(prefix)
        |> Enum.each(fn {scope, dataset} ->
          case Indexer.restore_pointer(scope, dataset) do
            :ok ->
              size = persisted |> Map.get(scope, %{}) |> Map.get(:key_map, %{}) |> map_size()

              Logger.info(
                "Indx.Recovery: restored pointer scope=#{scope} dataset=#{dataset} key_map=#{size} entries"
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

  # Group `<prefix>_<scope>_v<n>` dataset names by parsed scope, keeping the
  # MAX version's full dataset name per scope. Names that don't match the
  # shape are dropped. Returns a list of {scope, dataset}.
  defp latest_per_scope(names, prefix) do
    names
    |> Enum.flat_map(fn name -> parse(name, prefix) end)
    |> Enum.group_by(fn {scope, _ver, _name} -> scope end)
    |> Enum.map(fn {scope, entries} ->
      {_scope, _ver, dataset} = Enum.max_by(entries, fn {_s, ver, _n} -> ver end)
      {scope, dataset}
    end)
  end

  # Parse one `<prefix>_<scope>_v<n>` name → [{scope, version, name}] or [].
  # The scope segment is the SLUGIFIED scope (see moduledoc): for current
  # scopes slug == scope, so it doubles as the pointer key directly.
  defp parse(name, prefix) when is_binary(name) do
    case Regex.run(~r/^#{Regex.escape(prefix)}_(.+)_v(\d+)$/, name) do
      [_, scope, ver] when scope != "" -> [{scope, String.to_integer(ver), name}]
      _ -> []
    end
  end

  defp parse(_name, _prefix), do: []
end
