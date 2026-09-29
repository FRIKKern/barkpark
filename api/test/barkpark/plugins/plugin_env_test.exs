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
      Barkpark.PluginEnv.put!([])

      assert PluginEnv.capture() == []
    end

    test "returns a load-order list verbatim" do
      restore_true_baseline_last()
      Barkpark.PluginEnv.put!([DummyPlugin])

      assert PluginEnv.capture() == [DummyPlugin]
    end
  end

  describe "restore/1 — the round trip" do
    test "an unset-baseline round trip leaves the key ABSENT, not []" do
      restore_true_baseline_last()
      Application.delete_env(:barkpark, :plugins)

      prior = PluginEnv.capture()
      Barkpark.PluginEnv.put!([DummyPlugin])
      assert Application.fetch_env(:barkpark, :plugins) == {:ok, [DummyPlugin]}

      PluginEnv.restore(prior)

      assert Application.fetch_env(:barkpark, :plugins) == :error,
             "restore/1 on an unset baseline must delete_env the key. Leaving " <>
               "{:ok, []} here is the plugin-discovery kill switch leaking into " <>
               "every test that runs later in this VM."
    end

    test "an explicit-[] baseline round trip restores the [] (does NOT delete it)" do
      restore_true_baseline_last()
      Barkpark.PluginEnv.put!([])

      prior = PluginEnv.capture()
      Barkpark.PluginEnv.put!([DummyPlugin])
      PluginEnv.restore(prior)

      assert Application.fetch_env(:barkpark, :plugins) == {:ok, []},
             "a test that deliberately set the kill switch must get it back"
    end

    test "a load-order baseline round trip restores the list" do
      restore_true_baseline_last()
      Barkpark.PluginEnv.put!([DummyPlugin])

      prior = PluginEnv.capture()
      Barkpark.PluginEnv.put!([])
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
      # exactly as with_async_target/1 used to.
      # on-exit-ref-gate: allow-bare-ref — the bare ref IS the subject of this
      # test; rewriting it to a module-scoped ref would delete the regression.
      ExUnit.Callbacks.on_exit(ctx, fn -> :ok end)
    end

    test "a set baseline is restored verbatim after the callback chain drains", ctx do
      restore_true_baseline_last()
      Barkpark.PluginEnv.put!(["baseline-name"])

      on_exit(fn ->
        assert Application.fetch_env(:barkpark, :plugins) == {:ok, ["baseline-name"]}
      end)

      assert :ok = PluginEnv.with_plugins([DummyPlugin], ctx)
      assert Application.get_env(:barkpark, :plugins) == [DummyPlugin]
    end
  end

  describe "put!/1 — a non-plugin entry is refused, not silently dropped" do
    # The shape that hid the Tasks plugin in stamp_publish_lost_update_test.exs:
    # the Registry's ENTRY MAPS passed as the load order. Every reader drops a
    # map, so the plugin was OFF and nothing said so.
    test "a Registry entry map raises, names the entry, and says what to pass" do
      restore_true_baseline_last()
      Application.delete_env(:barkpark, :plugins)
      entry = %{module: DummyPlugin, name: "dummy", manifest: %{}}

      error = assert_raise ArgumentError, fn -> PluginEnv.put!([entry]) end

      assert error.message =~ "load-order entry 0"
      assert error.message =~ "silently OFF"
      assert error.message =~ "ENTRY MAP"
      assert error.message =~ inspect(DummyPlugin)

      assert Application.fetch_env(:barkpark, :plugins) == :error,
             "a refused order must not reach the env"
    end

    test "with_plugins/2 and run_with/2 refuse the same way" do
      restore_true_baseline_last()

      assert_raise ArgumentError, ~r/entry 1/, fn ->
        PluginEnv.with_plugins([DummyPlugin, %{module: DummyPlugin}], %{test: :with})
      end

      assert_raise ArgumentError, fn -> PluginEnv.run_with([nil], fn -> :ran end) end
    end

    test "nil, an unloadable atom, an empty name, a bad tuple, and a non-list are refused" do
      for bad <- [
            [nil],
            [Barkpark.Plugins.NoSuchPluginModule],
            [""],
            [{:tasks, DummyPlugin}],
            [1]
          ] do
        assert_raise ArgumentError, fn -> PluginEnv.validate!(bad) end
      end

      assert_raise ArgumentError, ~r/must be a list/, fn -> PluginEnv.validate!(:all) end
    end

    test "every shape a reader accepts passes: module, {name, module}, name, and []" do
      assert :ok = PluginEnv.validate!([DummyPlugin, {"dummy", DummyPlugin}, "media"])
      assert :ok = PluginEnv.validate!([])
    end

    test "run_with/2 restores the prior value even when the body raises" do
      restore_true_baseline_last()
      Application.delete_env(:barkpark, :plugins)

      assert_raise RuntimeError, fn ->
        PluginEnv.run_with([DummyPlugin], fn -> raise "boom" end)
      end

      assert Application.fetch_env(:barkpark, :plugins) == :error

      assert PluginEnv.run_with([DummyPlugin], fn -> Application.get_env(:barkpark, :plugins) end) ==
               [DummyPlugin]
    end
  end
end
