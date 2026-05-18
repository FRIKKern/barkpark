defmodule Barkpark.PluginApiTestsTest do
  @moduledoc """
  Behaviour-shape tests for the `api_tests/0` + `resolve_api_tests/2`
  callbacks added to `Barkpark.Plugin` for Goal `barkpark-bsp`.

  Three groups of assertions:

    1. `api_tests/0` is declared on the behaviour, is listed in
       `@optional_callbacks`, and has the documented arity.
    2. `resolve_api_tests/2` is declared on the behaviour, is listed in
       `@optional_callbacks`, and has the documented arity.
    3. The `__using__/1` macro supplies a `defoverridable` default —
       `api_tests/0` returns `[]` and `resolve_api_tests/2` lifts that
       empty list (identity) when neither callback is overridden.

  No state mutation, no plugin registration — pure introspection of the
  behaviour module plus one tiny `use Barkpark.Plugin` fixture defined
  inline. Safe to run `async: true`.
  """

  use ExUnit.Case, async: true

  describe "Barkpark.Plugin behaviour shape — api_tests/0" do
    test "behaviour_info(:callbacks) exports api_tests/0" do
      callbacks = Barkpark.Plugin.behaviour_info(:callbacks)

      assert {:api_tests, 0} in callbacks,
             "expected @callback api_tests/0 on Barkpark.Plugin"
    end

    test "api_tests/0 is listed in @optional_callbacks" do
      optional = Barkpark.Plugin.behaviour_info(:optional_callbacks)

      assert {:api_tests, 0} in optional,
             "expected api_tests/0 to be optional on Barkpark.Plugin"
    end
  end

  describe "Barkpark.Plugin behaviour shape — resolve_api_tests/2" do
    test "behaviour_info(:callbacks) exports resolve_api_tests/2" do
      callbacks = Barkpark.Plugin.behaviour_info(:callbacks)

      assert {:resolve_api_tests, 2} in callbacks,
             "expected @callback resolve_api_tests/2 on Barkpark.Plugin"
    end

    test "resolve_api_tests/2 is listed in @optional_callbacks" do
      optional = Barkpark.Plugin.behaviour_info(:optional_callbacks)

      assert {:resolve_api_tests, 2} in optional,
             "expected resolve_api_tests/2 to be optional on Barkpark.Plugin"
    end
  end

  describe "defoverridable defaults from `use Barkpark.Plugin`" do
    # `use Barkpark.Plugin` reads a real manifest at compile time. Reuse
    # the OnixEdit plugin.json that other plugin behaviour-shape tests
    # already lean on — the path is stable and the manifest is
    # validation-clean.
    defmodule DummyApiTestsPlugin do
      @moduledoc false
      use Barkpark.Plugin,
        manifest_path: "../../priv/plugins/onixedit/plugin.json"
    end

    test "default api_tests/0 returns an empty list" do
      assert DummyApiTestsPlugin.api_tests() == []
    end

    test "default resolve_api_tests/2 is identity-when-empty (additive lift)" do
      # The default `resolve_api_tests/2` injected by `use Barkpark.Plugin`
      # calls `api_tests/0` and appends — when both are at their defaults
      # the chain is identity (`prev ++ [] == prev`).
      assert DummyApiTestsPlugin.resolve_api_tests([], %{}) == []
      assert DummyApiTestsPlugin.resolve_api_tests([:existing], %{}) == [:existing]
    end

    test "both defaults are overridable (functions exported at documented arities)" do
      assert function_exported?(DummyApiTestsPlugin, :api_tests, 0)
      assert function_exported?(DummyApiTestsPlugin, :resolve_api_tests, 2)
    end
  end
end
