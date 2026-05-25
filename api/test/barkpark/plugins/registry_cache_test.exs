defmodule Barkpark.Plugins.RegistryCacheTest do
  @moduledoc """
  Covers the `:persistent_term`-backed read cache for
  `Barkpark.Plugins.Registry`. The shape of the contract:

    * `all/0`, `collect_action_handlers/0`, and `collect_external_sync_entries/0`
      short-circuit through `:persistent_term` when warm.
    * `register/2` is the only mutation path; it bumps the snapshot.
    * No `clear/0` API exists — once warm, the cache stays warm.

  We can't easily assert "did/didn't hit the GenServer" without
  instrumenting it, so we verify via observable behaviour:

    * After a register, the snapshot key is present and contains the new plugin.
    * Manually corrupting the snapshot causes subsequent reads to return the
      corrupted value — proving reads go through the cache (not the GenServer).
    * Re-registering after a corrupt write refreshes the snapshot back to truth.

  The Registry is a single named GenServer in the supervision tree, so
  tests share state — keep this synchronous and use unique plugin names.
  """

  use Barkpark.RegistryCase, async: false

  alias Barkpark.Plugins.Registry

  @snapshot_key {Registry, :snapshot}

  # ─── Fake plugin modules ────────────────────────────────────────────────

  defmodule CacheActionPlugin do
    def action_handlers do
      %{
        "cache_action" => fn _doc_id, _dataset, _mode -> {:ok, :cache_hit} end
      }
    end
  end

  defmodule CacheSyncPlugin do
    def external_sync_entries do
      %{
        "cache_sync" => %{label: "CacheSync"}
      }
    end
  end

  # ─── Tests ──────────────────────────────────────────────────────────────

  describe "snapshot population" do
    test "register/2 writes the snapshot under the expected key" do
      name = "cache-pop-#{System.unique_integer([:positive])}"
      :ok = Registry.register(:cache_pop_module, %{"plugin_name" => name})

      snapshot = :persistent_term.get(@snapshot_key, nil)

      assert is_map(snapshot)
      assert Map.has_key?(snapshot, :plugins)
      assert Map.has_key?(snapshot, :action_handlers)
      assert Map.has_key?(snapshot, :external_sync_entries)

      assert Enum.any?(snapshot.plugins, &(&1.name == name))
    end

    test "snapshot pre-computes action_handlers" do
      name = "cache-action-#{System.unique_integer([:positive])}"
      :ok = Registry.register(CacheActionPlugin, %{"plugin_name" => name})

      %{action_handlers: handlers} = :persistent_term.get(@snapshot_key)

      assert is_function(handlers["cache_action"], 3)
    end

    test "snapshot pre-computes external_sync_entries" do
      name = "cache-sync-#{System.unique_integer([:positive])}"
      :ok = Registry.register(CacheSyncPlugin, %{"plugin_name" => name})

      %{external_sync_entries: entries} = :persistent_term.get(@snapshot_key)

      assert %{"cache_sync" => %{label: "CacheSync"}} = entries
    end
  end

  describe "reads short-circuit through the cache" do
    test "all/0 returns the cached snapshot when warm" do
      # Prime the cache, then poison the snapshot with a synthetic marker
      # plugin. If `all/0` goes through the GenServer it'll miss our
      # marker; if it reads from `:persistent_term` it'll see it.
      name = "cache-prime-#{System.unique_integer([:positive])}"
      :ok = Registry.register(:cache_prime_module, %{"plugin_name" => name})

      poison_name = "cache-poison-#{System.unique_integer([:positive])}"
      poison_entry = %{name: poison_name, module: :poison_only, manifest: %{"x" => 1}}

      original = :persistent_term.get(@snapshot_key)
      poisoned = %{original | plugins: [poison_entry | original.plugins]}
      :persistent_term.put(@snapshot_key, poisoned)

      try do
        result = Registry.all()
        assert Enum.any?(result, &(&1.name == poison_name)),
               "all/0 should have read the poisoned cache, but didn't"
      after
        # Don't leak the poison into sibling tests — restore the truth.
        :persistent_term.put(@snapshot_key, original)
      end
    end

    test "collect_action_handlers/0 returns the cached map when warm" do
      name = "cache-ah-prime-#{System.unique_integer([:positive])}"
      :ok = Registry.register(:cache_ah_prime, %{"plugin_name" => name})

      original = :persistent_term.get(@snapshot_key)
      poisoned = %{original | action_handlers: %{"poisoned" => :sentinel}}
      :persistent_term.put(@snapshot_key, poisoned)

      try do
        assert %{"poisoned" => :sentinel} = Registry.collect_action_handlers()
      after
        :persistent_term.put(@snapshot_key, original)
      end
    end

    test "collect_external_sync_entries/0 returns the cached map when warm" do
      name = "cache-es-prime-#{System.unique_integer([:positive])}"
      :ok = Registry.register(:cache_es_prime, %{"plugin_name" => name})

      original = :persistent_term.get(@snapshot_key)
      poisoned = %{original | external_sync_entries: %{"poisoned" => :sentinel}}
      :persistent_term.put(@snapshot_key, poisoned)

      try do
        assert %{"poisoned" => :sentinel} = Registry.collect_external_sync_entries()
      after
        :persistent_term.put(@snapshot_key, original)
      end
    end
  end

  describe "register/2 invalidates the cache" do
    test "registering a new plugin refreshes the snapshot to ground truth" do
      # Prime, then poison, then register — the new register must wipe
      # the poison and write a snapshot derived from the real state.
      :ok = Registry.register(:cache_inv_seed, %{"plugin_name" => "cache-inv-seed"})

      original = :persistent_term.get(@snapshot_key)
      poisoned = %{original | action_handlers: %{"poisoned" => :sentinel}}
      :persistent_term.put(@snapshot_key, poisoned)

      new_name = "cache-inv-fresh-#{System.unique_integer([:positive])}"
      :ok = Registry.register(CacheActionPlugin, %{"plugin_name" => new_name})

      handlers = Registry.collect_action_handlers()
      refute Map.has_key?(handlers, "poisoned"),
             "register/2 should have wiped the poisoned key"

      assert is_function(handlers["cache_action"], 3),
             "register/2 should have included the freshly registered plugin"
    end

    test "registering reflects in all/0 even after a prior cache poison" do
      :ok = Registry.register(:cache_inv_all_seed, %{"plugin_name" => "cache-inv-all-seed"})

      original = :persistent_term.get(@snapshot_key)
      # Wipe the plugin list in the snapshot — a `register/2` must restore it.
      :persistent_term.put(@snapshot_key, %{original | plugins: []})

      fresh = "cache-inv-all-#{System.unique_integer([:positive])}"
      :ok = Registry.register(:cache_inv_all_module, %{"plugin_name" => fresh})

      names = Registry.all() |> Enum.map(& &1.name)
      assert fresh in names
      # The original seed must also be back — proving we re-derived from
      # GenServer state, not just appended to the wiped cache.
      assert "cache-inv-all-seed" in names
    end
  end
end
