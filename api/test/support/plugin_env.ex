defmodule Barkpark.PluginEnv do
  @moduledoc """
  Save/restore for the process-global `:barkpark, :plugins` Application env,
  with the ONE distinction that matters: **unset is not `[]`**.

  ## Why a helper exists at all

  `Barkpark.Plugins.Registry.BootCollectors.plugin_modules_sync/0` branches on
  `Application.fetch_env(:barkpark, :plugins)`:

    * `{:ok, list}` — use exactly that load-order list. An explicit `[]` is
      therefore a discovery **kill switch**: zero plugins, no disk walk.
    * `:error` (UNSET) — walk `priv/plugins/` from disk. This is the boot
      baseline; `config/*.exs` declares no `:plugins` key.

  The naive save/restore pair

      prior = Application.get_env(:barkpark, :plugins, [])   # WRONG default
      Application.put_env(:barkpark, :plugins, mine)
      on_exit(fn -> Application.put_env(:barkpark, :plugins, prior) end)

  looks symmetric and is not: on the unset baseline `prior` is the `[]` the
  *default* invented, so "restore" **arms the kill switch** for every test that
  runs later in the same VM. The proven victim is
  `BarkparkWeb.PluginRoutesTest`'s "every auth: bucket declared by a registered
  plugin route is an accepted scope" — a bare `use ExUnit.Case, async: false`
  module with no self-reset, whose own vacuity guard (`assert declared != []`)
  is what reds: *"no plugin contributed any route — this completeness check
  would pass on an empty set, proving nothing"*. Nothing in that file is
  broken; a leaker three files earlier disabled plugin discovery.

  `capture/0` uses an `:unset` sentinel instead of a value default, so
  `restore/1` can `delete_env` the key back to genuinely-absent — the same
  shape `plugin_free_boot_test.exs` and `Barkpark.RegistryCase` already use.

  ## Use

      # in a test body / a setup that receives the context
      :ok = Barkpark.PluginEnv.with_plugins([SomePlugin], ctx)

      # in a bare `setup do` block (no context binding)
      prior = Barkpark.PluginEnv.capture()
      Application.put_env(:barkpark, :plugins, [SomePlugin])
      on_exit(fn -> Barkpark.PluginEnv.restore(prior) end)

  `test/barkpark/plugins/plugin_env_test.exs` pins the round trip: an
  unset-baseline capture/restore must leave `fetch_env` == `:error`.
  """

  @sentinel :unset

  @doc """
  Snapshot the current `:plugins` env. Returns `:unset` when the key is absent
  — NEVER `[]`, which is a meaningful value (the discovery kill switch).
  """
  def capture, do: Application.get_env(:barkpark, :plugins, @sentinel)

  @doc """
  Put a `capture/0` snapshot back. An `:unset` snapshot restores absence via
  `delete_env/2`; anything else is `put_env/3` verbatim.
  """
  def restore(@sentinel), do: Application.delete_env(:barkpark, :plugins)
  def restore(prior), do: Application.put_env(:barkpark, :plugins, prior)

  @doc """
  Set the `:plugins` load-order list for the duration of one test and register
  the correct restore on the given ExUnit context.

  ## The ref is NAMESPACED, and that is load-bearing

  `ExUnit.Callbacks.on_exit/2` treats its first argument as a KEY: registering
  twice with the same ref REPLACES the earlier callback. The callers this
  replaced passed the raw context `ctx`, which every other ctx-keyed helper in
  the same test file also passes — so in a test that called both
  `with_plugins(mods, ctx)` and a sibling `with_something(ctx)`, the sibling
  silently DELETED the plugins restore and the load-order list survived the
  test. `hooks_test.exs` hit exactly that: its last `with_plugins` test also
  calls `with_async_target(ctx)`, and the file ended a run leaving
  `:plugins` = `[PluginSlowAfter]` — a one-module load order, which makes
  `collect_routes/1` return `[]` just as surely as the `[]` kill switch does.

  Keying on `{__MODULE__, ctx}` keeps the intended dedup (a second
  `with_plugins/2` in the SAME test still replaces the first, so no stale
  snapshot stacks up) while colliding with nothing else.
  """
  def with_plugins(modules, ctx) when is_list(modules) do
    prior = capture()
    Application.put_env(:barkpark, :plugins, modules)
    ExUnit.Callbacks.on_exit({__MODULE__, ctx}, fn -> restore(prior) end)
    :ok
  end
end
