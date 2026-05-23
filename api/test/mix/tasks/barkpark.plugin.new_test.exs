defmodule Mix.Tasks.Barkpark.Plugin.NewTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Barkpark.Plugin.New

  setup do
    prev_shell = Mix.shell()
    Mix.shell(Mix.Shell.IO)

    tmp =
      Path.join(System.tmp_dir!(), "barkpark_plugin_new_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)

    on_exit(fn ->
      File.rm_rf!(tmp)
      Mix.shell(prev_shell)
    end)

    {:ok, tmp: tmp}
  end

  # Destinations under a given --root, matching the generator's layout.
  defp manifest_path(root, name), do: Path.join([root, "priv", "plugins", name, "plugin.json"])
  defp lib_path(root, name), do: Path.join([root, "lib", "barkpark", "plugins", name <> ".ex"])

  defp test_path(root, name),
    do: Path.join([root, "test", "barkpark", "plugins", name <> "_test.exs"])

  describe "name validation" do
    test "rejects uppercase letters", %{tmp: tmp} do
      assert_raise Mix.Error, ~r/Invalid plugin name/, fn ->
        run(["BadName", "--root", tmp])
      end
    end

    test "rejects leading digit", %{tmp: tmp} do
      assert_raise Mix.Error, ~r/Invalid plugin name/, fn ->
        run(["1plugin", "--root", tmp])
      end
    end

    test "rejects special characters", %{tmp: tmp} do
      assert_raise Mix.Error, ~r/Invalid plugin name/, fn ->
        run(["plug!in", "--root", tmp])
      end
    end

    test "rejects missing name" do
      assert_raise Mix.Error, ~r/name is required/, fn ->
        run([])
      end
    end

    test "accepts hyphens and underscores", %{tmp: tmp} do
      run(["my-plugin_v2", "--root", tmp])
      assert File.exists?(manifest_path(tmp, "my-plugin_v2"))
    end
  end

  describe "generation" do
    test "lands the three files in the OnixEdit-style layout", %{tmp: tmp} do
      run(["hello", "--root", tmp, "--description", "Hello plugin"])

      assert File.exists?(manifest_path(tmp, "hello"))
      assert File.exists?(lib_path(tmp, "hello"))
      assert File.exists?(test_path(tmp, "hello"))
      assert File.exists?(Path.join([tmp, "priv", "plugins", "hello", "README.md"]))
      assert File.exists?(Path.join([tmp, "priv", "plugins", "hello", "schemas", ".gitkeep"]))

      # No stray module/test in the priv subtree — those must live in the
      # compiled lib/+test/ trees, not under priv/plugins/<name>/.
      refute File.exists?(Path.join([tmp, "priv", "plugins", "hello", "lib", "hello.ex"]))
      refute File.exists?(Path.join([tmp, "priv", "plugins", "hello", "test"]))
    end

    test "manifest carries the namespaced module key and validates", %{tmp: tmp} do
      run(["hello", "--root", tmp, "--description", "Hi", "--capabilities", "r,w,s"])

      manifest = tmp |> manifest_path("hello") |> File.read!() |> Jason.decode!()

      assert manifest["plugin_name"] == "hello"
      assert manifest["version"] == "0.1.0"
      assert manifest["description"] == "Hi"
      assert manifest["capabilities"] == ["routes", "workers", "schemas"]
      assert manifest["module"] == "Barkpark.Plugins.Hello"

      assert Barkpark.Plugins.Manifest.validate!(manifest)
    end

    test "default module is namespaced under Barkpark.Plugins", %{tmp: tmp} do
      run(["my-plugin", "--root", tmp])

      body = File.read!(lib_path(tmp, "my-plugin"))
      assert body =~ "defmodule Barkpark.Plugins.MyPlugin do"
      assert body =~ "use Barkpark.Plugin, manifest_path:"
    end

    test "entry module's manifest_path climbs to the priv manifest", %{tmp: tmp} do
      run(["hello", "--root", tmp])

      body = File.read!(lib_path(tmp, "hello"))
      assert body =~ ~s(manifest_path: "../../../priv/plugins/hello/plugin.json")
    end

    test "--module overrides the default module name", %{tmp: tmp} do
      run(["hello", "--root", tmp, "--module", "MyApp.Plugins.Hello"])

      body = File.read!(lib_path(tmp, "hello"))
      assert body =~ "defmodule MyApp.Plugins.Hello do"

      manifest = tmp |> manifest_path("hello") |> File.read!() |> Jason.decode!()
      assert manifest["module"] == "MyApp.Plugins.Hello"
    end

    test "--capabilities CSV parses correctly", %{tmp: tmp} do
      run(["hello", "--root", tmp, "--capabilities", "routes, workers , schemas"])

      manifest = tmp |> manifest_path("hello") |> File.read!() |> Jason.decode!()
      assert manifest["capabilities"] == ["routes", "workers", "schemas"]
    end

    test "default capabilities is empty", %{tmp: tmp} do
      run(["hello", "--root", tmp])

      manifest = tmp |> manifest_path("hello") |> File.read!() |> Jason.decode!()
      assert manifest["capabilities"] == []
    end

    test "--out overrides only the priv manifest dir", %{tmp: tmp} do
      out = Path.join(tmp, "custom_priv")
      run(["hello", "--root", tmp, "--out", out])

      assert File.exists?(Path.join(out, "plugin.json"))
      # Module + test still derive from --root, not --out.
      assert File.exists?(lib_path(tmp, "hello"))
      assert File.exists?(test_path(tmp, "hello"))
    end
  end

  describe "overwrite protection" do
    test "refuses to overwrite without --force", %{tmp: tmp} do
      run(["hello", "--root", tmp])

      assert_raise Mix.Error, ~r/Refusing to overwrite/, fn ->
        run(["hello", "--root", tmp])
      end
    end

    test "--force overwrites existing files", %{tmp: tmp} do
      run(["hello", "--root", tmp])

      stale = Path.join([tmp, "priv", "plugins", "hello", "stale.txt"])
      File.write!(stale, "stale")

      run(["hello", "--root", tmp, "--force"])

      refute File.exists?(stale)
      assert File.exists?(manifest_path(tmp, "hello"))
    end
  end

  describe "discovery match (regression for barkpark-zf6v)" do
    test "generated manifest resolves to the module the lib file defines", %{tmp: tmp} do
      run(["demo_plug", "--root", tmp])

      manifest = tmp |> manifest_path("demo_plug") |> File.read!() |> Jason.decode!()

      # The bug: resolve_module derived a module that the generated lib file
      # never defined → ensure_loaded? false → plugin skipped. Assert they
      # agree now.
      assert {:ok, resolved} = Barkpark.Plugins.Registry.resolve_module(manifest)
      assert resolved == Barkpark.Plugins.DemoPlug

      [{compiled_mod, _bin} | _] = Code.compile_file(lib_path(tmp, "demo_plug"))
      assert compiled_mod == resolved
      assert function_exported?(compiled_mod, :manifest, 0)

      parsed = compiled_mod.manifest()
      assert parsed["plugin_name"] == "demo_plug"
      assert parsed["version"] == "0.1.0"
    after
      mod = Module.concat([Barkpark, Plugins, DemoPlug])
      :code.purge(mod)
      :code.delete(mod)
    end
  end

  defp run(argv) do
    capture_io(fn -> New.run(argv) end)
  end

  defp capture_io(fun) do
    ExUnit.CaptureIO.capture_io(fun)
  end
end
