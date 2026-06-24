defmodule Barkpark.Plugins.Registry.DiscoveryTest do
  use ExUnit.Case, async: true

  alias Barkpark.Plugins.Registry.Discovery

  @fixture_root Path.expand("../../../support/fixtures/plugins", __DIR__)

  describe "resolve_module/1" do
    test "prefers explicit 'module' key over plugin_name derivation" do
      assert {:ok, Barkpark.Plugins.Hello} =
               Discovery.resolve_module(%{
                 "module" => "Barkpark.Plugins.Hello",
                 "plugin_name" => "ignored"
               })
    end

    test "derives module from plugin_name using PascalCase" do
      assert {:ok, Barkpark.Plugins.OnixEdit} =
               Discovery.resolve_module(%{"plugin_name" => "onix-edit"})
    end

    test "derives module from underscore plugin_name" do
      assert {:ok, Barkpark.Plugins.MyPlugin} =
               Discovery.resolve_module(%{"plugin_name" => "my_plugin"})
    end

    test "returns error when neither key is present" do
      assert {:error, :no_plugin_name} = Discovery.resolve_module(%{"version" => "1.0.0"})
    end

    test "returns error for empty plugin_name" do
      assert {:error, :no_plugin_name} = Discovery.resolve_module(%{"plugin_name" => ""})
    end

    test "returns error for empty module string" do
      assert {:error, :no_plugin_name} = Discovery.resolve_module(%{"module" => ""})
    end
  end

  describe "plugin_dirs_in/1" do
    test "returns subdirectories containing plugin.json" do
      dirs = Discovery.plugin_dirs_in(@fixture_root)

      assert is_list(dirs)
      assert length(dirs) >= 1

      hello_dir = Path.join(@fixture_root, "hello")
      assert hello_dir in dirs
    end

    test "returns empty list for a non-existent root" do
      assert [] = Discovery.plugin_dirs_in("/this/path/does/not/exist/ever")
    end

    test "returns empty list for a root with no plugin.json subdirs" do
      # Use a temp dir with an empty subdir — no plugin.json present
      tmp = System.tmp_dir!()
      subdir = Path.join(tmp, "no_manifest_#{System.unique_integer([:positive])}")
      File.mkdir_p!(subdir)
      on_exit(fn -> File.rm_rf(subdir) end)

      assert [] = Discovery.plugin_dirs_in(tmp |> Path.dirname() |> then(fn _ -> subdir end))
    end
  end
end
