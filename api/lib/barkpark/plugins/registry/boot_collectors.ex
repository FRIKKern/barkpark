defmodule Barkpark.Plugins.Registry.BootCollectors do
  @moduledoc """
  Boot-/compile-time plugin collectors for `Barkpark.Plugins.Registry`:
  workers, Oban crontab, and routes.

  Extracted (Goal modularity-registry) as a behavior-preserving facade split.
  Every function here is PURE — it does NOT require the Registry GenServer to
  be alive, because these run at boot (workers/crontab, before Oban + before
  the Registry process) or at router COMPILE time (routes). Discovery reuses
  `Barkpark.Plugins.Registry.Discovery`'s disk walk, so the unset-vs-empty
  `:plugins` distinction is identical. Module location only, NO logic change.
  """

  require Logger

  alias Barkpark.Plugins.Registry.Discovery

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

  @doc """
  Walks every plugin module and returns the flat union of their
  `oban_crontab/0` callback results — the Oban Cron entries each plugin
  contributes. The host (`Barkpark.Application.start/2`) appends this list
  to the `Oban.Plugins.Cron` `:crontab` before starting Oban.

  Pure function — does NOT require the Registry GenServer to be alive,
  because it runs at boot BEFORE Oban (and the Registry GenServer is
  itself a sibling child). Discovery reuses the same synchronous
  `plugin_modules_sync/0` helper that powers `collect_workers/1`, so the
  unset-vs-empty `:plugins` distinction is identical.

  Per-plugin error isolation: a plugin that fails to load, doesn't export
  `oban_crontab/0`, or whose callback raises contributes nothing — the
  failure is logged at warning level and boot continues. This mirrors
  `collect_workers/1` exactly.

  Returns a flat list of Oban crontab elements: `{cron_expr, worker}` or
  `{cron_expr, worker, opts}`.
  """
  @spec collect_oban_crontab() :: [
          {String.t(), module()} | {String.t(), module(), keyword()}
        ]
  def collect_oban_crontab do
    plugin_modules_sync()
    |> Enum.flat_map(&safe_oban_crontab/1)
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

  # ─── Synchronous plugin-module discovery ────────────────────────────────

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
        Discovery.default_paths()
        |> Enum.flat_map(&Discovery.plugin_dirs_in/1)
        |> Enum.flat_map(&module_from_plugin_dir/1)
    end
  end

  defp module_of_configured_entry(module) when is_atom(module), do: module

  defp module_of_configured_entry({_name, module}) when is_atom(module), do: module

  defp module_of_configured_entry(name) when is_binary(name) do
    # Resolve a string plugin_name by reading the manifest off disk.
    Discovery.default_paths()
    |> Enum.flat_map(&Discovery.plugin_dirs_in/1)
    |> Enum.find_value(fn dir ->
      with {:ok, raw} <- File.read(Path.join(dir, "plugin.json")),
           {:ok, manifest} <- Jason.decode(raw),
           true <- manifest["plugin_name"] == name,
           {:ok, module} <- Discovery.resolve_module(manifest) do
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
         {:ok, module} <- Discovery.resolve_module(manifest) do
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

  # ─── Per-callback safe invocations ──────────────────────────────────────

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

  defp safe_oban_crontab(module) do
    try do
      if Code.ensure_loaded?(module) and function_exported?(module, :oban_crontab, 0) do
        case module.oban_crontab() do
          list when is_list(list) ->
            list

          other ->
            Logger.warning(
              "Barkpark.Plugins.Registry.collect_oban_crontab/0: #{inspect(module)}." <>
                "oban_crontab/0 returned non-list #{inspect(other)} — skipping"
            )

            []
        end
      else
        []
      end
    rescue
      e ->
        Logger.warning(
          "Barkpark.Plugins.Registry.collect_oban_crontab/0: #{inspect(module)}." <>
            "oban_crontab/0 raised — #{Exception.message(e)}"
        )

        []
    catch
      kind, reason ->
        Logger.warning(
          "Barkpark.Plugins.Registry.collect_oban_crontab/0: #{inspect(module)}." <>
            "oban_crontab/0 threw #{kind} #{inspect(reason)}"
        )

        []
    end
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
end
