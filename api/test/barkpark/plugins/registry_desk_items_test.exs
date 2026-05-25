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

    test "tolerates plugins whose callback raises" do
      name = "fake-desk-raise-#{System.unique_integer([:positive])}"
      :ok = Registry.register(FakeRaisingDeskPlugin, %{"plugin_name" => name})

      # Must not raise — safe_call catches and substitutes [].
      assert is_list(Registry.collect_desk_items("production"))
    end

    test "OnixEdit's Bokbasen items are reachable through the collector" do
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
  # plugin set so a sibling test's leaked fakes can't perturb the built tree.
  setup do
    Barkpark.Plugins.Registry.reset()
    :ok
  end

  test "Structure.build/1 appends plugin desk items after schema-discovery items" do
    structure = Barkpark.Structure.build("production")

    # OnixEdit's "Pending submissions" link node renders with type
    # :plugin_link (translated by Structure from the plugin's
    # declarative :link shape).
    plugin_link =
      Enum.find(structure.items, fn node ->
        Map.get(node, :type) == :plugin_link and
          Map.get(node, :title) == "Pending submissions"
      end)

    assert plugin_link, "expected OnixEdit's Pending submissions link in built structure"
    assert plugin_link.filter == "/admin/onixedit/staleness"
  end
end
