defmodule Barkpark.Plugins.RegistryTest do
  # The Registry is a single named GenServer in the supervision tree, so
  # tests share state — keep this synchronous.
  use ExUnit.Case, async: false

  alias Barkpark.Plugins.Registry

  @fixture_root Path.expand("../../support/fixtures/plugins", __DIR__)

  describe "registry lifecycle" do
    test "is alive after application boot" do
      assert is_pid(GenServer.whereis(Registry))
    end
  end

  describe "register/2 + lookup/1 + all/0" do
    test "round-trips a manifest map" do
      manifest = %{"plugin_name" => "round_trip", "version" => "0.0.0"}
      assert :ok = Registry.register(:fake_module_round_trip, manifest)

      assert {:ok, %{name: "round_trip", module: :fake_module_round_trip, manifest: ^manifest}} =
               Registry.lookup("round_trip")

      assert Enum.any?(Registry.all(), &(&1.name == "round_trip"))
    end

    test "lookup/1 returns :error for unknown plugin" do
      assert :error = Registry.lookup("does-not-exist-#{System.unique_integer([:positive])}")
    end

    test "register/2 rejects manifest without plugin_name" do
      assert {:error, :no_plugin_name} = Registry.register(:bad_mod, %{"name" => "no-discrim"})
    end
  end

  describe "discover_and_register/1" do
    test "finds and registers the hello fixture plugin" do
      assert :ok = Registry.discover_and_register([@fixture_root])

      assert {:ok, %{module: Barkpark.Plugins.Hello, manifest: %{"plugin_name" => "hello"}}} =
               Registry.lookup("hello")
    end

    test "tolerates non-existent roots without raising" do
      assert :ok = Registry.discover_and_register(["/this/path/does/not/exist/ever"])
    end

    test "tolerates an empty path list" do
      assert :ok = Registry.discover_and_register([])
    end
  end
end
