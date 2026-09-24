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

  ## Every load-order SETTER goes through `put!/1`

  Every reader of the load order (`Plugins.Hooks`, `Registry.ResolverChain`,
  `Registry.BootCollectors`, `Registry.Discovery`, `Content.PreWriteFences`)
  accepts exactly three entry shapes — a module atom, a `{plugin_name, module}`
  tuple, a plugin-name string — and DROPS anything else without a word. A
  test that sets the order to something else runs with that plugin silently
  OFF and passes vacuously for the plugin half:
  `stamp_publish_lost_update_test.exs` passed the Registry's ENTRY MAPS
  (`Registry.all()`), so the Tasks plugin was out of its load order all along
  (task-05ea4e4c31dbc750).

  `put!/1` (and `with_plugins/2`, `run_with/2`, which call it) refuses such an
  entry with an `ArgumentError` naming it, instead of letting it through to a
  reader that drops it. `test/barkpark/plugins/plugin_order_setter_guard_test.exs`
  scans `api/test` and reds on any `Application.put_env(:barkpark, :plugins, _)`
  outside this module, so a setter cannot route around the check. Restores go
  through `restore/1`, which puts a `capture/0` snapshot back verbatim.
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
    put!(modules)
    ExUnit.Callbacks.on_exit({__MODULE__, ctx}, fn -> restore(prior) end)
    :ok
  end

  @doc """
  Set the `:plugins` load order to `order`, refusing any entry no reader
  accepts (see "Every load-order SETTER goes through `put!/1`"). The caller
  owns the restore: pair it with `capture/0` + `restore/1`, or use
  `with_plugins/2` / `run_with/2`, which register one.
  """
  def put!(order) do
    validate!(order)
    Application.put_env(:barkpark, :plugins, order)
    :ok
  end

  @doc """
  Run `fun` with the load order set to `order`, restoring the prior value
  (absence included) afterwards even when `fun` raises. Returns `fun`'s result.
  """
  def run_with(order, fun) when is_function(fun, 0) do
    prior = capture()
    put!(order)

    try do
      fun.()
    after
      restore(prior)
    end
  end

  @doc """
  Raise `ArgumentError` unless every entry of `order` is a shape the load-order
  readers accept: a LOADED module atom, a `{plugin_name, module}` tuple, or a
  non-empty plugin-name string.

  A string is not resolved here: an unregistered name is skipped by the
  readers by design, and `pre_write_fences_test.exs` exercises exactly that
  skip. A module atom IS checked for loadability — a misspelt module is as
  silently dropped as a map.
  """
  def validate!(order) when is_list(order) do
    order
    |> Enum.with_index()
    |> Enum.each(fn {entry, index} ->
      unless valid_entry?(entry), do: refuse!(entry, index, order)
    end)
  end

  def validate!(order) do
    raise ArgumentError,
          "the :barkpark, :plugins load order must be a list, got: #{inspect(order)}"
  end

  defp valid_entry?(name) when is_binary(name), do: name != ""

  defp valid_entry?({name, module}) when is_binary(name) and is_atom(module),
    do: name != "" and loaded_module?(module)

  defp valid_entry?(module) when is_atom(module), do: loaded_module?(module)
  defp valid_entry?(_), do: false

  defp loaded_module?(nil), do: false
  defp loaded_module?(module), do: Code.ensure_loaded?(module)

  defp refuse!(entry, index, order) do
    hint =
      case entry do
        %{module: module} ->
          " It looks like a Plugins.Registry ENTRY MAP; pass its module " <>
            "(#{inspect(module)}) — e.g. `Enum.map(Registry.all(), & &1.module)`."

        atom when is_atom(atom) and not is_nil(atom) ->
          " #{inspect(atom)} is not a loadable module."

        _ ->
          ""
      end

    raise ArgumentError,
          "refusing :barkpark, :plugins load-order entry #{index} " <>
            "(#{inspect(entry, limit: 5)}): every load-order reader DROPS an " <>
            "entry that is not a module atom, a {plugin_name, module} tuple, or " <>
            "a plugin-name string, so this plugin would be silently OFF for the " <>
            "test." <> hint <> " Full order: #{inspect(order, limit: 8)}"
  end
end
