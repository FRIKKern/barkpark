defmodule Mix.Tasks.Barkpark.Gen.PluginTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Barkpark.Gen.Plugin

  setup do
    prev_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    prev_cwd = File.cwd!()

    tmp =
      Path.join(System.tmp_dir!(), "barkpark_gen_plugin_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    File.cd!(tmp)

    on_exit(fn ->
      File.cd!(prev_cwd)
      File.rm_rf!(tmp)
      Mix.shell(prev_shell)
    end)

    {:ok, tmp: tmp}
  end

  describe "normalize_name/1" do
    test "PascalCase stays PascalCase, snake form is derived" do
      assert {"Vlie", "vlie"} = Plugin.normalize_name("Vlie")
    end

    test "snake_case is accepted and camelised back" do
      assert {"Vlie", "vlie"} = Plugin.normalize_name("vlie")
    end

    test "multi-word PascalCase round-trips through underscore" do
      assert {"FooBar", "foo_bar"} = Plugin.normalize_name("FooBar")
    end
  end

  describe "run/1" do
    test "creates all five files with the right contents", %{tmp: tmp} do
      Plugin.run(["Vlie", "--force"])

      entry = Path.join(tmp, "lib/barkpark/plugins/vlie.ex")
      actions = Path.join(tmp, "lib/barkpark/plugins/vlie/actions.ex")
      client = Path.join(tmp, "lib/barkpark/plugins/vlie/client.ex")
      actions_test = Path.join(tmp, "test/barkpark/plugins/vlie/actions_test.exs")
      client_test = Path.join(tmp, "test/barkpark/plugins/vlie/client_test.exs")

      for path <- [entry, actions, client, actions_test, client_test] do
        assert File.exists?(path), "expected #{path} to exist"
      end

      entry_src = File.read!(entry)
      assert entry_src =~ "defmodule Barkpark.Plugins.Vlie do"
      assert entry_src =~ "def register_schemas(dataset \\\\ \"production\")"
      assert Code.string_to_quoted!(entry_src)

      actions_src = File.read!(actions)
      assert actions_src =~ "defmodule Barkpark.Plugins.Vlie.Actions do"
      assert actions_src =~ "def example_action(doc_id, dataset, mode \\\\ :dryrun)"
      assert Code.string_to_quoted!(actions_src)

      client_src = File.read!(client)
      assert client_src =~ "defmodule Barkpark.Plugins.Vlie.Client do"
      assert client_src =~ "def fetch_token"
      assert client_src =~ "def submit("
      assert Code.string_to_quoted!(client_src)

      assert File.read!(actions_test) =~ "defmodule Barkpark.Plugins.Vlie.ActionsTest do"
      assert Code.string_to_quoted!(File.read!(actions_test))
      assert File.read!(client_test) =~ "defmodule Barkpark.Plugins.Vlie.ClientTest do"
      assert Code.string_to_quoted!(File.read!(client_test))
    end

    test "--no-test skips the two test files", %{tmp: tmp} do
      Plugin.run(["Vlie", "--no-test", "--force"])

      assert File.exists?(Path.join(tmp, "lib/barkpark/plugins/vlie.ex"))
      assert File.exists?(Path.join(tmp, "lib/barkpark/plugins/vlie/actions.ex"))
      assert File.exists?(Path.join(tmp, "lib/barkpark/plugins/vlie/client.ex"))

      refute File.exists?(Path.join(tmp, "test/barkpark/plugins/vlie/actions_test.exs"))
      refute File.exists?(Path.join(tmp, "test/barkpark/plugins/vlie/client_test.exs"))
    end

    test "snake_case input produces PascalCase module names", %{tmp: tmp} do
      Plugin.run(["foo_bar", "--no-test", "--force"])

      entry = Path.join(tmp, "lib/barkpark/plugins/foo_bar.ex")
      assert File.exists?(entry)
      src = File.read!(entry)
      assert src =~ "defmodule Barkpark.Plugins.FooBar do"
    end

    test "emits Next steps banner", %{tmp: _tmp} do
      Plugin.run(["Vlie", "--no-test", "--force"])

      messages = drain_messages()
      assert Enum.any?(messages, &String.contains?(&1, ~s(Creating plugin scaffold for "Vlie")))
      assert Enum.any?(messages, &String.contains?(&1, "Next steps:"))
      assert Enum.any?(messages, &String.contains?(&1, "Barkpark.Plugins.Vlie"))
    end

    test "rejects invalid name", %{tmp: _tmp} do
      assert catch_exit(Plugin.run(["bad!name"])) == {:shutdown, 1}
    end

    test "rejects empty argv" do
      assert catch_exit(Plugin.run([])) == {:shutdown, 1}
    end
  end

  defp drain_messages do
    drain_messages([])
  end

  defp drain_messages(acc) do
    receive do
      {:mix_shell, _, [msg]} -> drain_messages([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
