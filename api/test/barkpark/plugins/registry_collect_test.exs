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
  use ExUnit.Case, async: false

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
  end
end
