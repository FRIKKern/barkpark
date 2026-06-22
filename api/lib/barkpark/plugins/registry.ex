defmodule Barkpark.Plugins.Registry do
  @moduledoc """
  Boot-time registry of `use Barkpark.Plugin` modules — keyed by `plugin_name`
  (decision D20), populated by `discover_and_register/1` from
  `Barkpark.Application.start/2`.

  Thin **facade** over the GenServer state plus four concern modules; the
  public API and all boot/resolution semantics are unchanged — every former
  internal function now lives in a focused submodule the facade `defdelegate`s
  into:

    * `Registry.Discovery` — disk walk, manifest→module resolution, the
      `:plugins` kill-switch / whitelist, `discover_and_register/*`.
    * `Registry.ResolverChain` — `reduce_resolvers/3` plus the additive-lift,
      load-order, top-menu, and duplicate-form machinery.
    * `Registry.BootCollectors` — `collect_workers/1`, `collect_oban_crontab/0`,
      `collect_routes/1` (boot-/compile-time, GenServer-independent).
    * `Registry.PluginCallbacks` — first-wins content renderer / test
      connection, codelist-seeder execution, media hooks.

  The GenServer itself (`register/2`, `lookup/1`, `all/0`, `reset/0`,
  `capture_baseline/0`, the `:persistent_term` snapshot cache) stays here.

  ## Collectors, caching, source of truth

  Collectors funnel through `ResolverChain.reduce_resolvers/3`, threading a
  `(prev, ctx) -> next` chain over every plugin in load order. Each `collect_X`
  takes `:baseline` (initial `prev`; defaults `[]` for lists, `%{}` for maps)
  and `:ctx` (defaults `%{}`); legacy zero-opt callers keep the empty baseline
  + empty ctx — see the `Barkpark.Plugin` `@callback` docs for per-callback ctx
  shapes.

  Plugin iteration order: `Application.get_env(:barkpark, :plugins, [])` when
  configured, else `all/0` sorted alphabetically (legacy). Names resolve via
  `lookup/1`; configured-but-unregistered names are skipped with a debug log.

  Caching: `all/0` and the legacy zero-arg `collect_action_handlers/0`,
  `collect_external_sync_entries/0`, `collect_top_menu_entries/0` short-circuit
  through a `:persistent_term` snapshot ONLY when called with no opts (the
  empty-baseline/empty-ctx resolution). Any `:baseline`/`:ctx` bypasses the
  cache. The snapshot refreshes on every mutation (`register/2`); we write on
  mutation only, never on read (each `:persistent_term.put/2` triggers a global
  GC). The ctx-/side-effect-dependent collectors (`collect_desk_items/1`,
  `collect_checkers/1`, `collect_doc_actions/1`, `collect_api_tests/1`,
  `run_all_codelist_seeders/0`, …) always run the live chain.
  """

  use GenServer
  require Logger

  alias Barkpark.Plugins.Registry.BootCollectors
  alias Barkpark.Plugins.Registry.Discovery
  alias Barkpark.Plugins.Registry.PluginCallbacks
  alias Barkpark.Plugins.Registry.ResolverChain

  @name __MODULE__
  @snapshot_key {__MODULE__, :snapshot}

  # ─── Public API ─────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @spec register(module(), map()) :: :ok | {:error, :no_plugin_name}
  def register(module, manifest) when is_atom(module) and is_map(manifest) do
    GenServer.call(@name, {:register, module, manifest})
  end

  @spec lookup(String.t()) ::
          {:ok, %{module: module(), manifest: map(), name: String.t()}} | :error
  def lookup(plugin_name) when is_binary(plugin_name) do
    GenServer.call(@name, {:lookup, plugin_name})
  end

  @doc """
  Test-isolation helper — restores the Registry to its BASELINE plugin set and
  re-snapshots `:persistent_term` to match.

  The Registry's `state.plugins` only ever grows (no production `unregister/1`),
  so every test that `register/2`s a fake leaks into the shared state AND the
  `:persistent_term` read cache, breaking order-dependent sibling assertions.
  `reset/0` restores the once-captured boot-time baseline (OnixEdit, media) and
  re-runs `refresh_snapshot/1`, wiping any sibling-left poison. Idempotent, no
  production caller — wire it through `Barkpark.RegistryCase` (`setup`/`on_exit`).
  """
  @spec reset() :: :ok
  def reset do
    GenServer.call(@name, :reset)
  end

  @doc """
  Eagerly freezes the current plugin set as the `reset/0` baseline. Called at
  the end of `discover_and_register/0` so the baseline captures the real boot
  set BEFORE any test stub registers. Idempotent (no-op once frozen).
  """
  @spec capture_baseline() :: :ok
  def capture_baseline do
    GenServer.call(@name, :capture_baseline)
  end

  @spec all() :: [%{module: module(), manifest: map(), name: String.t()}]
  def all do
    case :persistent_term.get(@snapshot_key, nil) do
      %{plugins: plugins} -> plugins
      nil -> GenServer.call(@name, :all)
    end
  end

  # ─── Cached collectors ──────────────────────────────────────────────────
  # These read the `:persistent_term` snapshot directly when called with no
  # opts, and fall through to the resolver chain otherwise.

  @doc """
  Drives the `resolve_action_handlers/2` chain → merged
  `%{action_name => handler_fn}`. No-opt callers hit the cached snapshot;
  `:baseline`/`:ctx` run the live chain. See moduledoc.
  """
  @spec collect_action_handlers(keyword()) ::
          %{optional(String.t()) => Barkpark.Plugin.action_handler()}
  def collect_action_handlers(opts \\ []) do
    if opts == [] do
      case :persistent_term.get(@snapshot_key, nil) do
        %{action_handlers: handlers} ->
          handlers

        nil ->
          baseline = Keyword.get(opts, :baseline, %{})
          ctx = Keyword.get(opts, :ctx, %{})
          ResolverChain.reduce_resolvers(:resolve_action_handlers, baseline, ctx)
      end
    else
      baseline = Keyword.get(opts, :baseline, %{})
      ctx = Keyword.get(opts, :ctx, %{})
      ResolverChain.reduce_resolvers(:resolve_action_handlers, baseline, ctx)
    end
  end

  @doc """
  Drives the `resolve_external_sync_entries/2` chain → merged registry map.
  No-opt callers hit the cached snapshot; `:baseline`/`:ctx` run the live chain.
  """
  @spec collect_external_sync_entries(keyword()) :: %{optional(String.t()) => map()}
  def collect_external_sync_entries(opts \\ []) do
    if opts == [] do
      case :persistent_term.get(@snapshot_key, nil) do
        %{external_sync_entries: entries} ->
          entries

        nil ->
          ResolverChain.reduce_resolvers(:resolve_external_sync_entries, %{}, %{})
      end
    else
      baseline = Keyword.get(opts, :baseline, %{})
      ctx = Keyword.get(opts, :ctx, %{})
      ResolverChain.reduce_resolvers(:resolve_external_sync_entries, baseline, ctx)
    end
  end

  @doc """
  Drives the `resolve_top_menu_entries/2` chain; the result is normalised
  (`:order` defaults to 100) and sorted by `{order, label}` for determinism.
  No-opt callers hit the cached snapshot; `:baseline`/`:ctx` run the live chain.
  """
  @spec collect_top_menu_entries(keyword()) :: [Barkpark.Plugin.top_menu_entry()]
  def collect_top_menu_entries(opts \\ []) do
    if opts == [] do
      case :persistent_term.get(@snapshot_key, nil) do
        %{top_menu_entries: entries} ->
          entries

        nil ->
          ResolverChain.compute_top_menu_entries([], %{})
      end
    else
      baseline = Keyword.get(opts, :baseline, [])
      ctx = Keyword.get(opts, :ctx, %{})
      ResolverChain.compute_top_menu_entries(baseline, ctx)
    end
  end

  @doc """
  Drives the `resolve_desk_items/2` chain → flat concatenated list. Accepts a
  binary (legacy `collect_desk_items("production")`, folded into
  `ctx = %{dataset: dataset}`) or a keyword list (`:baseline` / `:ctx`).
  Not cached — desk items vary per dataset/ctx.
  """
  @spec collect_desk_items(String.t() | keyword()) :: [Barkpark.Plugin.desk_item()]
  def collect_desk_items(dataset_or_opts \\ "production")

  def collect_desk_items(dataset) when is_binary(dataset) do
    ResolverChain.reduce_resolvers(:resolve_desk_items, [], %{dataset: dataset})
  end

  def collect_desk_items(opts) when is_list(opts) do
    baseline = Keyword.get(opts, :baseline, [])
    ctx = Keyword.get(opts, :ctx, %{})
    ResolverChain.reduce_resolvers(:resolve_desk_items, baseline, ctx)
  end

  @doc """
  Drives the `resolve_checkers/2` chain → flat list of `{name, module}`
  checker pairs. Not cached; accepts `:baseline` / `:ctx`.
  """
  @spec collect_checkers(keyword()) :: [Barkpark.Plugin.checker()]
  def collect_checkers(opts \\ []) do
    baseline = Keyword.get(opts, :baseline, [])
    ctx = Keyword.get(opts, :ctx, %{})
    ResolverChain.reduce_resolvers(:resolve_checkers, baseline, ctx)
  end

  @doc """
  Drives the `resolve_codelist_seeders/2` chain → flat list of zero-arg seeder
  functions. To EXECUTE them use `run_all_codelist_seeders/0`. Accepts
  `:baseline` / `:ctx`.
  """
  @spec collect_codelist_seeders(keyword()) :: [(-> any())]
  def collect_codelist_seeders(opts \\ []) do
    baseline = Keyword.get(opts, :baseline, [])
    ctx = Keyword.get(opts, :ctx, %{})
    ResolverChain.reduce_resolvers(:resolve_codelist_seeders, baseline, ctx)
  end

  @doc """
  Drives the `resolve_settings_schema/2` chain → flat list of declarative
  settings fields. Accepts `:baseline` / `:ctx` (host passes
  `%{plugin_name: name}` in `:ctx` for the resolver-aware cross-plugin view).
  """
  @spec collect_settings_schema(keyword()) :: [Barkpark.Plugin.setting_field()]
  def collect_settings_schema(opts \\ []) do
    baseline = Keyword.get(opts, :baseline, [])
    ctx = Keyword.get(opts, :ctx, %{})
    ResolverChain.reduce_resolvers(:resolve_settings_schema, baseline, ctx)
  end

  @doc """
  Drives the `resolve_doc_actions/2` chain (no additive predecessor — plugins
  implement the resolver directly to filter/reorder/amend per-doc actions).
  Host seeds `:baseline` with schema `:actions` and `ctx = %{dataset, doc_id,
  doc_type, doc}` for live-payload decisions.
  """
  @spec collect_doc_actions(keyword()) :: [Barkpark.Plugin.doc_action()]
  def collect_doc_actions(opts \\ []) do
    baseline = Keyword.get(opts, :baseline, [])
    ctx = Keyword.get(opts, :ctx, %{})
    ResolverChain.reduce_resolvers(:resolve_doc_actions, baseline, ctx)
  end

  @doc """
  Drives the `resolve_extract_edges/2` chain — the content-graph edge
  collector. `Barkpark.EdgeProjector.Projector` seeds `:baseline` with the
  document's CORE reference-field edges and `ctx = %{doc, dataset}`; each
  plugin UNIONS its edges via the `prev ++ extract_edges(ctx.doc, ctx)` default
  lift. With plugins `[]` returns the baseline unchanged (fresh-install
  invariant). NOT cached — per-document / ctx-dependent.
  """
  @spec collect_edge_extractors(keyword()) :: [Barkpark.Plugin.edge()]
  def collect_edge_extractors(opts \\ []) do
    baseline = Keyword.get(opts, :baseline, [])
    ctx = Keyword.get(opts, :ctx, %{})
    ResolverChain.reduce_resolvers(:resolve_extract_edges, baseline, ctx)
  end

  @doc """
  Drives the `resolve_api_tests/2` chain → flat list of `api_test_spec()` maps
  the runner fires on demand. Not cached; accepts `:baseline` / `:ctx`. Plugins
  usually implement additive `api_tests/0` (default resolver lifts via
  `prev ++ result`); override the resolver to filter/reorder.
  """
  @spec collect_api_tests(keyword()) :: [Barkpark.Plugin.api_test_spec()]
  def collect_api_tests(opts \\ []) do
    baseline = Keyword.get(opts, :baseline, [])
    ctx = Keyword.get(opts, :ctx, %{})
    ResolverChain.reduce_resolvers(:resolve_api_tests, baseline, ctx)
  end

  @doc """
  Drives the `resolve_cli_commands/2` chain → flat list of `cli_command()` maps
  the `/v1/capabilities` controller folds into the manifest's `commands[]`. Not
  cached; accepts `:baseline` / `:ctx`. Plugins usually implement additive
  `cli_commands/0` (default resolver lifts via `prev ++ result`).
  """
  @spec collect_cli_commands(keyword()) :: [Barkpark.Plugin.cli_command()]
  def collect_cli_commands(opts \\ []) do
    baseline = Keyword.get(opts, :baseline, [])
    ctx = Keyword.get(opts, :ctx, %{})
    ResolverChain.reduce_resolvers(:resolve_cli_commands, baseline, ctx)
  end

  # ─── Delegations ────────────────────────────────────────────────────────
  # Public surface preserved verbatim; canonical docs live on each delegated
  # target module (ResolverChain · PluginCallbacks · BootCollectors · Discovery).

  @doc false
  @spec reduce_resolvers(atom(), term(), map()) :: term()
  defdelegate reduce_resolvers(callback_name, baseline, ctx), to: ResolverChain

  @spec warn_duplicate_forms() :: :ok
  defdelegate warn_duplicate_forms, to: ResolverChain

  @spec collect_content_renderer(String.t(), map(), map()) :: {:ok, iodata()} | :none
  defdelegate collect_content_renderer(doc_type, content, ctx \\ %{}), to: PluginCallbacks

  @spec collect_test_connection(plugin_name :: String.t() | atom(), settings :: map()) ::
          Barkpark.Plugin.test_connection_result() | {:error, :plugin_not_found}
  defdelegate collect_test_connection(plugin_name, settings), to: PluginCallbacks

  @spec run_all_codelist_seeders() :: :ok
  defdelegate run_all_codelist_seeders, to: PluginCallbacks

  @spec run_codelist_seeders_by_name(String.t()) :: :ok | {:error, :unknown_plugin}
  defdelegate run_codelist_seeders_by_name(plugin_name), to: PluginCallbacks

  @spec run_after_media_upload(map()) :: :ok
  defdelegate run_after_media_upload(ctx), to: PluginCallbacks

  @spec run_after_media_delete(map()) :: :ok
  defdelegate run_after_media_delete(ctx), to: PluginCallbacks

  @spec asset_doc_id_for_media_file(String.t(), String.t()) :: String.t() | nil
  defdelegate asset_doc_id_for_media_file(media_file_id, dataset), to: PluginCallbacks

  @spec collect_workers(map()) :: [Supervisor.child_spec() | {module(), term()} | module()]
  defdelegate collect_workers(ctx \\ %{}), to: BootCollectors

  @spec collect_oban_crontab() :: [
          {String.t(), module()} | {String.t(), module(), keyword()}
        ]
  defdelegate collect_oban_crontab, to: BootCollectors

  @spec collect_routes(map()) :: [Barkpark.Plugin.route_spec()]
  defdelegate collect_routes(ctx \\ %{}), to: BootCollectors

  @spec discover_and_register() :: :ok
  defdelegate discover_and_register, to: Discovery

  @spec discover_and_register([Path.t()]) :: :ok
  defdelegate discover_and_register(paths), to: Discovery

  @spec resolve_module(map()) :: {:ok, module()} | {:error, :no_plugin_name}
  defdelegate resolve_module(manifest), to: Discovery

  # ─── Snapshot cache refresh ─────────────────────────────────────────────

  # Re-snapshot the cache from the GenServer state. Called from every
  # mutation handler. Single `:persistent_term.put/2` ⇒ one global GC.
  #
  # Snapshot values are computed via the resolver chain with empty baseline
  # and empty ctx — the same shape legacy zero-arg callers expect. Any
  # caller passing `:baseline` or `:ctx` bypasses the cache.
  defp refresh_snapshot(state) do
    plugins = Map.values(state.plugins)

    # Temporarily install the new plugin list so `reduce_resolvers/3`
    # (which reads from `all/0` via `:persistent_term`) sees ground truth
    # during the refresh.
    :persistent_term.put(@snapshot_key, %{
      plugins: plugins,
      action_handlers: %{},
      external_sync_entries: %{},
      top_menu_entries: []
    })

    :persistent_term.put(@snapshot_key, %{
      plugins: plugins,
      action_handlers: ResolverChain.reduce_resolvers(:resolve_action_handlers, %{}, %{}),
      external_sync_entries:
        ResolverChain.reduce_resolvers(:resolve_external_sync_entries, %{}, %{}),
      top_menu_entries: ResolverChain.compute_top_menu_entries([], %{})
    })

    state
  end

  # ─── GenServer ──────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    # `baseline_plugins` starts nil and is frozen eagerly by the
    # `:capture_baseline` call at the end of `discover_and_register/0`.
    # `nil` means "not yet frozen" — `reset/0` falls back to `state.plugins`
    # as a safety net for callers that skip discovery entirely (e.g. tests
    # that set the kill-switch env before any reset). See
    # `handle_call(:capture_baseline, …)` and `handle_call(:reset, …)`.
    {:ok, %{plugins: %{}, baseline_plugins: nil}}
  end

  @impl true
  def handle_call({:register, module, manifest}, _from, state) do
    case manifest["plugin_name"] do
      name when is_binary(name) and name != "" ->
        entry = %{name: name, module: module, manifest: manifest}
        new_state = %{state | plugins: Map.put(state.plugins, name, entry)}
        refreshed = refresh_snapshot(new_state)
        # Log duplicate-form warnings after the new plugin lands in the
        # snapshot so `all/0` reflects ground truth during the scan.
        _ = ResolverChain.warn_duplicate_forms()
        {:reply, :ok, refreshed}

      _ ->
        {:reply, {:error, :no_plugin_name}, state}
    end
  end

  def handle_call({:lookup, name}, _from, state) do
    case Map.fetch(state.plugins, name) do
      {:ok, entry} -> {:reply, {:ok, entry}, state}
      :error -> {:reply, :error, state}
    end
  end

  def handle_call(:all, _from, state) do
    {:reply, Map.values(state.plugins), state}
  end

  # Eagerly freeze the current plugin set as the baseline.
  # Called at the end of discover_and_register/0 so the baseline is always
  # the post-discovery set, never a test-polluted set.
  # Idempotent: a second call is a no-op (baseline already frozen).
  def handle_call(:capture_baseline, _from, state) do
    new_state =
      case state.baseline_plugins do
        nil -> %{state | baseline_plugins: state.plugins}
        _already_frozen -> state
      end

    {:reply, :ok, new_state}
  end

  # Test-isolation reset. Two phases:
  #
  #   1. First call freezes the current `state.plugins` as the baseline.
  #      Because the first test's `setup` runs after boot discovery has
  #      populated the registry, this captures OnixEdit + media + any other
  #      bundled plugin — the "real" set tests expect to see.
  #   2. Every call (including the first) restores `state.plugins` to the
  #      frozen baseline and re-snapshots `:persistent_term` through the
  #      same `refresh_snapshot/1` path `register/2` uses, so a poisoned
  #      snapshot left by a sibling test is fully overwritten.
  def handle_call(:reset, _from, state) do
    baseline =
      case state.baseline_plugins do
        nil -> state.plugins
        captured -> captured
      end

    new_state = %{state | plugins: baseline, baseline_plugins: baseline}
    refreshed = refresh_snapshot(new_state)
    {:reply, :ok, refreshed}
  end
end
