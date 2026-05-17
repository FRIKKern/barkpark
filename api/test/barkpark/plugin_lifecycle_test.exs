defmodule Barkpark.PluginLifecycleTest do
  @moduledoc """
  Behaviour-shape tests for the `lifecycle_hooks/0` callback added to
  `Barkpark.Plugin` in commit 14c6e48 (Goal `barkpark-9lq`).

  Three assertions cover the contract:

    1. `lifecycle_hooks/0` is declared on the behaviour
       (`behaviour_info(:callbacks)`).
    2. It is listed in `@optional_callbacks` — plugins that don't
       declare any lifecycle hooks must still compile cleanly.
    3. The `__using__/1` macro supplies a `defoverridable` default that
       returns `%{}` — a plugin that calls `use Barkpark.Plugin` and
       defines no further callbacks still has a working
       `lifecycle_hooks/0`.

  No state mutation, no plugin registration — pure introspection of the
  behaviour module and one tiny `use Barkpark.Plugin` fixture defined
  inline. `async: true` is safe.
  """

  use ExUnit.Case, async: true

  describe "Barkpark.Plugin behaviour shape" do
    test "behaviour_info(:callbacks) exports lifecycle_hooks/0" do
      callbacks = Barkpark.Plugin.behaviour_info(:callbacks)

      assert {:lifecycle_hooks, 0} in callbacks,
             "expected @callback lifecycle_hooks/0 on Barkpark.Plugin"
    end

    test "lifecycle_hooks/0 is listed in @optional_callbacks" do
      optional = Barkpark.Plugin.behaviour_info(:optional_callbacks)

      assert {:lifecycle_hooks, 0} in optional,
             "expected lifecycle_hooks/0 to be optional on Barkpark.Plugin"
    end
  end

  describe "defoverridable default from use Barkpark.Plugin" do
    # Sibling module compiled at test-suite compile time. The `use
    # Barkpark.Plugin` macro reads a real manifest at compile time —
    # reuse the OnixEdit plugin.json that other tests rely on.
    defmodule DummyLifecyclePlugin do
      @moduledoc false
      use Barkpark.Plugin,
        manifest_path: "../../priv/plugins/onixedit/plugin.json"
    end

    test "default lifecycle_hooks/0 returns an empty map" do
      assert DummyLifecyclePlugin.lifecycle_hooks() == %{}
    end

    test "the default is overridable (function is exported at arity 0)" do
      assert function_exported?(DummyLifecyclePlugin, :lifecycle_hooks, 0)
    end
  end
end
