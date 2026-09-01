defmodule Barkpark.PluginEnvTest do
  @moduledoc """
  Durable guard on `Barkpark.PluginEnv` — the save/restore pair every test that
  sets a `:plugins` load order now routes through.

  ## The failure this pins closed

  `BootCollectors.plugin_modules_sync/0` branches on
  `Application.fetch_env(:barkpark, :plugins)`: `:error` (UNSET — the boot
  baseline, since no config file declares the key) walks `priv/plugins/` from
  disk, while `{:ok, []}` is a discovery **kill switch**. So the difference
  between "absent" and "`[]`" is the difference between "all plugins" and "no
  plugins", and a save/restore helper that snapshots with

      Application.get_env(:barkpark, :plugins, [])   # WRONG default

  restores the `[]` its own default invented — arming the kill switch for every
  later test in the same VM. That is exactly the leak that reds
  `BarkparkWeb.PluginRoutesTest`'s "every auth: bucket declared by a registered
  plugin route is an accepted scope" (`assert declared != []` → "no plugin
  contributed any route — this completeness check would pass on an empty set,
  proving nothing"): an order-dependent red on a file with no defect in it.

  ## Fail-before

  Restore `capture/0`'s default to `[]` (and `restore/1` to a bare `put_env`)
  and every test below goes RED with `{:ok, []} != :error` — the key present
  and empty where the baseline had it absent. Verified by reverting the helper
  and re-running this file.

  `async: false`: these tests mutate the process-global `:plugins` env.
  """
  use ExUnit.Case, async: false

  alias Barkpark.PluginEnv

  defmodule DummyPlugin do
    @moduledoc false
  end

  # Put the true baseline back no matter what a test leaves behind. Registered
  # FIRST in each test so ExUnit's LIFO on_exit runs it LAST — after the
  # helper's own restore and after the assertions below observe that restore.
  defp restore_true_baseline_last do
    true_prior = PluginEnv.capture()
    on_exit(fn -> PluginEnv.restore(true_prior) end)
  end

  describe "capture/0 — unset is not []" do
    test "returns the :unset sentinel when the key is absent, NOT []" do
      restore_true_baseline_last()
      Application.delete_env(:barkpark, :plugins)

      assert PluginEnv.capture() == :unset,
             "capture/0 must distinguish an absent :plugins key from an explicit " <>
               "[] — [] is BootCollectors' discovery kill switch, absent is 'walk disk'"
    end

    test "returns an explicit [] verbatim (it is a real, meaningful value)" do
      restore_true_baseline_last()
      Application.put_env(:barkpark, :plugins, [])

      assert PluginEnv.capture() == []
    end

    test "returns a load-order list verbatim" do
      restore_true_baseline_last()
      Application.put_env(:barkpark, :plugins, [DummyPlugin])

      assert PluginEnv.capture() == [DummyPlugin]
    end
  end

  describe "restore/1 — the round trip" do
    test "an unset-baseline round trip leaves the key ABSENT, not []" do
      restore_true_baseline_last()
      Application.delete_env(:barkpark, :plugins)

      prior = PluginEnv.capture()
      Application.put_env(:barkpark, :plugins, [DummyPlugin])
      assert Application.fetch_env(:barkpark, :plugins) == {:ok, [DummyPlugin]}

      PluginEnv.restore(prior)

      assert Application.fetch_env(:barkpark, :plugins) == :error,
             "restore/1 on an unset baseline must delete_env the key. Leaving " <>
               "{:ok, []} here is the plugin-discovery kill switch leaking into " <>
               "every test that runs later in this VM."
    end

    test "an explicit-[] baseline round trip restores the [] (does NOT delete it)" do
      restore_true_baseline_last()
      Application.put_env(:barkpark, :plugins, [])

      prior = PluginEnv.capture()
      Application.put_env(:barkpark, :plugins, [DummyPlugin])
      PluginEnv.restore(prior)

      assert Application.fetch_env(:barkpark, :plugins) == {:ok, []},
             "a test that deliberately set the kill switch must get it back"
    end

    test "a load-order baseline round trip restores the list" do
      restore_true_baseline_last()
      Application.put_env(:barkpark, :plugins, [DummyPlugin])

      prior = PluginEnv.capture()
      Application.put_env(:barkpark, :plugins, [])
      PluginEnv.restore(prior)

      assert Application.fetch_env(:barkpark, :plugins) == {:ok, [DummyPlugin]}
    end
  end

  describe "with_plugins/2 — the on_exit actually fires the correct restore" do
    # END-TO-END, not just the pure functions: the assertion runs INSIDE an
    # on_exit registered BEFORE `with_plugins/2`, so LIFO puts it after the
    # helper's own restore callback. An assertion that raises in on_exit is
    # reported as a test failure, so this cannot pass vacuously.
    test "an unset baseline is left ABSENT after the callback chain drains", ctx do
      restore_true_baseline_last()
      Application.delete_env(:barkpark, :plugins)

      on_exit(fn ->
        assert Application.fetch_env(:barkpark, :plugins) == :error,
               "with_plugins/2's on_exit left the :plugins key present on an " <>
                 "unset baseline — that is the leak PluginRoutesTest dies on"
      end)

      assert :ok = PluginEnv.with_plugins([DummyPlugin], ctx)
      assert Application.get_env(:barkpark, :plugins) == [DummyPlugin]
    end

    test "a SIBLING ctx-keyed on_exit does not delete the plugins restore", ctx do
      # `on_exit/2`'s first argument is a KEY: a second registration with the
      # same ref REPLACES the first. Test files routinely have several helpers
      # that each take the test context and pass it straight to `on_exit/2`, so
      # a helper keying on the raw `ctx` gets silently unregistered by the next
      # one. hooks_test.exs did exactly this — `with_async_target(ctx)` after
      # `with_plugins(mods, ctx)` — and the file ended its run leaving
      # `:plugins` = `[PluginSlowAfter]`, a one-module load order that starves
      # `collect_routes/1` just as the `[]` kill switch does.
      restore_true_baseline_last()
      Application.delete_env(:barkpark, :plugins)

      on_exit(fn ->
        assert Application.fetch_env(:barkpark, :plugins) == :error,
               "a sibling ctx-keyed on_exit replaced with_plugins/2's restore"
      end)

      assert :ok = PluginEnv.with_plugins([DummyPlugin], ctx)

      # The sibling: a helper that keys its own cleanup on the bare context,
      # exactly as with_async_target/1 does.
      ExUnit.Callbacks.on_exit(ctx, fn -> :ok end)
    end

    test "a set baseline is restored verbatim after the callback chain drains", ctx do
      restore_true_baseline_last()
      Application.put_env(:barkpark, :plugins, [:baseline_name])

      on_exit(fn ->
        assert Application.fetch_env(:barkpark, :plugins) == {:ok, [:baseline_name]}
      end)

      assert :ok = PluginEnv.with_plugins([DummyPlugin], ctx)
      assert Application.get_env(:barkpark, :plugins) == [DummyPlugin]
    end
  end
end
