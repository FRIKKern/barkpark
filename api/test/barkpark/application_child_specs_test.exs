defmodule Barkpark.ApplicationChildSpecsTest do
  @moduledoc """
  Structural test for `Barkpark.Application.child_specs/4` (task
  task-d328fb91ff55b743): the volatile/subsystem tiers are wrapped in their OWN
  supervisors (not flat under Barkpark.Supervisor), and the boot ORDER
  invariants the old flat list encoded are preserved.
  """
  use ExUnit.Case, async: true

  defp specs(plugin_children) do
    Barkpark.Application.child_specs(plugin_children, [repo: Barkpark.Repo], [], [])
  end

  # Reduce a child spec to its identifying module/key.
  defp key(mod) when is_atom(mod), do: mod
  defp key(tuple) when is_tuple(tuple), do: elem(tuple, 0)
  defp key(%{start: {mod, _, _}}), do: mod

  defp keys(specs), do: Enum.map(specs, &key/1)

  defp index(specs, k), do: Enum.find_index(keys(specs), &(&1 == k))

  test "root supervisor waits for the synchronous bootstrap" do
    src = File.read!("lib/barkpark/application.ex")

    assert src =~ "timeout: :infinity",
           "the root Supervisor.start_link includes SchemaBootstrap and must not retain " <>
             "GenServer's five-second start deadline"
  end

  test "plugin_children are wrapped under Barkpark.Plugins.Supervisor, not flat" do
    plugin = [{FakePluginWorker, arg: 1}]
    specs = specs(plugin)

    # The volatile plugin tier is its own supervisor carrying the plugin specs...
    assert {Barkpark.Plugins.Supervisor, ^plugin} =
             Enum.find(specs, &match?({Barkpark.Plugins.Supervisor, _}, &1))

    # ...and the raw plugin worker is NOT a direct top-level child.
    refute {FakePluginWorker, arg: 1} in specs
    refute FakePluginWorker in keys(specs)
  end

  test "each volatile/subsystem tier is a separate intermediate supervisor" do
    ks = keys(specs([]))

    assert Barkpark.Plugins.Supervisor in ks
    assert Barkpark.Plugins.Indx.Supervisor in ks
    assert Barkpark.Plugins.Sheets.Supervisor in ks
    assert Barkpark.StudioChat.Supervisor in ks

    # The formerly-flat leaves are now NESTED (owned by the tier supervisors),
    # not direct children of Barkpark.Supervisor.
    refute Barkpark.Plugins.Indx.Auth in ks
    refute Barkpark.Plugins.Indx.Monitor in ks
    refute Barkpark.Plugins.Indx.Recovery in ks
    refute Barkpark.Plugins.Sheets.Session.ReplayRing in ks
  end

  test "boot-order invariants preserved" do
    specs = specs([{FakePluginWorker, []}])

    # Repo before everything that queries it.
    assert index(specs, Barkpark.Repo) < index(specs, Barkpark.Plugins.Supervisor)
    assert index(specs, Barkpark.Repo) < index(specs, Barkpark.SchemaBootstrap)
    assert index(specs, Barkpark.Repo) < index(specs, Oban)

    # Registry before the plugin worker tier.
    assert index(specs, Barkpark.Plugins.Registry) < index(specs, Barkpark.Plugins.Supervisor)

    # SchemaBootstrap after Repo/Registry and BEFORE Oban (no job against an
    # unregistered schema).
    assert index(specs, Barkpark.Plugins.Registry) < index(specs, Barkpark.SchemaBootstrap)
    assert index(specs, Barkpark.SchemaBootstrap) < index(specs, Oban)

    # Indx subsystem before Oban (its :indx queue jobs call Auth.token/0).
    assert index(specs, Barkpark.Plugins.Indx.Supervisor) < index(specs, Oban)

    # PubSub before the Sheets/StudioChat tiers and the Endpoint.
    assert index(specs, Phoenix.PubSub) < index(specs, Barkpark.Plugins.Sheets.Supervisor)
    assert index(specs, Phoenix.PubSub) < index(specs, Barkpark.StudioChat.Supervisor)
    assert index(specs, Phoenix.PubSub) < index(specs, BarkparkWeb.Endpoint)

    # Endpoint is last.
    assert List.last(keys(specs)) == BarkparkWeb.Endpoint
  end

  test "fresh-install invariant: empty plugin tier still yields a wrapper, Endpoint last" do
    specs = specs([])

    assert {Barkpark.Plugins.Supervisor, []} in specs
    assert List.last(keys(specs)) == BarkparkWeb.Endpoint
  end
end
