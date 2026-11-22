defmodule Barkpark.PortableDoc.SourceWallTooDeepTest do
  @moduledoc """
  The shared fixtures the editor's source-mode wall names as past the value-depth
  limit instead of running them (`test/support/fixtures/paper-editor/source_wall_too_deep.json`,
  read by `api/assets/paper-editor/src/__source_wall_fixtures.test.mjs`). Each is
  refused by `Validate` as `too_deep`, so no stored Paper holds one. A row whose doc
  turns valid fails here, and the editor's list would then be wrong.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Validate
  alias Mix.Tasks.Barkpark.PortableDoc.GenPdParity.{Limits, Pack}

  @path Path.expand("../../support/fixtures/paper-editor/source_wall_too_deep.json", __DIR__)
  @external_resource @path
  @rows @path |> File.read!() |> Jason.decode!() |> Map.fetch!("rows")

  # The doc a row names: a limit doc or edge is one block written with the pack's
  # macros; a value-depth case is a whole doc; a golden is one rendered edge, its
  # block already expanded under "input".
  defp doc(%{"file" => file, "list" => "golden", "entry" => entry}) do
    golden = Path.join(Pack.dir(), file) |> File.read!() |> Jason.decode!()
    assert golden["name"] == entry, "#{file} is not the golden of #{inspect(entry)}"
    %{"blocks" => [golden["input"]]}
  end

  defp doc(%{"file" => file, "list" => list, "entry" => entry}) do
    found =
      Path.join(Pack.dir(), file)
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!(list)
      |> Enum.find(&(&1["name"] == entry))

    assert found, "#{file} has no #{list} entry named #{inspect(entry)}"

    case list do
      list when list in ["docs", "edges"] -> %{"blocks" => [Limits.expand(found["doc"])]}
      "cases" -> found["doc"]
    end
  end

  test "the list names docs" do
    assert length(@rows) == 6
  end

  for row <- @rows do
    @row row

    test "#{row["name"]} is refused as too deep" do
      assert {:error, errors} = Validate.validate(doc(@row))
      assert Enum.any?(errors, &(&1.code == :too_deep)), inspect(Enum.map(errors, & &1.code))
    end
  end
end
