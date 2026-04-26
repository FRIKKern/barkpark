defmodule Barkpark.Validation.PluginCheckerLoaderTest do
  # Synchronous because the validation registry is a single named GenServer
  # in the supervision tree (mirrors RegistryTest pattern).
  use ExUnit.Case, async: false

  alias Barkpark.Plugins.Registry, as: PluginRegistry
  alias Barkpark.Validation.PluginCheckerLoader
  alias Barkpark.Validation.Registry, as: ValidationRegistry

  @fixture_root Path.expand("../../support/fixtures/plugins", __DIR__)

  describe "load_plugin/1" do
    test "registers the fixture plugin's checker under the namespaced name" do
      :ok = PluginRegistry.discover_and_register([@fixture_root])

      {:ok, hello_entry} = PluginRegistry.lookup("hello")

      assert ["plugin:hello:always_ok"] = PluginCheckerLoader.load_plugin(hello_entry)

      assert {:ok, Barkpark.Plugins.Hello.AlwaysOk} =
               ValidationRegistry.lookup("plugin:hello:always_ok")

      # Round-trip via ValidationRegistry.check/3 — the entry point WI1's
      # rule DSL :matches:<checker> op will use.
      assert :ok = ValidationRegistry.check("plugin:hello:always_ok", "any", %{})
    end

    test "is idempotent — loading twice does not error and keeps the registration" do
      :ok = PluginRegistry.discover_and_register([@fixture_root])
      {:ok, hello_entry} = PluginRegistry.lookup("hello")

      assert ["plugin:hello:always_ok"] = PluginCheckerLoader.load_plugin(hello_entry)
      assert ["plugin:hello:always_ok"] = PluginCheckerLoader.load_plugin(hello_entry)

      assert {:ok, _} = ValidationRegistry.lookup("plugin:hello:always_ok")
    end

    test "returns [] for plugin entries without a checkers/0 callback" do
      assert [] =
               PluginCheckerLoader.load_plugin(%{
                 module: __MODULE__.NoCheckersPlugin,
                 name: "no_checkers",
                 manifest: %{}
               })
    end

    test "returns [] for malformed entries" do
      assert [] = PluginCheckerLoader.load_plugin(:not_a_map)
      assert [] = PluginCheckerLoader.load_plugin(%{name: "x"})
    end
  end

  describe "load_all/0" do
    test "covers every plugin currently in Plugins.Registry" do
      :ok = PluginRegistry.discover_and_register([@fixture_root])

      registered = PluginCheckerLoader.load_all()
      assert "plugin:hello:always_ok" in registered
    end
  end

  describe "ValidationRegistry.lookup/1 unknown" do
    test ":error for an unregistered name" do
      assert :error =
               ValidationRegistry.lookup(
                 "plugin:nonexistent:#{System.unique_integer([:positive])}"
               )
    end

    test ":unknown_checker error from the dispatch helper" do
      assert {:error, :unknown_checker} =
               ValidationRegistry.check(
                 "plugin:nonexistent:#{System.unique_integer([:positive])}",
                 "value",
                 %{}
               )
    end
  end
end

defmodule Barkpark.Validation.PluginCheckerLoaderTest.NoCheckersPlugin do
  @moduledoc false
  # Used as a synthetic plugin module that does NOT export `checkers/0`.
  def manifest, do: %{}
end
