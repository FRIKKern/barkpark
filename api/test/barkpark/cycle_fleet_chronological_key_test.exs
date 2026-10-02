defmodule Barkpark.CycleFleetChronologicalKeyTest do
  @moduledoc """
  task-0284692b2db7f02e: `CycleFleet` ordered quarantines and assignment
  attributions with `Enum.sort_by(&{&1.inserted_at, &1.id})`. A `%DateTime{}`
  inside a tuple compares STRUCTURALLY: map keys order alphabetically, so `day`
  is compared before `month`, and 2026-09-24 sorted AFTER 2026-10-01. Every
  ordering across a month boundary was wrong.
  """
  use ExUnit.Case, async: true

  alias Barkpark.CycleFleet

  @sep ~U[2026-09-24 00:10:38.000000Z]
  @oct ~U[2026-10-01 00:10:38.000000Z]

  test "the structural tuple order is wrong across a month boundary (the bug, pinned)" do
    rows = [%{inserted_at: @oct, id: "b"}, %{inserted_at: @sep, id: "a"}]
    assert Enum.map(Enum.sort_by(rows, &{&1.inserted_at, &1.id}), & &1.id) == ["b", "a"]
  end

  test "chronological_key orders oldest-first across a month boundary" do
    rows = [%{inserted_at: @oct, id: "b"}, %{inserted_at: @sep, id: "a"}]
    assert Enum.map(Enum.sort_by(rows, &CycleFleet.chronological_key/1), & &1.id) == ["a", "b"]
  end

  test "equal timestamps fall back to id" do
    rows = [%{inserted_at: @sep, id: "z"}, %{inserted_at: @sep, id: "a"}]
    assert Enum.map(Enum.sort_by(rows, &CycleFleet.chronological_key/1), & &1.id) == ["a", "z"]
  end
end
