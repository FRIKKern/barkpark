defmodule Barkpark.PluginTest do
  use ExUnit.Case, async: true

  describe "use Barkpark.Plugin (compile-time macro)" do
    test "fixture plugin compiles cleanly and exposes parsed manifest/0" do
      manifest = Barkpark.Plugins.Hello.manifest()

      assert is_map(manifest)
      assert manifest["plugin_name"] == "hello"
      assert manifest["module"] == "Barkpark.Plugins.Hello"
      assert manifest["version"] == "0.0.1"
      assert manifest["capabilities"] == ["routes"]
    end

    test "default optional callbacks no-op safely" do
      assert Barkpark.Plugins.Hello.register_routes(:any_router) == :ok
      assert Barkpark.Plugins.Hello.register_workers(:any_supervisor) == []
      assert Barkpark.Plugins.Hello.register_schemas([]) == []
      assert Barkpark.Plugins.Hello.validate_settings(%{}) == :ok
    end

    test "fixture module declares the Barkpark.Plugin behaviour" do
      behaviours =
        :attributes
        |> Barkpark.Plugins.Hello.module_info()
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Barkpark.Plugin in behaviours
    end
  end
end
