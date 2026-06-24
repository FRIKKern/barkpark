defmodule Barkpark.Plugins.Registry.ResolverChainTest do
  @moduledoc """
  Unit tests for `Barkpark.Plugins.Registry.ResolverChain`.

  Covers the two public helpers that sit closest to pure logic:

    * `safe_call/4` — defensive module dispatch; returns default on missing
      function, unloaded module, or exception.
    * `compute_top_menu_entries/2` — normalization (missing keys filled in)
      and sort by `{order, label}` layered on top of the resolver chain.

  `safe_call/4` needs no GenServer — it runs purely against in-process
  modules, so these cases run `async: true`. The `compute_top_menu_entries/2`
  group drives the live Registry singleton and is bracketed by `RegistryCase`
  (`async: false`).
  """

  # safe_call/4 is purely in-process — no GenServer dependency.
  use Barkpark.RegistryCase, async: false

  alias Barkpark.Plugins.Registry.ResolverChain
  alias Barkpark.Plugins.Registry

  # ── Inline fakes for safe_call tests ────────────────────────────────

  defmodule GoodModule do
    def greet(name), do: "hello #{name}"
    def add(a, b), do: a + b
  end

  defmodule RaisingModule do
    def boom, do: raise("intentional boom")
  end

  # ── safe_call/4 ──────────────────────────────────────────────────────

  describe "safe_call/4" do
    test "calls an exported function and returns its result" do
      assert ResolverChain.safe_call(GoodModule, :greet, ["world"], "default") == "hello world"
    end

    test "calls multi-arg functions correctly" do
      assert ResolverChain.safe_call(GoodModule, :add, [3, 4], 0) == 7
    end

    test "returns the default when the function is not exported on the module" do
      assert ResolverChain.safe_call(GoodModule, :nonexistent, [], :fallback) == :fallback
    end

    test "returns the default when the module atom is not loaded" do
      assert ResolverChain.safe_call(DoesNotExistAtAll, :whatever, [], "safe") == "safe"
    end

    test "returns the default (not raises) when the function raises" do
      assert ResolverChain.safe_call(RaisingModule, :boom, [], "caught") == "caught"
    end
  end

  # ── Fake plugin for compute_top_menu_entries tests ───────────────────

  defmodule NormFakePlugin do
    # Returns entries with deliberately missing optional fields.
    def top_menu_entries do
      [
        # label and path only — no icon, no order, no active_when
        %{label: "Zeta", path: "/z"},
        # explicit low order → should sort first
        %{label: "Alpha", path: "/a", order: 10, icon: "alpha-icon", active_when: "/a/"}
      ]
    end
  end

  # ── compute_top_menu_entries/2 ────────────────────────────────────────

  describe "compute_top_menu_entries/2" do
    test "fills in missing keys with defaults" do
      name = "rcct-norm-#{System.unique_integer([:positive])}"
      :ok = Registry.register(NormFakePlugin, %{"plugin_name" => name})

      entries = ResolverChain.compute_top_menu_entries([], %{})

      zeta = Enum.find(entries, &(&1.label == "Zeta"))
      assert zeta, "expected Zeta entry to be present"
      assert zeta.path == "/z"
      assert zeta.icon == nil
      assert zeta.order == 100
      assert zeta.active_when == nil
    end

    test "preserves explicit fields (icon, order, active_when)" do
      name = "rcct-explicit-#{System.unique_integer([:positive])}"
      :ok = Registry.register(NormFakePlugin, %{"plugin_name" => name})

      entries = ResolverChain.compute_top_menu_entries([], %{})

      alpha = Enum.find(entries, &(&1.label == "Alpha"))
      assert alpha, "expected Alpha entry to be present"
      assert alpha.order == 10
      assert alpha.icon == "alpha-icon"
      assert alpha.active_when == "/a/"
    end

    test "sorts by {order, label} — lower order first, then alphabetically" do
      name = "rcct-sort-#{System.unique_integer([:positive])}"
      :ok = Registry.register(NormFakePlugin, %{"plugin_name" => name})

      entries = ResolverChain.compute_top_menu_entries([], %{})

      our_labels =
        entries
        |> Enum.filter(&(&1.label in ~w(Alpha Zeta)))
        |> Enum.uniq_by(& &1.label)
        |> Enum.map(& &1.label)

      # Alpha (order 10) before Zeta (order 100)
      assert our_labels == ["Alpha", "Zeta"],
             "expected Alpha (order 10) before Zeta (order 100); got #{inspect(our_labels)}"
    end

    test "baseline entries are normalized and included in the sort" do
      baseline = [%{label: "Baseline", path: "/b", order: 5}]
      entries = ResolverChain.compute_top_menu_entries(baseline, %{})

      b = Enum.find(entries, &(&1.label == "Baseline"))
      assert b, "expected baseline entry to pass through"
      assert b.order == 5
      assert b.icon == nil
    end
  end
end
