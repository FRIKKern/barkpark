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

  describe "name validation" do
    test "rejects uppercase letters", %{tmp: tmp} do
      assert_raise Mix.Error, ~r/Invalid plugin name/, fn ->
        run(["BadName", "--out", Path.join(tmp, "out")])
      end
    end

    test "rejects leading digit", %{tmp: tmp} do
      assert_raise Mix.Error, ~r/Invalid plugin name/, fn ->
        run(["1plugin", "--out", Path.join(tmp, "out")])
      end
    end

    test "rejects special characters", %{tmp: tmp} do
      assert_raise Mix.Error, ~r/Invalid plugin name/, fn ->
        run(["plug!in", "--out", Path.join(tmp, "out")])
      end
    end

    test "rejects missing name" do
      assert_raise Mix.Error, ~r/name is required/, fn ->
        run([])
      end
    end

    test "accepts hyphens and underscores", %{tmp: tmp} do
      out = Path.join(tmp, "ok")
      run(["my-plugin_v2", "--out", out])
      assert File.exists?(Path.join(out, "plugin.json"))
    end
  end

  describe "generation" do
    test "creates the expected file tree", %{tmp: tmp} do
      out = Path.join(tmp, "hello")
      run(["hello", "--out", out, "--description", "Hello plugin"])

      assert File.exists?(Path.join(out, "plugin.json"))
      assert File.exists?(Path.join(out, "README.md"))
      assert File.exists?(Path.join(out, "lib/hello.ex"))
      assert File.exists?(Path.join(out, "test/hello_test.exs"))
      assert File.exists?(Path.join(out, "schemas/.gitkeep"))
    end

    test "plugin.json has the expected manifest shape", %{tmp: tmp} do
      out = Path.join(tmp, "hello")
      run(["hello", "--out", out, "--description", "Hi", "--capabilities", "r,w,s"])

      manifest = out |> Path.join("plugin.json") |> File.read!() |> Jason.decode!()

      assert manifest["plugin_name"] == "hello"
      assert manifest["version"] == "0.1.0"
      assert manifest["description"] == "Hi"
      assert manifest["capabilities"] == ["routes", "workers", "schemas"]
    end

    test "plugin.json passes Barkpark.Plugins.Manifest.validate!/1 when available", %{tmp: tmp} do
      out = Path.join(tmp, "hello")
      run(["hello", "--out", out])

      manifest = out |> Path.join("plugin.json") |> File.read!() |> Jason.decode!()

      mod = Module.concat([:Barkpark, :Plugins, :Manifest])

      if Code.ensure_loaded?(mod) and function_exported?(mod, :validate!, 1) do
        assert apply(mod, :validate!, [manifest])
      else
        :ok
      end
    end

    test "module body uses Barkpark.Plugin", %{tmp: tmp} do
      out = Path.join(tmp, "hello")
      run(["hello", "--out", out])

      body = File.read!(Path.join(out, "lib/hello.ex"))
      assert body =~ "defmodule Hello do"
      assert body =~ "use Barkpark.Plugin"
    end

    test "--module overrides default module name", %{tmp: tmp} do
      out = Path.join(tmp, "hello")
      run(["hello", "--out", out, "--module", "MyApp.Plugins.Hello"])

      body = File.read!(Path.join(out, "lib/hello.ex"))
      assert body =~ "defmodule MyApp.Plugins.Hello do"
    end

    test "--capabilities CSV parses correctly", %{tmp: tmp} do
      out = Path.join(tmp, "hello")
      run(["hello", "--out", out, "--capabilities", "routes, workers , schemas"])

      manifest = out |> Path.join("plugin.json") |> File.read!() |> Jason.decode!()
      assert manifest["capabilities"] == ["routes", "workers", "schemas"]
    end

    test "default capabilities is empty", %{tmp: tmp} do
      out = Path.join(tmp, "hello")
      run(["hello", "--out", out])

      manifest = out |> Path.join("plugin.json") |> File.read!() |> Jason.decode!()
      assert manifest["capabilities"] == []
    end

    test "default module name derived from hyphenated slug", %{tmp: tmp} do
      out = Path.join(tmp, "out")
      run(["my-plugin", "--out", out])

      body = File.read!(Path.join(out, "lib/my-plugin.ex"))
      assert body =~ "defmodule MyPlugin do"
    end
  end

  describe "overwrite protection" do
    test "refuses to overwrite without --force", %{tmp: tmp} do
      out = Path.join(tmp, "hello")
      run(["hello", "--out", out])

      assert_raise Mix.Error, ~r/already exists/, fn ->
        run(["hello", "--out", out])
      end
    end

    test "--force overwrites existing dir", %{tmp: tmp} do
      out = Path.join(tmp, "hello")
      run(["hello", "--out", out])

      stale = Path.join(out, "stale.txt")
      File.write!(stale, "stale")

      run(["hello", "--out", out, "--force"])

      refute File.exists?(stale)
      assert File.exists?(Path.join(out, "plugin.json"))
    end
  end

  describe "compiled module smoke" do
    test "generated lib/<name>.ex compiles and exposes manifest/0", %{tmp: tmp} do
      out = Path.join(tmp, "smoke")
      run(["smoke", "--out", out])

      module_path = Path.join(out, "lib/smoke.ex")
      assert File.exists?(module_path)
      assert File.exists?(Path.join(out, "plugin.json"))

      [{mod, _bin} | _] = Code.compile_file(module_path)
      assert function_exported?(mod, :manifest, 0)

      manifest = mod.manifest()
      assert manifest["plugin_name"] == "smoke"
      assert manifest["version"] == "0.1.0"
    after
      smoke_mod = Module.concat([:Smoke])
      :code.purge(smoke_mod)
      :code.delete(smoke_mod)
    end
  end

  defp run(argv) do
    capture_io(fn -> New.run(argv) end)
  end

  defp capture_io(fun) do
    ExUnit.CaptureIO.capture_io(fun)
  end
end
