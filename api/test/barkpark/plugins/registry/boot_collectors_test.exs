defmodule Barkpark.Plugins.Registry.BootCollectorsTest do
  @moduledoc """
  Direct unit tests for `Barkpark.Plugins.Registry.BootCollectors`.

  All three public functions are pure and driven via the `:barkpark, :plugins`
  Application env — no GenServer, no disk walk needed. Each test sets the env
  to a concrete list of inline fake modules, exercises the collector, then
  restores the prior env on exit.

  `async: false` is required because `Application.put_env/3` is a global
  side-channel — concurrent modifications across async tests would race.
  """

  # Application env is a global side-channel — must be synchronous.
  use ExUnit.Case, async: false

  alias Barkpark.Plugins.Registry.BootCollectors

  # ─── Shared env-restore setup ───────────────────────────────────────────

  # The two ctx-capturing fake plugins at the bottom of this file record the ctx
  # they received in a `:persistent_term`. That store is global AND UNOWNED —
  # nothing tears it down between modules — and each test `erase`s its key
  # BEFORE reading it, which protects that test and protects nobody else.
  @capture_keys [{__MODULE__, :collected_ctx}, {__MODULE__, :route_ctx}]

  setup do
    prev = Application.get_env(:barkpark, :plugins, :unset)
    prior_terms = Enum.map(@capture_keys, &{&1, :persistent_term.get(&1, :__absent__)})

    on_exit(fn ->
      case prev do
        :unset -> Application.delete_env(:barkpark, :plugins)
        v -> Application.put_env(:barkpark, :plugins, v)
      end

      # Erase when there was no prior term, so an absent key stays absent.
      Enum.each(prior_terms, fn
        {key, :__absent__} -> :persistent_term.erase(key)
        {key, value} -> :persistent_term.put(key, value)
      end)
    end)

    :ok
  end

  # ─── collect_workers/1 ──────────────────────────────────────────────────

  describe "collect_workers/1" do
    test "returns [] when :plugins is explicitly empty (kill-switch)" do
      Application.put_env(:barkpark, :plugins, [])
      assert BootCollectors.collect_workers(%{}) == []
    end

    test "returns workers from a plugin that exports register_workers/1" do
      Application.put_env(:barkpark, :plugins, [
        Barkpark.Plugins.Registry.BootCollectorsTest.WorkerFakeA
      ])

      workers = BootCollectors.collect_workers(%{})
      assert is_list(workers)
      assert {Barkpark.Plugins.Registry.BootCollectorsTest.FakeWorker, []} in workers
    end

    test "injects default :boot phase into ctx when not supplied" do
      Application.put_env(:barkpark, :plugins, [
        Barkpark.Plugins.Registry.BootCollectorsTest.CtxCapturingPlugin
      ])

      # The plugin records the ctx it received in a persistent_term.
      key = {__MODULE__, :collected_ctx}
      :persistent_term.erase(key)

      _workers = BootCollectors.collect_workers(%{})

      ctx = :persistent_term.get(key, nil)
      assert ctx != nil
      assert ctx[:phase] == :boot
    end

    test "isolates a plugin whose register_workers/1 raises — others still contribute" do
      Application.put_env(:barkpark, :plugins, [
        Barkpark.Plugins.Registry.BootCollectorsTest.WorkerFakeA,
        Barkpark.Plugins.Registry.BootCollectorsTest.RaisingWorkerPlugin
      ])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          workers = BootCollectors.collect_workers(%{})
          # WorkerFakeA still contributes despite the raising sibling.
          assert {Barkpark.Plugins.Registry.BootCollectorsTest.FakeWorker, []} in workers
        end)

      assert log =~ "register_workers/1 raised"
    end

    test "tolerates a plugin that does not export register_workers/1" do
      Application.put_env(:barkpark, :plugins, [
        Barkpark.Plugins.Registry.BootCollectorsTest.NoCallbackPlugin
      ])

      assert BootCollectors.collect_workers(%{}) == []
    end
  end

  # ─── collect_oban_crontab/0 ─────────────────────────────────────────────

  describe "collect_oban_crontab/0" do
    test "returns [] when :plugins is explicitly empty" do
      Application.put_env(:barkpark, :plugins, [])
      assert BootCollectors.collect_oban_crontab() == []
    end

    test "returns crontab entries from a plugin that exports oban_crontab/0" do
      Application.put_env(:barkpark, :plugins, [
        Barkpark.Plugins.Registry.BootCollectorsTest.CronFake
      ])

      crontab = BootCollectors.collect_oban_crontab()
      assert is_list(crontab)

      assert {"0 2 * * *", Barkpark.Plugins.Registry.BootCollectorsTest.FakeCronWorker} in crontab
    end

    test "isolates a raising plugin, leaving siblings intact" do
      Application.put_env(:barkpark, :plugins, [
        Barkpark.Plugins.Registry.BootCollectorsTest.CronFake,
        Barkpark.Plugins.Registry.BootCollectorsTest.RaisingCronPlugin
      ])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          crontab = BootCollectors.collect_oban_crontab()

          assert {"0 2 * * *", Barkpark.Plugins.Registry.BootCollectorsTest.FakeCronWorker} in crontab
          # The raising plugin contributes nothing.
          assert length(crontab) == 1
        end)

      assert log =~ "oban_crontab/0 raised"
    end
  end

  # ─── collect_routes/1 ───────────────────────────────────────────────────

  describe "collect_routes/1" do
    test "returns [] when :plugins is explicitly empty" do
      Application.put_env(:barkpark, :plugins, [])
      assert BootCollectors.collect_routes(%{}) == []
    end

    test "returns routes from a plugin that exports register_routes/1" do
      Application.put_env(:barkpark, :plugins, [
        Barkpark.Plugins.Registry.BootCollectorsTest.RouteFake
      ])

      routes = BootCollectors.collect_routes(%{})
      assert is_list(routes)

      assert {:get, "/fake/route", Barkpark.Plugins.Registry.BootCollectorsTest.FakeController,
              :index} in routes
    end

    test "injects default :compile phase into ctx when not supplied" do
      Application.put_env(:barkpark, :plugins, [
        Barkpark.Plugins.Registry.BootCollectorsTest.RouteCtxCapturingPlugin
      ])

      key = {__MODULE__, :route_ctx}
      :persistent_term.erase(key)

      _routes = BootCollectors.collect_routes(%{})

      ctx = :persistent_term.get(key, nil)
      assert ctx != nil
      assert ctx[:phase] == :compile
    end
  end
end

# ── Inline fake plugin modules ────────────────────────────────────────────
# Deliberately do NOT `use Barkpark.Plugin` — the collectors only care that
# the right callbacks are exported and return the right shape.

defmodule Barkpark.Plugins.Registry.BootCollectorsTest.FakeWorker do
  @moduledoc false
end

defmodule Barkpark.Plugins.Registry.BootCollectorsTest.WorkerFakeA do
  @moduledoc false
  def register_workers(_ctx) do
    [{Barkpark.Plugins.Registry.BootCollectorsTest.FakeWorker, []}]
  end
end

defmodule Barkpark.Plugins.Registry.BootCollectorsTest.CtxCapturingPlugin do
  @moduledoc false
  def register_workers(ctx) do
    :persistent_term.put({Barkpark.Plugins.Registry.BootCollectorsTest, :collected_ctx}, ctx)
    []
  end
end

defmodule Barkpark.Plugins.Registry.BootCollectorsTest.RaisingWorkerPlugin do
  @moduledoc false
  def register_workers(_ctx), do: raise("boom from RaisingWorkerPlugin")
end

defmodule Barkpark.Plugins.Registry.BootCollectorsTest.NoCallbackPlugin do
  @moduledoc false
  # Intentionally exports nothing relevant.
  def some_unrelated_function, do: :ok
end

defmodule Barkpark.Plugins.Registry.BootCollectorsTest.FakeCronWorker do
  @moduledoc false
end

defmodule Barkpark.Plugins.Registry.BootCollectorsTest.CronFake do
  @moduledoc false
  def oban_crontab do
    [{"0 2 * * *", Barkpark.Plugins.Registry.BootCollectorsTest.FakeCronWorker}]
  end
end

defmodule Barkpark.Plugins.Registry.BootCollectorsTest.RaisingCronPlugin do
  @moduledoc false
  def oban_crontab, do: raise("boom from RaisingCronPlugin")
end

defmodule Barkpark.Plugins.Registry.BootCollectorsTest.FakeController do
  @moduledoc false
end

defmodule Barkpark.Plugins.Registry.BootCollectorsTest.RouteFake do
  @moduledoc false
  def register_routes(_ctx) do
    [{:get, "/fake/route", Barkpark.Plugins.Registry.BootCollectorsTest.FakeController, :index}]
  end
end

defmodule Barkpark.Plugins.Registry.BootCollectorsTest.RouteCtxCapturingPlugin do
  @moduledoc false
  def register_routes(ctx) do
    :persistent_term.put({Barkpark.Plugins.Registry.BootCollectorsTest, :route_ctx}, ctx)
    []
  end
end
