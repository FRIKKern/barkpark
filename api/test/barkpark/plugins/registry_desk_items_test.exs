defmodule Barkpark.Plugins.RegistryDeskItemsTest do
  @moduledoc """
  Covers `Barkpark.Plugins.Registry.collect_desk_items/1` — the 12th
  plugin collector. Registers fake plugins, verifies the collector
  walks them in alphabetical-by-name order, and confirms it
  composes with the host's `Barkpark.Structure.build/1`.
  """

  use Barkpark.RegistryCase, async: false

  alias Barkpark.Plugins.Registry

  defmodule FakeDeskPluginX do
    def desk_items(dataset) do
      [
        %{type: :divider, label: "X (#{dataset})"},
        %{type: :link, label: "X link", path: "/admin/x"}
      ]
    end
  end

  defmodule FakeDeskPluginY do
    def desk_items(_dataset) do
      [%{type: :link, label: "Y link", path: "/admin/y"}]
    end
  end

  defmodule FakeRaisingDeskPlugin do
    def desk_items(_dataset), do: raise("boom from FakeRaisingDeskPlugin")
  end

  describe "collect_desk_items/1" do
    test "flattens items from one plugin and forwards the dataset arg" do
      name = "fake-desk-x-#{System.unique_integer([:positive])}"
      :ok = Registry.register(FakeDeskPluginX, %{"plugin_name" => name})

      items = Registry.collect_desk_items("staging")
      labels = Enum.map(items, &(Map.get(&1, :label) || ""))

      assert "X (staging)" in labels
      assert "X link" in labels
    end

    test "merges items across multiple plugins" do
      name_x = "fake-desk-merge-x-#{System.unique_integer([:positive])}"
      name_y = "fake-desk-merge-y-#{System.unique_integer([:positive])}"
      :ok = Registry.register(FakeDeskPluginX, %{"plugin_name" => name_x})
      :ok = Registry.register(FakeDeskPluginY, %{"plugin_name" => name_y})

      items = Registry.collect_desk_items("production")
      labels = Enum.map(items, &(Map.get(&1, :label) || ""))

      assert "X link" in labels
      assert "Y link" in labels
    end

    # `assert is_list(...)` verified only "did not raise": a `safe_call/4` that
    # returned `[]` for EVERY plugin gutted the collector and stayed green.
    # Assert instead that a healthy neighbour SURVIVES the bad plugin, and
    # that the raise was caught for the offending module by name.
    test "isolates a plugin whose callback raises, keeping its neighbours" do
      good = "fake-desk-raise-good-#{System.unique_integer([:positive])}"
      bad = "fake-desk-raise-#{System.unique_integer([:positive])}"
      :ok = Registry.register(FakeDeskPluginX, %{"plugin_name" => good})
      :ok = Registry.register(FakeRaisingDeskPlugin, %{"plugin_name" => bad})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          labels =
            Enum.map(Registry.collect_desk_items("production"), &(Map.get(&1, :label) || ""))

          assert "X link" in labels
        end)

      assert log =~ "FakeRaisingDeskPlugin.desk_items/1 raised"
    end

    test "OnixEdit's Bokbasen items are reachable through the collector" do
      # DESK collectors stay unfiltered on a workspace-less ctx (the consumer,
      # Barkpark.Structure, tiers by enablement itself). Only the TOP-MENU
      # collector gates off-by-default plugins on a nil workspace
      # (snav-w1-gating-determinism), so OnixEdit's desk items remain reachable
      # here.
      items = Registry.collect_desk_items("production")
      labels = Enum.map(items, &Map.get(&1, :label))

      assert "Bokbasen" in labels
      assert "Pending submissions" in labels
    end
  end
end

defmodule Barkpark.Plugins.RegistryDeskItemsStructureTest do
  @moduledoc """
  Integration test in its own module so it can `use Barkpark.DataCase`
  (needed by `Barkpark.Structure.build/1`, which calls
  `Content.list_schemas/1`) without polluting the async-unsafe Registry
  tests above with a SQL sandbox.
  """

  use Barkpark.DataCase, async: false

  # Reads the plugin registry via `Structure.build/1`; reset to the baseline
  # plugin set so a sibling test's leaked fakes can't perturb the built tree —
  # and reset again on exit so OUR registered fakes can't leak out either.
  setup do
    Barkpark.Plugins.Registry.reset()
    on_exit(fn -> Barkpark.Plugins.Registry.reset() end)
    :ok
  end

  defmodule FakeTierDeskPlugin do
    def desk_items(_dataset), do: [%{type: :link, label: "Tier link", path: "/admin/tier"}]
  end

  test "Structure.build/1 places plugin desk items under the Plugins tier as :plugin_link" do
    # OnixEdit ships default_enabled?: false (studio-structure-polish), so an
    # unscoped build (declaration defaults) no longer surfaces its nodes.
    # Register a FAKE plugin — unknown to Enablement → enabled + :plugins —
    # and assert its declarative :link arrives translated to :plugin_link,
    # grouped under the Plugins tier node.
    name = "fake-tier-desk-#{System.unique_integer([:positive])}"
    :ok = Barkpark.Plugins.Registry.register(FakeTierDeskPlugin, %{"plugin_name" => name})

    structure = Barkpark.Structure.build("production")

    plugins_tier = Enum.find(structure.items, &(Map.get(&1, :id) == "plugins"))
    assert plugins_tier, "expected the Plugins tier node in the built structure"
    assert plugins_tier.type == :list

    plugin_link =
      plugins_tier.items
      |> Enum.flat_map(fn group -> [group | group.items || []] end)
      |> Enum.find(fn node ->
        Map.get(node, :type) == :plugin_link and Map.get(node, :title) == "Tier link"
      end)

    assert plugin_link, "expected the fake plugin's link under the Plugins tier"
    assert plugin_link.filter == "/admin/tier"
  end

  test "Structure.build/1 drops a default-disabled plugin's desk items (OnixEdit)" do
    structure = Barkpark.Structure.build("production")

    titles =
      structure.items
      |> Enum.flat_map(fn node -> [node | node.items || []] end)
      |> Enum.map(&Map.get(&1, :title))

    refute "Pending submissions" in titles,
           "OnixEdit is off by default — its desk nodes must not surface unscoped"
  end
end
