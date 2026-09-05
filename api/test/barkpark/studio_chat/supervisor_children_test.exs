defmodule Barkpark.StudioChat.SupervisorChildrenTest do
  @moduledoc """
  The test-env gate on `StudioChat.BlockedSweeper`, from BOTH sides.

  The sweeper's 60s tick is a `Repo.all` from its own process, which under test
  owns no ExUnit sandbox connection — so a boot-started singleton logged an
  ownership warning on an exact 60s period for the whole `mix test` run (CI run
  33720395852). `config/test.exs` gates it off. The DANGER of that gate is that
  it silently disables the sweeper in production too, so the first test here is
  a POSITIVE CONTROL: at the DEFAULT config value (the dev/prod value — no
  `:barkpark, Barkpark.StudioChat.BlockedSweeper` key at all) the child is in
  `Supervisor.children/0`. The second test pins the test-env value.

  `AgentStateSweeper` and `FleetHub` are asserted alongside so a refactor that
  drops a child while keeping the flag honest still reds here.
  """
  use ExUnit.Case, async: false

  alias Barkpark.StudioChat.{AgentStateSweeper, BlockedSweeper, FleetHub, Supervisor}

  setup do
    prev = Application.fetch_env(:barkpark, BlockedSweeper)

    on_exit(fn ->
      case prev do
        {:ok, v} -> Application.put_env(:barkpark, BlockedSweeper, v)
        :error -> Application.delete_env(:barkpark, BlockedSweeper)
      end
    end)

    :ok
  end

  test "POSITIVE CONTROL: at the dev/prod default (key absent) the BlockedSweeper IS a child" do
    Application.delete_env(:barkpark, BlockedSweeper)

    children = Supervisor.children()

    assert BlockedSweeper in children,
           "the test-env gate has leaked into the default: prod would no longer sweep"

    assert AgentStateSweeper in children
    assert FleetHub in children
  end

  test "POSITIVE CONTROL: an explicit `enabled: true` also yields the child" do
    Application.put_env(:barkpark, BlockedSweeper, enabled: true)

    assert BlockedSweeper in Supervisor.children()
  end

  test "with `enabled: false` (the config/test.exs value) the child is absent, others stay" do
    Application.put_env(:barkpark, BlockedSweeper, enabled: false)

    children = Supervisor.children()

    refute BlockedSweeper in children
    assert AgentStateSweeper in children
    assert FleetHub in children
  end

  test "config/test.exs actually sets the gate off for this suite" do
    assert Application.get_env(:barkpark, BlockedSweeper)[:enabled] == false

    refute BlockedSweeper in Supervisor.children()
  end

  test "the boot-started singleton is NOT running in this suite" do
    refute Process.whereis(BlockedSweeper),
           "a live BlockedSweeper here means the gate is not wired into the boot child list"
  end
end
