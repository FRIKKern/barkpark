defmodule Barkpark.Plugins.Sheets.SessionRuntimeBootChildTest do
  @moduledoc """
  task-c10be8a9ad8f0145: the Sheets session supervisor is the Sheets plugin's
  own boot child, not a static child of `Barkpark.Application`. It is present
  when the plugin is loaded and absent when it is not. The kill-switch boot
  itself (no supervisor running, `Session` answering instead of raising) is
  asserted in `plugin_free_boot_test.exs`.

  `async: false`: `Barkpark.PluginEnv.run_with/2` writes global app env.
  """
  use ExUnit.Case, async: false

  @sheets_sup Barkpark.Plugins.Sheets.Supervisor

  defp boot_child_ids do
    Enum.map(Barkpark.Plugins.Registry.collect_workers(%{phase: :boot}), fn spec ->
      Supervisor.child_spec(spec, []).id
    end)
  end

  test "register_workers/1 contributes the session supervisor as a supervisor child" do
    assert [%{id: @sheets_sup, type: :supervisor, start: {@sheets_sup, :start_link, _}}] =
             Barkpark.Plugins.Sheets.register_workers(%{phase: :boot})
  end

  test "the boot collector folds it in with Sheets loaded, and NOT with Sheets absent" do
    Barkpark.PluginEnv.run_with([Barkpark.Plugins.Sheets], fn ->
      assert @sheets_sup in boot_child_ids()
    end)

    # Another plugin loaded, Sheets not: the supervisor is not collected.
    Barkpark.PluginEnv.run_with([Barkpark.Plugins.Tasks], fn ->
      refute @sheets_sup in boot_child_ids()
    end)

    Barkpark.PluginEnv.run_with([], fn ->
      refute @sheets_sup in boot_child_ids()
    end)
  end

  test "the host's static child list does not name it" do
    ids =
      []
      |> Barkpark.Application.child_specs([repo: Barkpark.Repo], [], [])
      |> Enum.map(&Supervisor.child_spec(&1, []).id)

    refute @sheets_sup in ids
  end

  test "in the running app (every plugin loaded) it runs under the plugin tier, after PubSub" do
    sup_pid = Process.whereis(@sheets_sup)
    assert is_pid(sup_pid)
    assert Barkpark.Plugins.Sheets.Session.runtime_started?()

    plugin_tier = Supervisor.which_children(Barkpark.Plugins.Supervisor)
    assert Enum.any?(plugin_tier, fn {id, pid, _, _} -> id == @sheets_sup and pid == sup_pid end)

    top = Supervisor.which_children(Barkpark.Supervisor)
    refute Enum.any?(top, fn {id, _, _, _} -> id == @sheets_sup end)

    # `which_children/1` lists children newest first; PubSub must be OLDER than
    # the plugin tier, i.e. appear AFTER it in this list.
    top_ids = Enum.map(top, fn {id, _, _, _} -> id end)
    pubsub_at = Enum.find_index(top_ids, &(&1 == Phoenix.PubSub.Supervisor))
    plugins_at = Enum.find_index(top_ids, &(&1 == Barkpark.Plugins.Supervisor))
    assert is_integer(pubsub_at) and is_integer(plugins_at)
    assert pubsub_at > plugins_at
  end
end
