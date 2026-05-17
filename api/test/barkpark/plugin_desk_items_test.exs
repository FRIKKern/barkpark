defmodule Barkpark.PluginDeskItemsTest do
  @moduledoc """
  Covers the `desk_items/1` callback added to `Barkpark.Plugin`:

    * `Barkpark.Plugins.Hello` (fixture) inherits the default `[]` impl.
    * `Barkpark.Plugins.OnixEdit` declares the Bokbasen items.
  """

  use ExUnit.Case, async: true

  describe "default desk_items/1" do
    test "fixture plugin returns the injected empty list for any dataset" do
      assert Barkpark.Plugins.Hello.desk_items("production") == []
      assert Barkpark.Plugins.Hello.desk_items("staging") == []
    end
  end

  describe "OnixEdit.desk_items/1" do
    setup do
      [items: Barkpark.Plugins.OnixEdit.desk_items("production")]
    end

    test "returns a divider followed by a link", %{items: items} do
      assert is_list(items)
      assert length(items) == 2
      assert [%{type: :divider, label: "Bokbasen"}, %{type: :link} | _] = items
    end

    test "the link points at the staleness console", %{items: items} do
      link = Enum.find(items, &(Map.get(&1, :type) == :link))

      assert link.label == "Pending submissions"
      assert link.path == "/admin/onixedit/staleness"
      assert link.icon == "clock"
    end

    test "is dataset-agnostic for v1 (no per-dataset shape difference)" do
      prod = Barkpark.Plugins.OnixEdit.desk_items("production")
      staging = Barkpark.Plugins.OnixEdit.desk_items("staging")
      assert prod == staging
    end
  end
end
