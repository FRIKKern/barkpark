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

  CAVEAT — that distinction exists in the function but the COMPILE-time
  caller never sees it: `:barkpark, :plugins` is set only in
  `config/runtime.exs`, which has not run at macro-expansion, so
  `collect_routes/1` always takes the `:unset` disk-walk branch. See the
  block above `plugin_modules_sync/0` for the per-caller branch table and
  for how the kill switch is enforced for routes instead (PR #14725,
  `BarkparkWeb.Plugs.PluginRouteGuard`).
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

  Pure function — does NOT require the Registry GenServer to be alive.
  It has TWO callers on different clocks: the `plugin_routes/1` router
  macro at COMPILE TIME (Goal barkpark-G2 task s3), and — since PR
  #14725 — `BarkparkWeb.Plugs.PluginRouteGuard` at REQUEST time.

  Discovery reuses the same synchronous `plugin_modules_sync/0` helper
  that powers `collect_workers/1`, but the two callers do NOT reach the
  same branch of it, and this block used to claim they did: "an explicit
  `[]` returns `[]` (matching the fresh-install invariant the G1 boot
  test locks), while `:unset` walks `default_paths/0`". Every clause of
  that was true of this FUNCTION and the conclusion was still false for
  the ROUTER. `:barkpark, :plugins` is written in exactly one place —
  `config/runtime.exs`, which evaluates at BOOT, i.e. after compilation
  — so at router macro-expansion `Application.fetch_env(:barkpark,
  :plugins)` is `:error` (UNSET), never `{:ok, []}`, and the disk-walk
  branch ALWAYS runs. The explicit-`[]` branch is UNREACHABLE from the
  router path: no value of `BARKPARK_PLUGINS` can keep a plugin route
  from being MOUNTED. Read `plugin_modules_sync/0`'s own block below for
  the per-caller branch table, for where the kill switch does bite, and
  for what the fresh-install boot test actually locks.

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

  # WHICH BRANCH EACH CALLER REACHES (corrected by PR #14725's follow-up)
  #
  # Two branches below, and the callers do not share them:
  #
  #   caller                          when it runs                 branch
  #   ------------------------------  ---------------------------  ------------------
  #   collect_workers/1               boot, AFTER runtime.exs      {:ok, list} if the
  #   collect_oban_crontab/0          boot, AFTER runtime.exs      env var is set —
  #                                                                an explicit [] is
  #                                                                honoured verbatim
  #   collect_routes/1, called by     router MACRO-EXPANSION,      ALWAYS :error —
  #   BarkparkWeb.Router.Plugins.     i.e. `mix compile`,          the disk walk, every
  #   plugin_routes/1                 BEFORE runtime.exs           build, no exceptions
  #   collect_routes/1, called by     REQUEST time, after          {:ok, list} if set
  #   BarkparkWeb.Plugs.              runtime.exs
  #   PluginRouteGuard
  #
  # `:barkpark, :plugins` is written in exactly ONE place: config/runtime.exs
  # (BARKPARK_PLUGINS unset -> leave unconfigured = discover-all-from-disk;
  # "" -> `[]` = the kill switch; "a,b" -> explicit whitelist). config.exs,
  # dev.exs, test.exs and prod.exs do not set it. Near miss to not be fooled
  # by: config/config.exs does carry a `plugins:` key, but it belongs to
  # `config :barkpark, Oban` — a different key, not this one.
  #
  # WHAT THE KILL SWITCH CAN AND CANNOT DO
  #
  # BARKPARK_PLUGINS="" stops plugin workers and plugin Oban crontab entries
  # from registering (both collectors above run after runtime.exs), and since
  # PR #14725 it makes plugin ROUTES answer 404. It does NOT unmount them — a
  # compile-time-mounted route cannot be unmounted at runtime. Instead every
  # route the macro emits is stamped with its spec key and wrapped in a scope
  # piping through BarkparkWeb.Plugs.PluginRouteGuard, which re-reads
  # collect_routes/1 at REQUEST time (where the switch is finally visible) and
  # 404s any route whose plugin is not in the enabled set. The routes stay
  # mounted; they stop answering. Before #14725 the switch could not touch
  # routes at all: with it fully engaged, a build still carried 41
  # /v1/plugins/* routes and POST /v1/plugins/pulse/:channel/events took an
  # unauthenticated, persisted write. So never read "an explicit [] returns []"
  # as "the router emits nothing" — that inference is how the P0 survived
  # review.
  #
  # THE FRESH-INSTALL INVARIANT, AND WHAT ACTUALLY LOCKS IT
  #
  # test/barkpark/plugin_free_boot_test.exs (Goal barkpark-G1) is the
  # invariant's regression bar, and it is narrower than its name suggests: it
  # `put_env`s :plugins [] and RESTARTS the app — it never recompiles the
  # router — so it locks the post-boot picture only. Its assertions are: no
  # plugin children in the supervision tree; GET /studio/production renders
  # with none of the plugin tokens; /api/schemas returns exactly the public
  # seed set; core-mounted /v1/graph/* still answers under the switch. It
  # asserts NOTHING about plugin routes being absent from Phoenix.Router, so
  # a green run of it is not evidence that routes are gated.
  #
  # The empty-list branch of THIS function is locked instead by
  # test/barkpark/plugins/registry/boot_collectors_test.exs ("returns [] when
  # :plugins is explicitly empty", one per collector) and by
  # test/barkpark_web/plugin_routes_test.exs ("collect_routes/1 returns []
  # under plugins=[]"). Both call this function at RUNTIME with the env
  # already `put_env`d; neither says anything about what compile time sees.
  defp plugin_modules_sync do
    case Application.fetch_env(:barkpark, :plugins) do
      {:ok, configured} when is_list(configured) ->
        # Entries are interpreted by `Barkpark.Content.PluginLoadOrder.modules/3`
        # (task-3fbd48182b1d35ea) against the manifests on disk (the Registry
        # does not exist yet at boot): a MODULE-dispatch reader, so a loadable
        # module that is not a plugin still contributes (the RoutesFake* /
        # crontab fakes rely on it), and every skipped entry — an unknown name,
        # an unloadable module, a malformed entry — is logged by name.
        Barkpark.Content.PluginLoadOrder.modules(
          configured,
          &Discovery.manifest_index/0,
          Barkpark.Plugins.Registry.BootCollectors
        )

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

  # `File.read/1` reads `plugin.json` under `dir`, which the caller obtained from
  # `Discovery.plugin_dirs_in/1` — a boot-time disk enumeration, not user input.
  # Inline rather than a line-pinned `.sobelow-skips` row (fingerprints shift).
  # sobelow_skip ["Traversal.FileModule"]
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
