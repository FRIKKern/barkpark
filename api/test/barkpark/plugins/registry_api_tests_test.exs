defmodule Barkpark.Plugins.RegistryApiTestsTest do
  @moduledoc """
  Resolver-chain coverage for `Barkpark.Plugins.Registry.collect_api_tests/1`
  (Goal `barkpark-bsp`, task barkpark-rsek).

  The collector threads `:baseline` through every registered plugin's
  `resolve_api_tests/2` in load order. Two behaviours matter:

    1. **Additive** — a plugin that exports `api_tests/0` (bare module,
       no `use Barkpark.Plugin`) gets its list concatenated to `prev`
       via the additive-form lift in `apply_resolver/8`.
    2. **Resolver-override** — a plugin that overrides
       `resolve_api_tests/2` directly may REMOVE, reorder, or amend
       sibling-plugin entries. Symmetric with how every other resolver
       on the chain behaves.

  The Registry is a process-global singleton, so this file is
  `async: false` and uses unique plugin names per test to avoid
  cross-test pollution. Tests that touch
  `Application.put_env(:barkpark, :plugins, …)` restore on exit so the
  load-order list does not leak into sibling test files.
  """

  use Barkpark.RegistryCase, async: false

  alias Barkpark.Plugins.Registry

  # ─── Fake plugin modules ────────────────────────────────────────────
  #
  # Bare modules (no `use Barkpark.Plugin`) — the macro requires a
  # `plugin.json` on disk, and `apply_resolver/8` handles bare modules
  # exactly like the resolver chain needs:
  #
  #   * Module exports `resolve_api_tests/2`   → path 1 (direct call)
  #   * Module exports only `api_tests/0`      → path 2 (additive lift)
  #
  # Both paths are exercised below.

  @spec_a %{
    name: "PluginA spec",
    method: :get,
    path: "/plugin-a",
    auth: :none,
    asserts: [{:status, 200}]
  }

  @spec_b %{
    name: "PluginB spec",
    method: :get,
    path: "/plugin-b",
    auth: :none,
    asserts: [{:status, 200}]
  }

  defmodule AdditiveApiTestsPlugin do
    # Bare additive form — `apply_resolver/8` lifts via prev ++ result.
    def api_tests do
      [
        %{
          name: "PluginA spec",
          method: :get,
          path: "/plugin-a",
          auth: :none,
          asserts: [{:status, 200}]
        }
      ]
    end
  end

  defmodule SecondAdditiveApiTestsPlugin do
    def api_tests do
      [
        %{
          name: "PluginB spec",
          method: :get,
          path: "/plugin-b",
          auth: :none,
          asserts: [{:status, 200}]
        }
      ]
    end
  end

  defmodule FilteringApiTestsPlugin do
    # Resolver-override — drops every prior spec whose name starts
    # with "PluginA". Proves a plugin can REMOVE sibling-plugin entries.
    def resolve_api_tests(prev, _ctx) do
      Enum.reject(prev, fn spec -> String.starts_with?(spec.name, "PluginA") end)
    end
  end

  # ─── Helpers ────────────────────────────────────────────────────────

  defp uniq_name(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp set_load_order(names) do
    # `capture/0` (an `:unset` sentinel), not `get_env(…, [])`: a `[]` default
    # would restore an EXPLICIT `[]` — the discovery kill switch.
    prev = Barkpark.PluginEnv.capture()
    Application.put_env(:barkpark, :plugins, names)
    on_exit(fn -> Barkpark.PluginEnv.restore(prev) end)
  end

  # ─── Group 1 — additive plugins concatenate ─────────────────────────

  describe "collect_api_tests/1 — additive plugins" do
    test "concatenates `api_tests/0` from every registered plugin in load order" do
      name_a = uniq_name("api-tests-additive-a")
      name_b = uniq_name("api-tests-additive-b")

      :ok = Registry.register(AdditiveApiTestsPlugin, %{"plugin_name" => name_a})
      :ok = Registry.register(SecondAdditiveApiTestsPlugin, %{"plugin_name" => name_b})

      set_load_order([name_a, name_b])

      tests = Registry.collect_api_tests(baseline: [], ctx: %{})

      # The chain MUST include both plugins' contributions — order
      # follows the configured load order (A then B).
      names = Enum.map(tests, & &1.name)
      assert "PluginA spec" in names
      assert "PluginB spec" in names

      idx_a = Enum.find_index(names, &(&1 == "PluginA spec"))
      idx_b = Enum.find_index(names, &(&1 == "PluginB spec"))
      assert idx_a < idx_b, "expected PluginA before PluginB given load order"
    end

    test "threads :baseline through the chain — host-seeded specs survive" do
      name = uniq_name("api-tests-baseline")
      :ok = Registry.register(AdditiveApiTestsPlugin, %{"plugin_name" => name})
      set_load_order([name])

      host_baseline = [
        %{
          name: "host baseline spec",
          method: :get,
          path: "/host",
          auth: :none,
          asserts: [{:status, 200}]
        }
      ]

      tests = Registry.collect_api_tests(baseline: host_baseline, ctx: %{})
      names = Enum.map(tests, & &1.name)

      assert "host baseline spec" in names
      assert "PluginA spec" in names
    end
  end

  # ─── Group 2 — resolver-override plugin can FILTER ──────────────────

  describe "collect_api_tests/1 — resolver-override plugin" do
    test "a plugin's resolve_api_tests/2 can REMOVE entries from prev" do
      name_a = uniq_name("api-tests-add-a")
      name_b = uniq_name("api-tests-add-b")
      name_filter = uniq_name("api-tests-filter")

      :ok = Registry.register(AdditiveApiTestsPlugin, %{"plugin_name" => name_a})
      :ok = Registry.register(SecondAdditiveApiTestsPlugin, %{"plugin_name" => name_b})
      :ok = Registry.register(FilteringApiTestsPlugin, %{"plugin_name" => name_filter})

      # Filter plugin MUST come last so it sees A's and B's contributions
      # in `prev`. Symmetric with how every other resolver on the chain
      # treats sibling-plugin contributions.
      set_load_order([name_a, name_b, name_filter])

      tests = Registry.collect_api_tests(baseline: [], ctx: %{})
      names = Enum.map(tests, & &1.name)

      refute "PluginA spec" in names, "filter plugin should have dropped PluginA"
      assert "PluginB spec" in names, "PluginB should survive"
    end
  end

  # Spec fixtures referenced indirectly via the additive plugin
  # modules. Pinned here so the test file documents the exact shape
  # plugins return — keeps reviewers from having to trace through the
  # plugin module definitions to verify shape.
  describe "Spec shape sanity" do
    test "additive plugin module returns a list of well-shaped specs" do
      assert [spec] = AdditiveApiTestsPlugin.api_tests()
      assert spec.name == @spec_a.name
      assert spec.method == :get
      assert is_binary(spec.path)
      assert is_list(spec.asserts)
    end

    test "second additive plugin module returns a list of well-shaped specs" do
      assert [spec] = SecondAdditiveApiTestsPlugin.api_tests()
      assert spec.name == @spec_b.name
    end
  end
end
