defmodule Barkpark.PortableDoc.RenderSlotDepthTest do
  @moduledoc """
  The deepest shapes tabs, steps and list items reach, on the fixture Go reads too
  (`internal/pdrender/limits_test.go`, `TestSlotDepthFixture`): the bounds there
  must equal Elixir's limits, every block slot path must fit the fixture's slot
  levels, and each case must show the word and the notice as the fixture says.
  task-11bbe4b4ae8c85f4.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.{Render, Validate}
  alias Barkpark.PortableDoc.Render.InlineDepth
  alias Mix.Tasks.Barkpark.PortableDoc.GenPdParity.Limits

  @path Path.expand("../../support/fixtures/portable-doc-slot-depth.json", __DIR__)
  @external_resource @path
  @fixture @path |> File.read!() |> Jason.decode!()
  @bounds @fixture["bounds"]

  test "the bounds equal Elixir's limits and the Go sum" do
    assert @bounds["max_nest_depth"] == Validate.max_depth()
    assert @bounds["max_word_depth"] == InlineDepth.max_word_depth()

    longest =
      Render.block_slots() |> Map.values() |> Enum.concat() |> Enum.map(&length/1) |> Enum.max()

    assert @bounds["slot_path_levels"] == longest

    assert @bounds["go_max_json_depth"] ==
             2 * @bounds["max_word_depth"] +
               @bounds["slot_path_levels"] * @bounds["max_nest_depth"] +
               16

    assert @bounds["editor_max_carry_depth"] ==
             2 * @bounds["max_word_depth"] + 2 * @bounds["max_nest_depth"] + 16
  end

  test "the fixture holds tabs, steps and list, three cases each" do
    assert length(@fixture["cases"]) == 9
  end

  for row <- @fixture["cases"] do
    @row row

    test "#{row["name"]}" do
      html = Render.render_block(Limits.expand(@row["doc"]), %{style: :article})
      words = html |> String.replace(~r/<[^>]*>/, " ") |> String.split()
      text = Enum.join(words, " ")

      assert "leaf" in words == @row["leaf"], String.slice(text, 0, 300)

      assert String.contains?(text, InlineDepth.notice()) == @row["notice"],
             String.slice(text, 0, 300)

      if @row["leaf"] and @row["notice"] do
        assert text =~ "leaf " <> InlineDepth.notice(), String.slice(text, 0, 300)
      end
    end
  end
end
