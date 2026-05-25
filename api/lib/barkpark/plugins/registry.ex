defmodule Barkpark.Plugins.Registry do
  @moduledoc """
  Boot-time registry of `use Barkpark.Plugin` modules.

  Populated by `discover_and_register/1` from `Barkpark.Application`'s
  supervisor `start/2` callback. Lookup keyed by `plugin_name` (decision D20).

  Discovery walks two roots by default:

    * `Application.app_dir(:barkpark, "priv/plugins")` — bundled plugins
    * `Mix.Project.deps_path/0` — when Mix is loaded (dev/test)

  Each subdirectory containing a `plugin.json` is treated as a plugin. The
  module to register is derived from the manifest's `module` field if
  present, otherwise from `plugin_name` (PascalCased under
  `Barkpark.Plugins.<Name>`). Modules that fail to load are logged and
  skipped — discovery NEVER raises.

  ## Resolver chain (Goal barkpark-cjs, task s2)

  Seven collectors plus `collect_doc_actions/1` and `collect_api_tests/1`
  drive a per-callback resolver chain — `(prev, ctx) -> next` — through
  every registered plugin in load order. Each `collect_X/1` accepts a
  keyword list with two optional keys:

    * `:baseline` — initial `prev` value the host seeds. Defaults to `[]`
      for list-shaped collectors, `%{}` for map-shaped ones. Lets the host
      (task s3) thread its built-in baseline through plugins so plugins can
      drop, reorder, or amend host items — symmetric with how they treat
      other plugins' contributions.
    * `:ctx` — per-callback context map documented on each
      `Barkpark.Plugin` resolver `@callback`. Defaults to `%{}`.

  Backwards compatibility: every `collect_X` defaults `opts` to `[]`, so
  legacy callers (`Registry.collect_top_menu_entries()`,
  `Registry.collect_desk_items("production")`) keep compiling and behave
  identically — `prev` defaults to the empty baseline, `ctx` to `%{}`.

  ## Plugin iteration source of truth

  `reduce_resolvers/3` iterates plugins via this precedence:

    1. `Application.get_env(:barkpark, :plugins, [])` — the explicit
       load-order list per plan §0 Q2, when configured.
    2. Otherwise the GenServer-backed `all/0`, sorted alphabetically by
       plugin name — the legacy behaviour, preserved so dev/test plugins
       that register without an Application config entry continue to work.

  Whichever source provides the names, each name is resolved to its
  registered entry via `lookup/1`; plugins listed in config but never
  registered are silently skipped (with a debug log line).

  ## Duplicate-form warning

  `warn_duplicate_forms/0` walks the registered plugins once and logs a
  single `Logger.warning` per plugin/callback pair that defines both the
  resolver (`resolve_X/2`) and the additive form (`X/0` or `X/1`). The
  resolver wins. Run at boot from the registry's `init/1` after discovery,
  and again from each `register/2` mutation so a plugin added at runtime
  doesn't silently slip through.

  ## Caching

  Reads (`all/0`, the legacy zero-arg `collect_action_handlers/0`,
  `collect_external_sync_entries/0`, `collect_top_menu_entries/0`)
  short-circuit through a `:persistent_term` snapshot ONLY when called
  without `:baseline` or `:ctx` — the cached value is the empty-baseline,
  empty-ctx resolution. Any caller passing options bypasses the cache and
  runs the chain on the fly. The snapshot is refreshed on every state
  mutation (currently: `register/2`). Because `:persistent_term.put/2`
  triggers a global GC scan of all live data, we only write on mutation
  — never on read.

  `lookup/1`, `collect_desk_items/1` (dataset-dependent),
  `collect_checkers/1`, `collect_codelist_seeders/1`,
  `collect_settings_schema/1`, `collect_doc_actions/1`,
  `collect_api_tests/1`, and `run_all_codelist_seeders/0` always go
  through the live chain — they either depend on ctx or run
  side-effects.
  """

  use GenServer
  require Logger

  @name __MODULE__
  @snapshot_key {__MODULE__, :snapshot}

  # Resolver-callback ↔ additive-callback metadata. Used by `reduce_resolvers/3`
  # to know how to lift the additive form when a plugin only exports it, and by
  # `warn_duplicate_forms/0` to flag plugins that define both.
  #
  # Shape: %{resolver_name => {additive_name, additive_arity, additive_default, lift_kind}}
  #   * lift_kind :: :list_concat | :map_merge | :none (no additive lift, identity default)
  @resolver_callbacks %{
    resolve_checkers: {:checkers, 0, [], :list_concat},
    resolve_action_handlers: {:action_handlers, 0, %{}, :map_merge},
    resolve_external_sync_entries: {:external_sync_entries, 0, %{}, :map_merge},
    resolve_codelist_seeders: {:codelist_seeders, 0, [], :list_concat},
    resolve_settings_schema: {:settings_schema, 0, [], :list_concat},
    resolve_top_menu_entries: {:top_menu_entries, 0, [], :list_concat},
    resolve_desk_items: {:desk_items, 1, [], :list_concat},
    resolve_doc_actions: {nil, nil, nil, :none},
    resolve_api_tests: {:api_tests, 0, [], :list_concat}
  }

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

  @spec all() :: [%{module: module(), manifest: map(), name: String.t()}]
  def all do
    case :persistent_term.get(@snapshot_key, nil) do
      %{plugins: plugins} -> plugins
      nil -> GenServer.call(@name, :all)
    end
  end

  @doc """
  Walks every registered plugin and drives the `resolve_action_handlers/2`
  chain, returning the final merged `%{action_name => handler_fn}` map.

  Accepts `:baseline` (initial `prev`, defaults to `%{}`) and `:ctx`
  (defaults to `%{}`). Legacy callers pass no opts — the cached snapshot
  (built from empty baseline + empty ctx) short-circuits the chain.

  Plugins that don't implement either the resolver or the additive form
  contribute nothing.
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
          reduce_resolvers(:resolve_action_handlers, baseline, ctx)
      end
    else
      baseline = Keyword.get(opts, :baseline, %{})
      ctx = Keyword.get(opts, :ctx, %{})
      reduce_resolvers(:resolve_action_handlers, baseline, ctx)
    end
  end

  @doc """
  Walks every registered plugin and drives the
  `resolve_external_sync_entries/2` chain, returning the final merged
  registry map.

  Accepts `:baseline` / `:ctx` — see `collect_action_handlers/1`.
  """
  @spec collect_external_sync_entries(keyword()) :: %{optional(String.t()) => map()}
  def collect_external_sync_entries(opts \\ []) do
    if opts == [] do
      case :persistent_term.get(@snapshot_key, nil) do
        %{external_sync_entries: entries} ->
          entries

        nil ->
          reduce_resolvers(:resolve_external_sync_entries, %{}, %{})
      end
    else
      baseline = Keyword.get(opts, :baseline, %{})
      ctx = Keyword.get(opts, :ctx, %{})
      reduce_resolvers(:resolve_external_sync_entries, baseline, ctx)
    end
  end

  @doc """
  Walks every registered plugin and drives the
  `resolve_top_menu_entries/2` chain. The final list is normalised
  (defaults `:order` to 100) and sorted by `{order, label}` so output is
  deterministic.

  Built-in host tabs use orders 10/20/30; plugin tabs default to 100 and
  sort to the right end unless overridden. The host (task s3) will pass
  its built-in baseline via `:baseline` so plugins can drop or reorder
  built-ins symmetric with how they treat sibling-plugin tabs.

  Accepts `:baseline` / `:ctx` — see `collect_action_handlers/1`.
  """
  @spec collect_top_menu_entries(keyword()) :: [Barkpark.Plugin.top_menu_entry()]
  def collect_top_menu_entries(opts \\ []) do
    if opts == [] do
      case :persistent_term.get(@snapshot_key, nil) do
        %{top_menu_entries: entries} ->
          entries

        nil ->
          compute_top_menu_entries([], %{})
      end
    else
      baseline = Keyword.get(opts, :baseline, [])
      ctx = Keyword.get(opts, :ctx, %{})
      compute_top_menu_entries(baseline, ctx)
    end
  end

  @doc """
  Walks every registered plugin and drives the `resolve_desk_items/2`
  chain, returning the flat concatenated list.

  For backwards compatibility this function accepts either a binary
  (legacy `collect_desk_items("production")` — folded into
  `ctx = %{dataset: dataset}`) or a keyword list (`:baseline` / `:ctx`).
  When called with a binary, `ctx.dataset` is set so the default
  resolver lift continues to pass it into the plugin's `desk_items/1`
  callback.

  Not cached — desk items vary per dataset and per ctx, and the cost is
  a handful of map lookups + list concatenation per plugin.
  """
  @spec collect_desk_items(String.t() | keyword()) :: [Barkpark.Plugin.desk_item()]
  def collect_desk_items(dataset_or_opts \\ "production")

  def collect_desk_items(dataset) when is_binary(dataset) do
    reduce_resolvers(:resolve_desk_items, [], %{dataset: dataset})
  end

  def collect_desk_items(opts) when is_list(opts) do
    baseline = Keyword.get(opts, :baseline, [])
    ctx = Keyword.get(opts, :ctx, %{})
    reduce_resolvers(:resolve_desk_items, baseline, ctx)
  end

  @doc """
  Walks every registered plugin and drives the `resolve_checkers/2`
  chain, returning the flat concatenated list of `{name, module}`
  checker pairs.

  Accepts `:baseline` / `:ctx` — see `collect_action_handlers/1`. Not
  cached: checkers vary per ctx and the host (task s3) will seed its
  built-ins via `:baseline`.
  """
  @spec collect_checkers(keyword()) :: [Barkpark.Plugin.checker()]
  def collect_checkers(opts \\ []) do
    baseline = Keyword.get(opts, :baseline, [])
    ctx = Keyword.get(opts, :ctx, %{})
    reduce_resolvers(:resolve_checkers, baseline, ctx)
  end

  @doc """
  Walks every registered plugin and drives the
  `resolve_codelist_seeders/2` chain, returning the flat concatenated
  list of zero-arg seeder functions.

  This is the chain-result LIST — to actually execute the seeders use
  `run_all_codelist_seeders/0` (which still iterates per-plugin with
  per-seeder error isolation).

  Accepts `:baseline` / `:ctx` — see `collect_action_handlers/1`.
  """
  @spec collect_codelist_seeders(keyword()) :: [(-> any())]
  def collect_codelist_seeders(opts \\ []) do
    baseline = Keyword.get(opts, :baseline, [])
    ctx = Keyword.get(opts, :ctx, %{})
    reduce_resolvers(:resolve_codelist_seeders, baseline, ctx)
  end

  @doc """
  Walks every registered plugin and drives the
  `resolve_settings_schema/2` chain, returning the flat concatenated
  list of declarative settings fields.

  Accepts `:baseline` / `:ctx` — see `collect_action_handlers/1`. The
  host (task s3) will pass `%{plugin_name: name}` in `:ctx` so plugins
  can produce per-plugin settings (the existing pattern in
  `plugin_settings_live.ex` reads `settings_schema/0` directly off one
  plugin module; this collector is the resolver-aware path for the
  future cross-plugin view).
  """
  @spec collect_settings_schema(keyword()) :: [Barkpark.Plugin.setting_field()]
  def collect_settings_schema(opts \\ []) do
    baseline = Keyword.get(opts, :baseline, [])
    ctx = Keyword.get(opts, :ctx, %{})
    reduce_resolvers(:resolve_settings_schema, baseline, ctx)
  end

  @doc """
  Drives the brand-new `resolve_doc_actions/2` chain. No additive
  predecessor — plugins implement `resolve_doc_actions/2` directly to
  filter, reorder, or amend per-doc actions.

  Accepts `:baseline` / `:ctx` — see `collect_action_handlers/1`. The
  host (task s4) will seed `:baseline` with the schema-declared
  `:actions` list and pass `ctx = %{dataset, doc_id, doc_type, doc}` so
  plugins can decide based on the live document payload (e.g.
  OnixEdit's "Publish to Bokbasen" disappearing mid-submission).
  """
  @spec collect_doc_actions(keyword()) :: [Barkpark.Plugin.doc_action()]
  def collect_doc_actions(opts \\ []) do
    baseline = Keyword.get(opts, :baseline, [])
    ctx = Keyword.get(opts, :ctx, %{})
    reduce_resolvers(:resolve_doc_actions, baseline, ctx)
  end

  @doc """
  Walks every registered plugin and drives the `resolve_api_tests/2`
  chain, returning the flat concatenated list of `api_test_spec()` maps
  the runner can fire on demand.

  Accepts `:baseline` / `:ctx` — see `collect_action_handlers/1`. Not
  cached: the API test runner is an admin-triggered tool, not a hot
  path, and the host (task s3 — runner wiring) seeds its own built-in
  smoke tests via `:baseline` so plugins can drop or reorder them
  symmetric with how they treat sibling-plugin specs.

  Plugins typically implement the additive `api_tests/0` form; the
  default `resolve_api_tests/2` supplied by `use Barkpark.Plugin` lifts
  the additive return via `prev ++ result`. Plugins wanting to filter
  or reorder sibling-plugin specs override `resolve_api_tests/2`
  directly.
  """
  @spec collect_api_tests(keyword()) :: [Barkpark.Plugin.api_test_spec()]
  def collect_api_tests(opts \\ []) do
    baseline = Keyword.get(opts, :baseline, [])
    ctx = Keyword.get(opts, :ctx, %{})
    reduce_resolvers(:resolve_api_tests, baseline, ctx)
  end

  @doc """
  First-wins resolver for the Studio preview pane (Goal barkpark-G1
  task s3). Walks every registered plugin in load order (Application
  config when set, otherwise alphabetical-by-name — same source of
  truth as the additive resolver chain), calls `content_renderer/3` on
  each, and returns the FIRST `{:ok, iodata}` it gets back. When every
  plugin returns `:skip` (or no plugin implements the callback) the
  function returns `:none` and the StudioLive caller hides the preview
  pane entirely.

  Three reasons this is a simple first-wins instead of an additive
  `reduce_resolvers/3` fold:

    1. Only one preview can render per doc-type at a time — the pane
       holds a single `<pre>`. Two plugins claiming `"book"` would
       fight over the surface.
    2. The host has no built-in baseline to seed (unlike top-menu /
       desk-items / doc-actions). With plugins=[] there is no preview.
    3. The returned iodata flows straight into the rendered pane — no
       merge / sort / dedup step would be meaningful.

  Defensive: a plugin whose `content_renderer/3` raises is treated as
  `:skip` and the chain continues. The host never crashes because a
  preview renderer exploded mid-edit.
  """
  @spec collect_content_renderer(String.t(), map(), map()) :: {:ok, iodata()} | :none
  def collect_content_renderer(doc_type, content, ctx \\ %{})
      when is_binary(doc_type) and is_map(content) and is_map(ctx) do
    load_ordered_plugins()
    |> Enum.find_value(:none, fn entry ->
      safe_content_renderer_call(entry.module, doc_type, content, ctx)
    end)
  end

  # Returns `{:ok, iodata}` when the plugin contributes one (Enum.find_value
  # treats any non-nil/non-false return as the hit), or `nil` to keep the
  # chain walking. All non-ok returns + every raise / throw collapse to nil.
  defp safe_content_renderer_call(module, doc_type, content, ctx) do
    cond do
      not Code.ensure_loaded?(module) ->
        nil

      function_exported?(module, :content_renderer, 3) ->
        try do
          case module.content_renderer(doc_type, content, ctx) do
            {:ok, iodata} -> {:ok, iodata}
            :skip -> nil
            _ -> nil
          end
        rescue
          e ->
            Logger.warning(
              "Barkpark.Plugins.Registry: #{inspect(module)}.content_renderer/3 raised — " <>
                Exception.message(e)
            )

            nil
        catch
          kind, reason ->
            Logger.warning(
              "Barkpark.Plugins.Registry: #{inspect(module)}.content_renderer/3 threw " <>
                "#{kind} #{inspect(reason)}"
            )

            nil
        end

      true ->
        nil
    end
  end

  @doc """
  First-wins resolver for `Barkpark.Plugin.test_connection/1` (Goal
  barkpark-G3, task s1). Looks up the plugin by name and calls its
  `test_connection/1` callback. Returns the plugin's result verbatim,
  `{:error, :plugin_not_found}` when no plugin matches the name, and
  `{:error, :not_implemented}` when the matched plugin did not override
  the default callback.

  Unlike `collect_content_renderer/3` this is NOT a chain walk — there
  is one plugin per settings page, identified by the `plugin_name`
  URL segment the admin LiveView already routes on. The host (the
  admin Plugin Settings LiveView) calls this with the live form's
  current `settings` map; the plugin sees the same shape its own
  settings reader (`Bokbasen.Settings.get_credentials/0` etc.) would
  produce.

  Defensive: a plugin whose `test_connection/1` raises is collapsed to
  `{:error, {:raised, message}}` so the host never crashes because a
  connection test exploded mid-form-submit.
  """
  @spec collect_test_connection(plugin_name :: String.t() | atom(), settings :: map()) ::
          Barkpark.Plugin.test_connection_result() | {:error, :plugin_not_found}
  def collect_test_connection(plugin_name, settings) when is_map(settings) do
    name = to_string(plugin_name)

    case lookup(name) do
      {:ok, %{module: module}} -> safe_test_connection(module, settings)
      :error -> {:error, :plugin_not_found}
    end
  end

  defp safe_test_connection(module, settings) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, :not_implemented}

      function_exported?(module, :test_connection, 1) ->
        try do
          module.test_connection(settings)
        rescue
          e ->
            Logger.warning(
              "Barkpark.Plugins.Registry: #{inspect(module)}.test_connection/1 raised — " <>
                Exception.message(e)
            )

            {:error, {:raised, Exception.message(e)}}
        catch
          kind, reason ->
            Logger.warning(
              "Barkpark.Plugins.Registry: #{inspect(module)}.test_connection/1 threw " <>
                "#{kind} #{inspect(reason)}"
            )

            {:error, {kind, inspect(reason)}}
        end

      true ->
        {:error, :not_implemented}
    end
  end

  @doc """
  Walks every registered plugin, calls `codelist_seeders/0` to get a
  list of zero-arg functions, and invokes each one in the configured
  `:plugins` load order (the same order `reduce_resolvers/3` and
  `collect_content_renderer/3` use). Falls back to alphabetical-by-name
  when no `:plugins` order is configured.

  Each seeder is wrapped in `try/rescue` so one failing plugin's seeder
  doesn't abort the rest. Failures log a warning. Returns `:ok` always.

  Not cached — seeders are run for side-effects at boot / admin reload,
  not on hot paths.
  """
  @spec run_all_codelist_seeders() :: :ok
  def run_all_codelist_seeders do
    load_ordered_plugins()
    |> Enum.each(&run_codelist_seeders_for_entry/1)

    :ok
  end

  @doc """
  Looks up a single plugin by name and runs its codelist seeders. Used by
  the plugin admin LV's per-plugin Reload button. Returns `:ok` when the
  plugin was found (per-seeder failures are logged, not raised, matching
  `run_all_codelist_seeders/0`); `{:error, :unknown_plugin}` when not
  registered.

  Records the result into `Barkpark.Plugins.RunStatus` under `:seed`.
  """
  @spec run_codelist_seeders_by_name(String.t()) :: :ok | {:error, :unknown_plugin}
  def run_codelist_seeders_by_name(plugin_name) when is_binary(plugin_name) do
    case lookup(plugin_name) do
      {:ok, entry} ->
        run_codelist_seeders_for_entry(entry)
        :ok

      :error ->
        {:error, :unknown_plugin}
    end
  end

  @doc """
  Notifies registered plugins after a blob upload lands in `media_files`.

  Plugins opt in by exporting `after_media_upload/1`. Failures are logged
  per-plugin; the upload itself is never rolled back.
  """
  @spec run_after_media_upload(map()) :: :ok
  def run_after_media_upload(ctx) when is_map(ctx) do
    load_ordered_plugins()
    |> Enum.each(fn %{module: module} ->
      if function_exported?(module, :after_media_upload, 1) do
        safe_call(module, :after_media_upload, [ctx], :ok)
      end
    end)

    :ok
  end

  @doc """
  Notifies registered plugins after a blob row is deleted from `media_files`.

  Plugins opt in by exporting `after_media_delete/1`.
  """
  @spec run_after_media_delete(map()) :: :ok
  def run_after_media_delete(ctx) when is_map(ctx) do
    load_ordered_plugins()
    |> Enum.each(fn %{module: module} ->
      if function_exported?(module, :after_media_delete, 1) do
        safe_call(module, :after_media_delete, [ctx], :ok)
      end
    end)

    :ok
  end

  @doc """
  Returns the `mediaAsset` document id linked to a blob, if any plugin
  exports `asset_doc_id_for_file/2`.
  """
  @spec asset_doc_id_for_media_file(String.t(), String.t()) :: String.t() | nil
  def asset_doc_id_for_media_file(media_file_id, dataset)
      when is_binary(media_file_id) and is_binary(dataset) do
    load_ordered_plugins()
    |> Enum.find_value(fn %{module: module} ->
      if function_exported?(module, :asset_doc_id_for_file, 2) do
        module.asset_doc_id_for_file(media_file_id, dataset)
      end
    end)
  end

  @doc """
  Iterate registered plugins; for each (plugin, resolver-callback) pair
  where the plugin exports BOTH the resolver and the additive form, log
  one `Logger.warning` line naming the plugin and callback. The resolver
  always wins — this warning exists to nudge plugin authors toward
  removing the dead additive code.

  Idempotent and cheap (read-only loop). Called from `init/1` after the
  first discovery sweep, and again on every `register/2` so a runtime
  addition gets flagged.
  """
  @spec warn_duplicate_forms() :: :ok
  def warn_duplicate_forms do
    for entry <- all() do
      mod = entry.module

      if Code.ensure_loaded?(mod) do
        for {resolver, {additive, additive_arity, _default, _lift}} <- @resolver_callbacks,
            is_atom(additive) and not is_nil(additive) and is_integer(additive_arity),
            function_exported?(mod, resolver, 2),
            function_exported?(mod, additive, additive_arity) do
          # Only flag when the plugin has OVERRIDDEN the resolver — the
          # `use Barkpark.Plugin` default exports `resolve_X/2` for every
          # plugin, so a bare `function_exported?` check would warn on every
          # plugin that uses the additive form. Compare bytecode equality
          # against the additive lift: if the resolver is the synthesised
          # default, skip the warning.
          unless resolver_is_default_lift?(mod, resolver, additive, additive_arity) do
            Logger.warning(
              "Barkpark.Plugins.Registry: plugin #{entry.name} defines both " <>
                "#{resolver}/2 and #{additive}/#{additive_arity} — preferring resolver"
            )
          end
        end
      end
    end

    :ok
  end

  defp run_codelist_seeders_for_entry(%{name: name, module: module}) do
    seeders = safe_call(module, :codelist_seeders, [], [])

    {ok_count, errors} =
      if is_list(seeders) do
        Enum.reduce(seeders, {0, []}, fn seeder, {ok_acc, err_acc} ->
          case invoke_seeder(seeder, name) do
            :ok -> {ok_acc + 1, err_acc}
            {:error, reason} -> {ok_acc, [reason | err_acc]}
          end
        end)
      else
        {0, []}
      end

    result =
      case errors do
        [] -> {:ok, ok_count}
        _ -> {:error, Enum.reverse(errors)}
      end

    Barkpark.Plugins.RunStatus.record(:seed, name, result)
    result
  end

  defp invoke_seeder(seeder, plugin_name) do
    try do
      cond do
        is_function(seeder, 0) ->
          seeder.()
          :ok

        true ->
          {:error, {:not_a_zero_arity_function, seeder}}
      end
    rescue
      e ->
        Logger.warning(
          "Barkpark.Plugins.Registry: codelist seeder #{inspect(seeder)} from plugin " <>
            "#{plugin_name} raised — #{Exception.message(e)}"
        )

        {:error, {:raised, Exception.message(e)}}
    catch
      kind, reason ->
        Logger.warning(
          "Barkpark.Plugins.Registry: codelist seeder #{inspect(seeder)} from plugin " <>
            "#{plugin_name} threw #{kind} #{inspect(reason)}"
        )

        {:error, {kind, inspect(reason)}}
    end
  end

  # ─── Resolver chain core ────────────────────────────────────────────────
  #
  # `reduce_resolvers/3` is the single internal driver every collector funnels
  # through. It picks plugins via the documented source-of-truth order, then
  # threads `prev` through each plugin's resolver call.

  @doc false
  @spec reduce_resolvers(atom(), term(), map()) :: term()
  def reduce_resolvers(callback_name, baseline, ctx) when is_atom(callback_name) do
    {additive, additive_arity, default, lift_kind} =
      Map.fetch!(@resolver_callbacks, callback_name)

    Enum.reduce(load_ordered_plugins(), baseline, fn entry, prev ->
      apply_resolver(entry, callback_name, additive, additive_arity, default, lift_kind, prev, ctx)
    end)
  end

  # Resolve the in-order list of registered plugin entries, source of truth
  # documented in the moduledoc. Application config wins when set; otherwise
  # fall back to alphabetical-by-name over the GenServer state (legacy).
  defp load_ordered_plugins do
    case Application.get_env(:barkpark, :plugins, []) do
      [] ->
        all() |> Enum.sort_by(& &1.name)

      configured when is_list(configured) ->
        configured
        |> Enum.map(&plugin_name_of/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.flat_map(fn name ->
          case lookup(name) do
            {:ok, entry} ->
              [entry]

            :error ->
              Logger.debug(
                "Barkpark.Plugins.Registry: plugin #{inspect(name)} listed in " <>
                  ":barkpark, :plugins but not registered — skipping"
              )

              []
          end
        end)
    end
  end

  # The Application config entry can be a bare module atom, a `{name, module}`
  # tuple, or a string plugin name. We only need the name to look up the
  # registered entry — module form gets reverse-mapped via `all/0`.
  defp plugin_name_of(name) when is_binary(name), do: name

  defp plugin_name_of({name, _module}) when is_binary(name), do: name

  defp plugin_name_of(module) when is_atom(module) do
    Enum.find_value(all(), fn entry ->
      if entry.module == module, do: entry.name
    end)
  end

  defp plugin_name_of(_), do: nil

  # Per-plugin resolver dispatch. Three paths:
  #
  #   1. Plugin overrode `resolve_X/2`  →  call it directly.
  #   2. Plugin only exports the additive form  →  call it and lift into the
  #      resolver shape (concat for lists, Map.merge for maps).
  #   3. Plugin exports neither  →  return prev unchanged.
  #
  # Path 1 covers `use Barkpark.Plugin` plugins (whose `__using__` ships a
  # default `resolve_X/2` that already does the additive lift internally) AND
  # plugins that explicitly override the resolver to mutate.
  #
  # Path 2 covers bare test fakes that define just `top_menu_entries/0`
  # without `use Barkpark.Plugin`. These never hit path 1 because the
  # `__using__` macro is the only thing that exports `resolve_X/2` by default.
  defp apply_resolver(
         entry,
         resolver,
         additive,
         additive_arity,
         default,
         lift_kind,
         prev,
         ctx
       ) do
    mod = entry.module

    cond do
      not Code.ensure_loaded?(mod) ->
        prev

      function_exported?(mod, resolver, 2) ->
        safe_resolver_call(mod, resolver, prev, ctx)

      is_atom(additive) and not is_nil(additive) and is_integer(additive_arity) and
          function_exported?(mod, additive, additive_arity) ->
        result =
          if additive_arity == 0 do
            safe_call(mod, additive, [], default)
          else
            # Only `desk_items/1` has arity 1 today; the arg is dataset.
            dataset = Map.get(ctx, :dataset, "production")
            safe_call(mod, additive, [dataset], default)
          end

        lift(prev, result, lift_kind)

      true ->
        prev
    end
  end

  defp safe_resolver_call(module, resolver, prev, ctx) do
    try do
      apply(module, resolver, [prev, ctx])
    rescue
      e ->
        Logger.warning(
          "Barkpark.Plugins.Registry: #{inspect(module)}.#{resolver}/2 raised — " <>
            Exception.message(e)
        )

        prev
    catch
      kind, reason ->
        Logger.warning(
          "Barkpark.Plugins.Registry: #{inspect(module)}.#{resolver}/2 threw " <>
            "#{kind} #{inspect(reason)}"
        )

        prev
    end
  end

  defp lift(prev, result, :list_concat) when is_list(prev) and is_list(result),
    do: prev ++ result

  defp lift(prev, result, :map_merge) when is_map(prev) and is_map(result),
    do: Map.merge(prev, result)

  # Defensive: a misbehaving additive return falls through to prev so a
  # malformed plugin can't corrupt the accumulator.
  defp lift(prev, _result, _lift_kind), do: prev

  # Check whether the plugin's `resolve_X/2` is the macro-injected default
  # lift supplied by `Barkpark.Plugin.__using__/1`. This is deliberately a
  # BEHAVIORAL fingerprint, not a static check: `__using__/1` injects a
  # default `resolve_X/2` for EVERY plugin, so `function_exported?` cannot
  # distinguish an author override from the injected default — they're both
  # exported functions. There is no AST at runtime to inspect either. The
  # only signal left is to RUN the callbacks and compare results: call the
  # additive form and the resolver with a known empty `prev` + ctx, then test
  # whether the resolver returned exactly `prev ++ additive_result` (lists) or
  # `Map.merge(prev, additive_result)` (maps). Equal → it's the default lift,
  # no warning. Different → the author overrode it, warn.
  #
  # This runs ONCE per plugin at registration (from `warn_duplicate_forms/0`),
  # not on any hot path. It relies on the additive callbacks being
  # side-effect-free pure data returns — which the plugin contract requires —
  # since invoking them here for the fingerprint must be safe to repeat.
  #
  # Avoids false positives on the wide ecosystem of plugins that legitimately
  # use only the additive form.
  defp resolver_is_default_lift?(module, resolver, additive, additive_arity) do
    {empty_prev, ctx} =
      case Map.fetch!(@resolver_callbacks, resolver) do
        {_, _, %{} = empty, :map_merge} -> {empty, %{dataset: "production"}}
        {_, _, [], _} -> {[], %{dataset: "production"}}
      end

    try do
      additive_result =
        if additive_arity == 0 do
          apply(module, additive, [])
        else
          apply(module, additive, ["production"])
        end

      resolver_result = apply(module, resolver, [empty_prev, ctx])

      cond do
        is_list(empty_prev) and is_list(additive_result) ->
          resolver_result == empty_prev ++ additive_result

        is_map(empty_prev) and is_map(additive_result) ->
          resolver_result == Map.merge(empty_prev, additive_result)

        true ->
          false
      end
    rescue
      _ -> false
    catch
      _, _ -> false
    end
  end

  # Invoke `module.function(args)` only when exported. Errors / non-export
  # fall back to the supplied default. Centralised so all three collectors
  # share the same defensive shape.
  defp safe_call(module, fun, args, default) do
    try do
      if Code.ensure_loaded?(module) and function_exported?(module, fun, length(args)) do
        apply(module, fun, args)
      else
        default
      end
    rescue
      e ->
        Logger.warning(
          "Barkpark.Plugins.Registry: #{inspect(module)}.#{fun}/#{length(args)} raised — " <>
            Exception.message(e)
        )

        default
    end
  end

  # Top-menu collection adds normalisation + sort on top of the bare chain
  # so plugin-supplied entries get a stable `:order` default and the final
  # output is sorted by `{order, label}` regardless of registration order.
  defp compute_top_menu_entries(baseline, ctx) do
    :resolve_top_menu_entries
    |> reduce_resolvers(baseline, ctx)
    |> Enum.map(&normalize_top_menu_entry/1)
    |> Enum.sort_by(fn e -> {e.order, e.label} end)
  end

  defp normalize_top_menu_entry(entry) when is_map(entry) do
    %{
      label: to_string(entry[:label] || entry["label"] || ""),
      path: to_string(entry[:path] || entry["path"] || "/"),
      icon: entry[:icon] || entry["icon"],
      order: entry[:order] || entry["order"] || 100,
      active_when: entry[:active_when] || entry["active_when"]
    }
  end

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
      action_handlers: reduce_resolvers(:resolve_action_handlers, %{}, %{}),
      external_sync_entries: reduce_resolvers(:resolve_external_sync_entries, %{}, %{}),
      top_menu_entries: compute_top_menu_entries([], %{})
    })

    state
  end

  @doc """
  Walks registered plugin modules and returns the union of their
  `register_workers/1` callback results.

  Pure function — does NOT require the Registry GenServer to be alive,
  because it is called from `Barkpark.Application.start/2` while the
  supervision tree is being constructed (the Registry process is itself
  a child of that tree, not yet started). Discovery happens via the
  same source-of-truth chain documented in the module doc, with one
  twist: when `:plugins` is unset the function performs a synchronous
  disk walk of `default_paths/0` so production boots fold OnixEdit's
  Bokbasen.Auth in even when no explicit config declares the plugin.

  Source-of-truth precedence (matches `load_ordered_plugins/0` at
  runtime, with the unset-vs-empty distinction added):

    * `Application.fetch_env(:barkpark, :plugins)` returns `{:ok, list}` —
      honour the list verbatim, mapping each entry to its module atom.
      An EXPLICIT empty list returns `[]` (this is the
      `plugin_free_boot_test.exs` contract).
    * `:error` (unset) — walk `default_paths/0` synchronously, the same
      filesystem chain that powers `discover_and_register/0`.

  Per-plugin error isolation: a plugin that fails to load, fails to
  export `register_workers/1`, or whose callback raises contributes
  nothing — the failure is logged at warning level and the boot
  continues. This mirrors how the post-boot `discover_and_register/0`
  isolates per-plugin failures.

  Returns a flat list of `Supervisor.child_spec()`-compatible terms.
  """
  @spec collect_workers(map()) :: [Supervisor.child_spec() | {module(), term()} | module()]
  def collect_workers(ctx \\ %{}) do
    ctx = Map.put_new(ctx, :phase, :boot)

    plugin_modules_sync()
    |> Enum.flat_map(fn module -> safe_register_workers(module, ctx) end)
  end

  defp plugin_modules_sync do
    case Application.fetch_env(:barkpark, :plugins) do
      {:ok, configured} when is_list(configured) ->
        configured
        |> Enum.map(&module_of_configured_entry/1)
        |> Enum.reject(&is_nil/1)

      _ ->
        # Unset → walk disk synchronously. Matches `discover_and_register/0`
        # but returns modules instead of registering them; the post-boot
        # discovery Task still runs and populates the live Registry for
        # runtime resolver-chain queries.
        default_paths()
        |> Enum.flat_map(&plugin_dirs_in/1)
        |> Enum.flat_map(&module_from_plugin_dir/1)
    end
  end

  defp module_of_configured_entry(module) when is_atom(module), do: module

  defp module_of_configured_entry({_name, module}) when is_atom(module), do: module

  defp module_of_configured_entry(name) when is_binary(name) do
    # Resolve a string plugin_name by reading the manifest off disk.
    default_paths()
    |> Enum.flat_map(&plugin_dirs_in/1)
    |> Enum.find_value(fn dir ->
      with {:ok, raw} <- File.read(Path.join(dir, "plugin.json")),
           {:ok, manifest} <- Jason.decode(raw),
           true <- manifest["plugin_name"] == name,
           {:ok, module} <- resolve_module(manifest) do
        module
      else
        _ -> nil
      end
    end)
  end

  defp module_of_configured_entry(_), do: nil

  defp module_from_plugin_dir(dir) do
    manifest_path = Path.join(dir, "plugin.json")

    with {:ok, raw} <- File.read(manifest_path),
         {:ok, manifest} <- Jason.decode(raw),
         {:ok, module} <- resolve_module(manifest) do
      [module]
    else
      reason ->
        Logger.warning(
          "Barkpark.Plugins.Registry.collect_workers/1: skipping #{inspect(dir)} — " <>
            inspect(reason)
        )

        []
    end
  end

  defp safe_register_workers(module, ctx) do
    try do
      if Code.ensure_loaded?(module) and function_exported?(module, :register_workers, 1) do
        case module.register_workers(ctx) do
          list when is_list(list) ->
            list

          other ->
            Logger.warning(
              "Barkpark.Plugins.Registry.collect_workers/1: #{inspect(module)}." <>
                "register_workers/1 returned non-list #{inspect(other)} — skipping"
            )

            []
        end
      else
        []
      end
    rescue
      e ->
        Logger.warning(
          "Barkpark.Plugins.Registry.collect_workers/1: #{inspect(module)}." <>
            "register_workers/1 raised — #{Exception.message(e)}"
        )

        []
    catch
      kind, reason ->
        Logger.warning(
          "Barkpark.Plugins.Registry.collect_workers/1: #{inspect(module)}." <>
            "register_workers/1 threw #{kind} #{inspect(reason)}"
        )

        []
    end
  end

  @doc """
  Walks registered plugin modules and returns the union of their
  `register_routes/1` callback results.

  Pure function — does NOT require the Registry GenServer to be alive,
  because it is called from the `plugin_routes/1` router macro at
  COMPILE TIME (Goal barkpark-G2 task s3). Discovery reuses the same
  synchronous `plugin_modules_sync/0` helper that powers
  `collect_workers/1`, so the unset-vs-empty `:plugins` distinction
  documented there applies here too: an explicit `[]` returns `[]`
  (matching the fresh-install invariant the G1 boot test locks), while
  `:unset` walks `default_paths/0` to fold bundled plugins in.

  Per-plugin error isolation: a plugin that fails to load, fails to
  export `register_routes/1`, returns a non-list, or whose callback
  raises contributes nothing — the failure is logged at warning level
  and the host router still compiles. Mirrors `safe_register_workers/2`.

  Returns a flat list of `Barkpark.Plugin.route_spec()` tagged tuples.
  """
  @spec collect_routes(map()) :: [Barkpark.Plugin.route_spec()]
  def collect_routes(ctx \\ %{}) do
    ctx = Map.put_new(ctx, :phase, :compile)

    plugin_modules_sync()
    |> Enum.flat_map(fn module -> safe_register_routes(module, ctx) end)
  end

  defp safe_register_routes(module, ctx) do
    try do
      # `collect_routes/1` runs at router COMPILE time. `Code.ensure_loaded?`
      # only succeeds when the plugin module's .beam already exists — which is
      # NOT guaranteed during a single `mix compile` pass: Elixir's per-file
      # compile order is dependency-driven, and nothing forces a plugin module
      # to compile before the router. `Code.ensure_compiled/1` instead asks the
      # compiler to (compile and) load the module, registering a compile-time
      # dependency so the plugin is built first. This is the difference between
      # plugin routes mounting deterministically vs only when the file-order
      # lottery happens to favour them.
      if module_available?(module) and function_exported?(module, :register_routes, 1) do
        case module.register_routes(ctx) do
          list when is_list(list) ->
            list

          other ->
            Logger.warning(
              "Barkpark.Plugins.Registry.collect_routes/1: #{inspect(module)}." <>
                "register_routes/1 returned non-list #{inspect(other)} — skipping"
            )

            []
        end
      else
        []
      end
    rescue
      e ->
        Logger.warning(
          "Barkpark.Plugins.Registry.collect_routes/1: #{inspect(module)}." <>
            "register_routes/1 raised — #{Exception.message(e)}"
        )

        []
    catch
      kind, reason ->
        Logger.warning(
          "Barkpark.Plugins.Registry.collect_routes/1: #{inspect(module)}." <>
            "register_routes/1 threw #{kind} #{inspect(reason)}"
        )

        []
    end
  end

  # True when `module` can be invoked. `Code.ensure_compiled/1` forces a
  # compile-time dependency on the plugin module when called from the router
  # macro (so it compiles before the router), and is a plain "is it loadable?"
  # check at runtime. Returns true for `{:module, _}` and also for
  # `{:error, :unavailable}` — the latter is what `ensure_compiled` returns for
  # a module mid-compile in the SAME pass that already depends on us; in that
  # case the module IS being built and `function_exported?` below confirms it.
  defp module_available?(module) do
    case Code.ensure_compiled(module) do
      {:module, _} -> true
      _ -> false
    end
  end

  @doc """
  Walks the default discovery roots and registers every plugin found.

  Safe to call once during boot; logs warnings (never raises) on per-plugin
  errors.

  ## `:plugins` env interaction (Goal barkpark-G5 task s2)

  The Application env `:barkpark, :plugins` is the kill switch — this
  zero-arg head MUST respect it so the fresh-install invariant locked by
  `plugin_free_boot_test.exs` holds end-to-end:

    * `:unset` (env absent) — disk discovery proceeds as before.
      Production default; fresh installs fold bundled plugins in.
    * `[]` (explicit empty list) — short-circuit: nothing is registered.
      This is the kill switch. `Application.put_env(:barkpark, :plugins, [])`
      followed by `Application.ensure_all_started(:barkpark)` boots a
      plugin-free Barkpark.
    * `[<plugin_name>, …]` (non-empty list) — whitelist mode: walk disk
      but only register plugins whose `plugin_name` matches an entry in
      the list. Module atoms and `{name, module}` tuples are accepted
      and normalised to their string `plugin_name` for the match.

  The explicit-paths arity (`discover_and_register/1`) is the unconditional
  variant used by tests with a fixture root — it does NOT consult the env.
  """
  @spec discover_and_register() :: :ok
  def discover_and_register do
    case Application.get_env(:barkpark, :plugins, :unset) do
      [] ->
        # Explicit empty list = kill switch. Load nothing.
        :ok

      :unset ->
        # No env set = discover from disk (production / fresh-install default).
        discover_and_register(default_paths())

      configured when is_list(configured) ->
        # Whitelist: walk disk but only register plugins on the list.
        # Build a name-only whitelist; module / `{name, module}` entries
        # are normalised to their plugin_name by reading the manifest off
        # disk so we never depend on the (not-yet-populated) GenServer
        # state during boot.
        whitelist = whitelist_names_from_config(configured)
        discover_and_register(default_paths(), whitelist)

      _other ->
        # Defensive: a non-list value (someone misconfigured) falls back
        # to disk discovery rather than silently swallowing.
        discover_and_register(default_paths())
    end
  end

  @doc """
  Walks the given list of root directories and registers every plugin found.

  Each root is scanned non-recursively for immediate subdirectories
  containing a `plugin.json`. Useful in tests with an explicit fixture
  root. Unlike the zero-arg head, this variant does NOT consult the
  `:plugins` env — callers that want the kill switch use `discover_and_register/0`.
  """
  @spec discover_and_register([Path.t()]) :: :ok
  def discover_and_register(paths) when is_list(paths) do
    paths
    |> Enum.flat_map(&plugin_dirs_in/1)
    |> Enum.each(&try_register_plugin_dir/1)

    :ok
  end

  # Whitelist-aware discovery: same disk walk as the public arity but only
  # registers plugins whose manifest `plugin_name` is in `whitelist`.
  defp discover_and_register(paths, %MapSet{} = whitelist) when is_list(paths) do
    paths
    |> Enum.flat_map(&plugin_dirs_in/1)
    |> Enum.each(&try_register_plugin_dir_in_whitelist(&1, whitelist))

    :ok
  end

  # Normalise the :plugins env to a MapSet of plugin_name strings.
  # Accepts binary names, `{name, module}` tuples, and bare module atoms.
  # Module atoms are reverse-mapped by reading every plugin.json on disk
  # — we cannot consult the live Registry here because this runs during
  # boot, before discovery has populated state.
  defp whitelist_names_from_config(configured) do
    name_set =
      configured
      |> Enum.flat_map(fn
        name when is_binary(name) -> [name]
        {name, _module} when is_binary(name) -> [name]
        module when is_atom(module) and not is_nil(module) -> manifest_names_for_module(module)
        _ -> []
      end)
      |> MapSet.new()

    name_set
  end

  defp manifest_names_for_module(module) do
    default_paths()
    |> Enum.flat_map(&plugin_dirs_in/1)
    |> Enum.flat_map(fn dir ->
      with {:ok, raw} <- File.read(Path.join(dir, "plugin.json")),
           {:ok, manifest} <- Jason.decode(raw),
           {:ok, ^module} <- resolve_module(manifest),
           name when is_binary(name) and name != "" <- manifest["plugin_name"] do
        [name]
      else
        _ -> []
      end
    end)
  end

  defp try_register_plugin_dir_in_whitelist(dir, whitelist) do
    manifest_path = Path.join(dir, "plugin.json")

    with {:ok, raw} <- File.read(manifest_path),
         {:ok, manifest} <- Jason.decode(raw),
         name when is_binary(name) and name != "" <- manifest["plugin_name"],
         true <- MapSet.member?(whitelist, name) || :not_whitelisted,
         {:ok, module} <- resolve_module(manifest),
         true <- Code.ensure_loaded?(module) || {:module_not_loaded, module} do
      register(module, manifest)
    else
      :not_whitelisted ->
        Logger.debug(
          "Barkpark.Plugins.Registry: skipping #{inspect(dir)} — not in :plugins whitelist"
        )

        :error

      reason ->
        Logger.warning("Barkpark.Plugins.Registry: skipping #{inspect(dir)} — #{inspect(reason)}")

        :error
    end
  end

  # ─── Discovery internals ────────────────────────────────────────────────

  defp default_paths do
    bundled = Application.app_dir(:barkpark, "priv/plugins")

    deps =
      if Code.ensure_loaded?(Mix.Project) and function_exported?(Mix.Project, :deps_path, 0) do
        try do
          [Mix.Project.deps_path()]
        rescue
          _ -> []
        end
      else
        []
      end

    [bundled | deps]
  end

  defp plugin_dirs_in(root) do
    case File.ls(root) do
      {:ok, entries} ->
        for entry <- entries,
            dir = Path.join(root, entry),
            File.dir?(dir),
            File.exists?(Path.join(dir, "plugin.json")),
            do: dir

      _ ->
        []
    end
  end

  defp try_register_plugin_dir(dir) do
    manifest_path = Path.join(dir, "plugin.json")

    with {:ok, raw} <- File.read(manifest_path),
         {:ok, manifest} <- Jason.decode(raw),
         {:ok, module} <- resolve_module(manifest),
         true <- Code.ensure_loaded?(module) || {:module_not_loaded, module} do
      register(module, manifest)
    else
      reason ->
        Logger.warning("Barkpark.Plugins.Registry: skipping #{inspect(dir)} — #{inspect(reason)}")

        :error
    end
  end

  @doc """
  Resolves the Elixir module a manifest maps to.

  Prefers an explicit `"module"` key; otherwise derives
  `Barkpark.Plugins.<Pascal>` from `"plugin_name"` (per-segment
  `Macro.camelize`). Returns `{:ok, module}` or `{:error, :no_plugin_name}`.

  Public so the plugin generator's test can assert that the manifest it
  emits resolves to the module its generated `lib/` file defines — the
  exact discovery match that was previously broken.
  """
  @spec resolve_module(map()) :: {:ok, module()} | {:error, :no_plugin_name}
  def resolve_module(%{"module" => mod}) when is_binary(mod) and mod != "" do
    {:ok, Module.concat([mod])}
  end

  def resolve_module(%{"plugin_name" => name}) when is_binary(name) and name != "" do
    pascal =
      name
      |> String.split(~r/[_\-\s]+/, trim: true)
      |> Enum.map_join("", &Macro.camelize/1)

    {:ok, Module.concat([Barkpark, Plugins, pascal])}
  end

  def resolve_module(_), do: {:error, :no_plugin_name}

  # ─── GenServer ──────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    {:ok, %{plugins: %{}}}
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
        _ = warn_duplicate_forms()
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
end
