defmodule Barkpark.Content.DiffMatchPatchMakeTest do
  @moduledoc """
  `DiffMatchPatch.Make` against @sanity/diff-match-patch 3.2 (task-881f16e32fffbe9a):
  the vectors hold the library's `stringifyPatches(makePatches(base, mine))`
  and whether `applyPatches` placed every hunk on `theirs`, which is where
  TanStack's `merge3` gives null. Made with node from barkpark-studio's copy
  of the library: the reviewer's 24 merge inputs, the P8 cases and random
  edits over text with æ, ø and an emoji in it.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Content.DiffMatchPatch
  alias Barkpark.Content.DiffMatchPatch.Make

  @vectors "test/fixtures/diff_match_patch/make_vectors.json" |> File.read!() |> Jason.decode!()

  defp units(s) do
    bin = :unicode.characters_to_binary(s, :utf8, {:utf16, :big})
    for <<u::16 <- bin>>, do: u
  end

  test "the patch text is the library's, vector by vector" do
    for %{"base" => base, "mine" => mine, "patch" => patch} <- @vectors do
      assert Make.text(units(base), units(mine)) == patch, inspect({base, mine})
    end
  end

  test "applied to theirs, every hunk is placed where the library placed it" do
    for %{"base" => base, "mine" => mine, "theirs" => theirs, "placed" => placed} <- @vectors do
      {:ok, _text, applied} = DiffMatchPatch.apply(Make.text(units(base), units(mine)), theirs)
      assert Enum.all?(applied) == placed, inspect({base, mine, theirs})
    end
  end

  test "an empty diff makes no patch" do
    assert Make.text(units("same"), units("same")) == ""
  end
end
