defmodule Barkpark.PortableDoc.PatchFoldRowsTest do
  @moduledoc """
  The rows that tie the editor's patch.ex mirror to `Patch`
  (`test/support/fixtures/paper-editor/patch_fold_rows.json`): each row's ops,
  folded onto `before`, give `after`. The editor runs the same rows against
  `api/assets/paper-editor/src/canvas/patch-fold.js`
  (`src/canvas/__patch_fold_rows.test.mjs`), which the source-mode wall folds a
  save with, so the two folds cannot drift apart on these cases.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Patch

  @path Path.expand("../../support/fixtures/paper-editor/patch_fold_rows.json", __DIR__)
  @external_resource @path
  @rows @path |> File.read!() |> Jason.decode!() |> Map.fetch!("rows")

  test "every row carries before, ops and after" do
    assert @rows != []

    for row <- @rows do
      assert is_list(row["before"]) and is_list(row["ops"]) and is_list(row["after"]),
             "row #{inspect(row["row"])} has no result"
    end
  end

  for row <- @rows do
    @row row

    test "#{row["row"]}" do
      assert {:ok, blocks} = Patch.apply_patches(@row["before"], @row["ops"])
      assert blocks == @row["after"]
    end
  end
end
