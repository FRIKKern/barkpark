defmodule Barkpark.Plugins.RegistryTopMenuTest do
  @moduledoc """
  Covers `Barkpark.Plugins.Registry.collect_top_menu_entries/0` — the
  11th plugin collector. Registers fake plugin modules against the
  live (boot-time) Registry GenServer, exercises the collector, and
  verifies merge + sort behaviour.
  """

  # The Registry is a singleton in the supervision tree — shared state.
  use Barkpark.RegistryCase, async: false

  alias Barkpark.Plugins.Registry

  # ── Fake plugins ────────────────────────────────────────────────────

  defmodule FakeTopMenuPluginA do
    def top_menu_entries do
      [
        %{label: "Alpha", path: "/admin/alpha", icon: "alpha", order: 80}
      ]
    end
  end

  defmodule FakeTopMenuPluginB do
    def top_menu_entries do
      [
        # Two tabs, no explicit order → both default to 100.
        %{label: "Bravo", path: "/admin/bravo"},
        %{label: "Charlie", path: "/admin/charlie", active_when: "/admin/c/"}
      ]
    end
  end

  defmodule FakeRaisingTopMenuPlugin do
    def top_menu_entries, do: raise("boom from FakeRaisingTopMenuPlugin")
  end

  describe "collect_top_menu_entries/0" do
    test "flattens entries from a registered plugin and exposes them" do
      name = "fake-tm-a-#{System.unique_integer([:positive])}"
      :ok = Registry.register(FakeTopMenuPluginA, %{"plugin_name" => name})

      tabs = Registry.collect_top_menu_entries()
      assert Enum.any?(tabs, &(&1.label == "Alpha" and &1.path == "/admin/alpha"))
    end

    test "merges entries across plugins; orders sort ascending then by label" do
      name_a = "fake-tm-merge-a-#{System.unique_integer([:positive])}"
      name_b = "fake-tm-merge-b-#{System.unique_integer([:positive])}"
      :ok = Registry.register(FakeTopMenuPluginA, %{"plugin_name" => name_a})
      :ok = Registry.register(FakeTopMenuPluginB, %{"plugin_name" => name_b})

      tabs = Registry.collect_top_menu_entries()

      # Filter to just the labels we contributed (de-duplicated — earlier
      # tests in this file register the same fake modules under different
      # plugin names, and the Registry is a process-global singleton).
      ours =
        tabs
        |> Enum.filter(&(&1.label in ~w(Alpha Bravo Charlie)))
        |> Enum.uniq_by(& &1.label)

      labels = Enum.map(ours, & &1.label)

      # Alpha (order 80) comes first; then Bravo and Charlie (default 100)
      # tie-broken alphabetically by label.
      assert labels == ["Alpha", "Bravo", "Charlie"]
    end

    test "default order is 100 when omitted" do
      name = "fake-tm-default-#{System.unique_integer([:positive])}"
      :ok = Registry.register(FakeTopMenuPluginB, %{"plugin_name" => name})

      tabs = Registry.collect_top_menu_entries()
      bravo = Enum.find(tabs, &(&1.label == "Bravo"))
      assert bravo.order == 100
    end

    test "tolerates plugins whose callback raises" do
      name = "fake-tm-raise-#{System.unique_integer([:positive])}"
      :ok = Registry.register(FakeRaisingTopMenuPlugin, %{"plugin_name" => name})

      # Must not raise — safe_call catches and substitutes [].
      assert is_list(Registry.collect_top_menu_entries())
    end

    test "tolerates plugins that don't implement the callback" do
      name = "fake-tm-noop-#{System.unique_integer([:positive])}"
      :ok = Registry.register(__MODULE__, %{"plugin_name" => name})

      assert is_list(Registry.collect_top_menu_entries())
    end

    test "OnixEdit's Bokbasen tab is reachable through the collector" do
      tabs = Registry.collect_top_menu_entries()

      bokbasen = Enum.find(tabs, &(&1.label == "Bokbasen"))

      assert bokbasen, "expected OnixEdit's Bokbasen tab in collected entries"
      assert bokbasen.path == "/admin/onixedit/staleness"
      assert bokbasen.order == 50
    end
  end
end
