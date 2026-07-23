defmodule Barkpark.PluginTopMenuTest do
  @moduledoc """
  Covers the `top_menu_entries/0` callback added to `Barkpark.Plugin`:

    * `Barkpark.Plugins.Hello` (fixture) inherits the default `[]` impl.
    * `Barkpark.Plugins.OnixEdit` declares the Bokbasen tab.
    * `Barkpark.Plugins.Tasks` declares the Projects board tab.
  """

  use ExUnit.Case, async: true

  describe "default top_menu_entries/0" do
    test "fixture plugin returns the injected empty list" do
      assert Barkpark.Plugins.Hello.top_menu_entries() == []
    end
  end

  describe "OnixEdit.top_menu_entries/0" do
    setup do
      [tabs: Barkpark.Plugins.OnixEdit.top_menu_entries()]
    end

    test "returns exactly one Bokbasen tab", %{tabs: tabs} do
      assert is_list(tabs)
      assert length(tabs) == 1
      [tab] = tabs
      assert tab.label == "Bokbasen"
    end

    test "the tab points at the staleness console", %{tabs: tabs} do
      [tab] = tabs
      assert tab.path == "/admin/onixedit/staleness"
    end

    test "carries an icon and an order < default 100", %{tabs: tabs} do
      [tab] = tabs
      assert tab.icon == "send"
      assert tab.order == 50
    end

    test "active_when is a path-prefix string", %{tabs: tabs} do
      [tab] = tabs
      assert tab.active_when == "/admin/onixedit/"
    end
  end

  describe "Tasks.top_menu_entries/0" do
    setup do
      [tabs: Barkpark.Plugins.Tasks.top_menu_entries()]
    end

    test "returns the Projects board tab and the Fleet roster tab", %{tabs: tabs} do
      assert is_list(tabs)
      assert [%{label: "Projects"}, %{label: "Fleet"}] = tabs
      assert Enum.map(tabs, & &1.path) == ["/admin/projects", "/admin/fleet"]
    end

    test "orders after the built-in tabs (35/36, ahead of the default 100)", %{tabs: tabs} do
      [projects, fleet] = tabs
      assert projects.order == 35
      assert projects.icon == "columns"
      assert fleet.order == 36
      assert fleet.icon == "activity"
    end

    test "active_when covers each tab's own /admin subtree", %{tabs: tabs} do
      [projects, fleet] = tabs
      assert projects.active_when == "/admin/projects"
      assert fleet.active_when == "/admin/fleet"
    end
  end
end
