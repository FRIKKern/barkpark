defmodule Barkpark.Plugins.RunStatusTest do
  @moduledoc """
  Smoke test for the in-memory plugin run-status tracker
  (Task barkpark-otv). Exercises `record/3`, `get/1`, `all/0`, and the
  `reset/0` cleanup helper.

  Singleton GenServer registered under the module name, so we reset
  between tests instead of starting per-test instances.
  """

  use ExUnit.Case, async: false

  alias Barkpark.Plugins.RunStatus

  setup do
    RunStatus.reset()
    :ok
  end

  test "fresh state — get/1 returns empty map, all/0 returns empty map" do
    assert RunStatus.get("anything") == %{}
    assert RunStatus.all() == %{}
  end

  test "record/3 stores the most recent entry per (plugin, kind)" do
    :ok = RunStatus.record(:bootstrap, "onixedit", {:ok, 1})
    entry = RunStatus.get("onixedit")

    assert Map.has_key?(entry, :bootstrap)
    assert entry.bootstrap.result == {:ok, 1}
    assert %DateTime{} = entry.bootstrap.at

    # Overwrite — same key gets the latest value.
    :ok = RunStatus.record(:bootstrap, "onixedit", {:error, :boom})
    assert RunStatus.get("onixedit").bootstrap.result == {:error, :boom}
  end

  test "record/3 keeps :bootstrap and :seed as separate entries" do
    :ok = RunStatus.record(:bootstrap, "p1", {:ok, 1})
    :ok = RunStatus.record(:seed, "p1", :ok)

    entry = RunStatus.get("p1")
    assert entry.bootstrap.result == {:ok, 1}
    assert entry.seed.result == :ok
  end

  test "all/0 returns a map keyed by plugin name" do
    :ok = RunStatus.record(:bootstrap, "p1", {:ok, 1})
    :ok = RunStatus.record(:seed, "p2", :ok)

    snapshot = RunStatus.all()
    assert Map.has_key?(snapshot, "p1")
    assert Map.has_key?(snapshot, "p2")
    assert snapshot["p1"].bootstrap.result == {:ok, 1}
    assert snapshot["p2"].seed.result == :ok
  end

  test "reset/0 clears every entry" do
    :ok = RunStatus.record(:bootstrap, "p1", {:ok, 1})
    refute RunStatus.all() == %{}

    :ok = RunStatus.reset()
    assert RunStatus.all() == %{}
  end
end
