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

    # These two used to assert only `is_list(...)` — i.e. "did not raise".
    # Making `ResolverChain.safe_call/4` return `[]` for EVERY plugin gutted
    # the collector and kept them green. They now register the offending
    # plugin ALONGSIDE a healthy one and assert that the healthy
    # contribution SURVIVES, which is the property isolation actually means.
    # This mirrors `registry_oban_crontab_test.exs` "isolates a plugin whose
    # oban_crontab/0 raises", which already had the right shape.
    test "isolates a plugin whose callback raises, keeping its neighbours" do
      good = "fake-tm-raise-good-#{System.unique_integer([:positive])}"
      bad = "fake-tm-raise-#{System.unique_integer([:positive])}"
      :ok = Registry.register(FakeTopMenuPluginA, %{"plugin_name" => good})

      # The top-menu snapshot is computed workspace-less at REGISTRATION
      # (snav-w1-gating-determinism) and `collect_top_menu_entries/0` only
      # reads the cache — so the rescue fires here, not at collect time.
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          :ok = Registry.register(FakeRaisingTopMenuPlugin, %{"plugin_name" => bad})
        end)

      # The raise was actually caught for THIS plugin, not merely absent.
      assert log =~ "FakeRaisingTopMenuPlugin.top_menu_entries/0 raised"

      # And the healthy neighbour still lands — a blanket `[]` reds here.
      labels = Enum.map(Registry.collect_top_menu_entries(), & &1.label)
      assert "Alpha" in labels
    end

    test "tolerates plugins that don't implement the callback, keeping its neighbours" do
      good = "fake-tm-noop-good-#{System.unique_integer([:positive])}"
      noop = "fake-tm-noop-#{System.unique_integer([:positive])}"
      :ok = Registry.register(FakeTopMenuPluginA, %{"plugin_name" => good})
      :ok = Registry.register(__MODULE__, %{"plugin_name" => noop})

      labels = Enum.map(Registry.collect_top_menu_entries(), & &1.label)

      assert "Alpha" in labels
    end

    test "OnixEdit is off by default — its Bokbasen tab does NOT leak on the workspace-less collector" do
      # snav-w1-gating-determinism: `collect_top_menu_entries/0` reads the
      # cached snapshot, computed workspace-less at registration. That path now
      # resolves via `Enablement.effective(nil)` → declaration defaults, and
      # OnixEdit declares `default_enabled? == false`, so its Bokbasen tab is
      # gated OFF rather than leaking on every workspace-less surface. (Surfacing
      # when a workspace enables OnixEdit is covered in resolver_outputs_test.)
      tabs = Registry.collect_top_menu_entries()

      refute Enum.any?(tabs, &(&1.label == "Bokbasen")),
             "OnixEdit is off by default; its Bokbasen tab must not surface workspace-less"
    end
  end
end
