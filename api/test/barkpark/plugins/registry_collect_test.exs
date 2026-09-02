defmodule Barkpark.Plugins.RegistryCollectTest do
  @moduledoc """
  Covers the three runtime collectors added to `Barkpark.Plugins.Registry`
  in task barkpark-auo:

    * `collect_action_handlers/0`
    * `collect_external_sync_entries/0`
    * `run_all_codelist_seeders/0`

  Each test registers a fake plugin module against the live (boot-time)
  Registry GenServer, exercises the collector, then leaves the entry in
  place — the Registry has no removal API. We give every fake plugin a
  unique name so tests don't collide with each other or with bundled
  plugins.
  """

  # The Registry is a single named GenServer in the supervision tree,
  # so tests share state — keep this synchronous.
  #
  # DataCase (first, async: false) gives this module an Ecto sandbox owner in
  # SHARED mode. `run_all_codelist_seeders/0` runs the real Media/EDItEUR seeders
  # in spawned processes; without a shared owner that spawned DB work raises
  # `cannot find ownership process` and orphans/crashes the shared pool, which
  # under the full parallel suite cascades into unrelated tests' setup. Shared
  # mode lets every spawned seeder process use this test's connection. Mirrors
  # SheetsValidationTest's DataCase + RegistryCase composition.
  use Barkpark.DataCase, async: false
  use Barkpark.RegistryCase, async: false

  alias Barkpark.Plugins.Registry

  # ─── Fake plugin modules ────────────────────────────────────────────────

  defmodule FakeActionPlugin do
    def action_handlers do
      %{
        "fake_action_collect" => fn _doc_id, _dataset, _mode -> {:ok, :fake_did_it} end
      }
    end
  end

  defmodule FakeExternalSyncPlugin do
    def external_sync_entries do
      %{
        "fake_sync_collect" => %{
          label: "FakeSync",
          states: %{
            "pending" => %{color: "gray", label: "Pending"},
            nil => %{color: "gray", label: "Not synced"}
          }
        }
      }
    end
  end

  defmodule FakeCodelistPlugin do
    # Stash a counter in :persistent_term so the test can assert the
    # seeder actually ran without coupling to the Registry's GenServer
    # state.
    def codelist_seeders do
      [
        fn -> :persistent_term.put({__MODULE__, :seeded}, true) end
      ]
    end
  end

  defmodule FakeRaisingCodelistPlugin do
    def codelist_seeders do
      [
        fn -> raise "boom from #{__MODULE__}" end,
        # The second seeder must still run even after the first raised.
        fn -> :persistent_term.put({__MODULE__, :seeded_after_boom}, true) end
      ]
    end
  end

  defmodule FakeRaisingHandlersPlugin do
    def action_handlers, do: raise("boom from FakeRaisingHandlersPlugin")
    def external_sync_entries, do: raise("boom from FakeRaisingHandlersPlugin")
  end

  # Two ordering probes: each appends its own name to a shared
  # :persistent_term list so the test can read back the invocation order.
  defmodule FakeOrderPluginA do
    def codelist_seeders do
      [fn -> append_order(:a) end]
    end

    def append_order(tag) do
      key = {Barkpark.Plugins.RegistryCollectTest, :seed_order}
      :persistent_term.put(key, :persistent_term.get(key, []) ++ [tag])
    end
  end

  defmodule FakeOrderPluginB do
    def codelist_seeders do
      [fn -> FakeOrderPluginA.append_order(:b) end]
    end
  end

  # ─── Capture-term restore ───────────────────────────────────────────────
  #
  # The fake plugins above stash their "I ran" flags and the seeder-ordering
  # probe in `:persistent_term`, which is global AND UNOWNED — nothing tears it
  # down between modules, and `RegistryCase` restores only its own snapshot key.
  # Each test `erase`s its key BEFORE reading it, which protects that test and
  # protects nobody else: the term outlives the module. Capture the prior value
  # and put it back — erasing when there was none, so an absent key stays absent.

  setup do
    keys = [
      {FakeCodelistPlugin, :seeded},
      {FakeRaisingCodelistPlugin, :seeded_after_boom},
      {__MODULE__, :seed_order}
    ]

    prior = Enum.map(keys, &{&1, :persistent_term.get(&1, :__absent__)})

    on_exit(fn ->
      Enum.each(prior, fn
        {key, :__absent__} -> :persistent_term.erase(key)
        {key, value} -> :persistent_term.put(key, value)
      end)
    end)

    :ok
  end

  # ─── collect_action_handlers/0 ──────────────────────────────────────────

  describe "collect_action_handlers/0" do
    test "merges action_handlers from a registered plugin" do
      name = "fake-action-#{System.unique_integer([:positive])}"

      :ok =
        Registry.register(FakeActionPlugin, %{"plugin_name" => name})

      handlers = Registry.collect_action_handlers()

      assert is_function(handlers["fake_action_collect"], 3)
      assert handlers["fake_action_collect"].("x", "production", :dryrun) == {:ok, :fake_did_it}
    end

    test "tolerates plugins whose callback raises" do
      name = "fake-action-raise-#{System.unique_integer([:positive])}"
      :ok = Registry.register(FakeRaisingHandlersPlugin, %{"plugin_name" => name})

      # Must not raise — safe_call catches and substitutes the default %{}.
      assert is_map(Registry.collect_action_handlers())
    end

    test "tolerates plugins that don't implement the callback" do
      name = "fake-noop-#{System.unique_integer([:positive])}"
      :ok = Registry.register(__MODULE__, %{"plugin_name" => name})

      assert is_map(Registry.collect_action_handlers())
    end
  end

  # ─── collect_external_sync_entries/0 ────────────────────────────────────

  describe "collect_external_sync_entries/0" do
    test "merges external_sync_entries from a registered plugin" do
      name = "fake-sync-#{System.unique_integer([:positive])}"
      :ok = Registry.register(FakeExternalSyncPlugin, %{"plugin_name" => name})

      entries = Registry.collect_external_sync_entries()

      assert %{"fake_sync_collect" => %{label: "FakeSync", states: states}} = entries
      assert states["pending"] == %{color: "gray", label: "Pending"}
      assert states[nil] == %{color: "gray", label: "Not synced"}
    end

    test "is exposed through Barkpark.ExternalSync.all/0" do
      name = "fake-sync-via-all-#{System.unique_integer([:positive])}"
      :ok = Registry.register(FakeExternalSyncPlugin, %{"plugin_name" => name})

      assert %{"fake_sync_collect" => %{label: "FakeSync"}} = Barkpark.ExternalSync.all()
      assert %{label: "FakeSync"} = Barkpark.ExternalSync.get("fake_sync_collect")
    end
  end

  # ─── run_all_codelist_seeders/0 ─────────────────────────────────────────

  describe "run_all_codelist_seeders/0" do
    test "invokes each plugin's zero-arg seeder functions" do
      :persistent_term.erase({FakeCodelistPlugin, :seeded})

      name = "fake-cl-#{System.unique_integer([:positive])}"
      :ok = Registry.register(FakeCodelistPlugin, %{"plugin_name" => name})

      assert :ok = Registry.run_all_codelist_seeders()
      assert :persistent_term.get({FakeCodelistPlugin, :seeded}, false) == true
    end

    test "a raising seeder doesn't abort sibling seeders" do
      :persistent_term.erase({FakeRaisingCodelistPlugin, :seeded_after_boom})

      name = "fake-cl-raise-#{System.unique_integer([:positive])}"
      :ok = Registry.register(FakeRaisingCodelistPlugin, %{"plugin_name" => name})

      assert :ok = Registry.run_all_codelist_seeders()

      assert :persistent_term.get(
               {FakeRaisingCodelistPlugin, :seeded_after_boom},
               false
             ) == true
    end

    test "seeds in the configured :plugins order, not alphabetical" do
      order_key = {__MODULE__, :seed_order}
      :persistent_term.erase(order_key)

      salt = System.unique_integer([:positive])
      # Names chosen so alphabetical order (a-… before b-…) is the REVERSE
      # of the configured order, proving config wins over Enum.sort_by/2.
      name_a = "zz-order-a-#{salt}"
      name_b = "aa-order-b-#{salt}"

      :ok = Registry.register(FakeOrderPluginA, %{"plugin_name" => name_a})
      :ok = Registry.register(FakeOrderPluginB, %{"plugin_name" => name_b})

      # `capture/0` (an `:unset` sentinel), not `get_env(…, [])`: a `[]`
      # default would restore an EXPLICIT `[]` — the discovery kill switch.
      prior = Barkpark.PluginEnv.capture()
      # Configured order: A (zz-…) THEN B (aa-…) — opposite of alphabetical.
      Application.put_env(:barkpark, :plugins, [name_a, name_b])
      on_exit(fn -> Barkpark.PluginEnv.restore(prior) end)

      assert :ok = Registry.run_all_codelist_seeders()

      observed = :persistent_term.get(order_key, [])
      a_idx = Enum.find_index(observed, &(&1 == :a))
      b_idx = Enum.find_index(observed, &(&1 == :b))

      assert is_integer(a_idx) and is_integer(b_idx)

      assert a_idx < b_idx,
             "expected configured order (A before B); got: #{inspect(observed)}"
    end
  end
end
