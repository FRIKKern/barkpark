defmodule Mix.Tasks.Barkpark.Gen.PluginTest do
  @moduledoc """
  `mix barkpark.gen.plugin` is DEPRECATED — it now prints a deprecation
  notice and delegates to `mix barkpark.plugin.new`, which emits a valid
  manifest-based plugin under `priv/plugins/<name>/`. These tests assert
  both halves: the notice is shown AND the delegation produces a real
  `plugin.json`.
  """
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

  describe "run/1 (deprecated → delegates to barkpark.plugin.new)" do
    test "prints a deprecation notice", %{tmp: _tmp} do
      Plugin.run(["vlie"])

      messages = drain_messages()

      assert Enum.any?(messages, &String.contains?(&1, "DEPRECATED")),
             "expected a deprecation notice; got: #{inspect(messages)}"

      assert Enum.any?(messages, &String.contains?(&1, "barkpark.plugin.new")),
             "expected the notice to point at barkpark.plugin.new; got: #{inspect(messages)}"
    end

    test "delegates and produces a valid manifest-based plugin", %{tmp: tmp} do
      Plugin.run(["vlie"])

      manifest = Path.join(tmp, "priv/plugins/vlie/plugin.json")
      assert File.exists?(manifest), "expected #{manifest} to exist after delegation"

      parsed = Jason.decode!(File.read!(manifest))
      assert parsed["plugin_name"] == "vlie"

      # The delegated generator also writes the entry module into the
      # compiled tree and a README under the priv dir.
      assert File.exists?(Path.join(tmp, "lib/barkpark/plugins/vlie.ex"))
      assert File.exists?(Path.join(tmp, "priv/plugins/vlie/README.md"))
    end

    test "forwards options through to barkpark.plugin.new", %{tmp: tmp} do
      Plugin.run(["vlie", "--description", "Forwarded desc", "--capabilities", "schemas"])

      manifest = Path.join(tmp, "priv/plugins/vlie/plugin.json")
      parsed = Jason.decode!(File.read!(manifest))

      assert parsed["description"] == "Forwarded desc"
      assert "schemas" in parsed["capabilities"]
    end

    test "invalid name still surfaces an error from the delegate" do
      assert_raise Mix.Error, fn -> Plugin.run(["bad!name"]) end
    end

    test "empty argv surfaces the delegate's required-name error" do
      assert_raise Mix.Error, fn -> Plugin.run([]) end
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
