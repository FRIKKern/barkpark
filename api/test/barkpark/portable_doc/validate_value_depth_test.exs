defmodule Barkpark.PortableDoc.ValidateValueDepthTest do
  @moduledoc """
  The value-depth limit: any JSON value nests at most `max_value_depth/0`
  (1000) JSON levels from the doc root, `too_deep` at the first path past it,
  while blocks keep nesting at most `max_depth/0` (100). The shared case is the
  golden pack's `limits/value-too-deep.json`, which `@portable-doc/validate`
  runs too.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.Validate
  alias Mix.Tasks.Barkpark.PortableDoc.GenPdParity.{Limits, Pack}

  @fixture Path.join(Pack.dir(), "limits/value-too-deep.json")

  # The doc is level 1, blocks 2, the chart 3, series 4, the item 5, x 6.
  defp chart_at(total) do
    x = Enum.reduce(6..(total - 1)//1, [], fn _, inner -> [inner] end)

    %{
      "blocks" => [
        %{"type" => "chart", "kind" => "line", "series" => [%{"label" => "s", "x" => x}]}
      ]
    }
  end

  defp first_past, do: "/blocks/0/series/0/x" <> String.duplicate("/0", 1000 + 1 - 6)

  defp codes({:error, errors}), do: Enum.map(errors, & &1.code)
  defp codes(:ok), do: []

  test "the limits are 1000 JSON levels for values and 100 for blocks" do
    assert Validate.max_value_depth() == 1000
    assert Validate.max_depth() == 100
  end

  test "each value-too-deep.json case gives exactly its expected errors" do
    fixture = @fixture |> File.read!() |> Jason.decode!()
    assert fixture["maxValueDepth"] == 1000
    assert length(fixture["cases"]) == 2

    for %{"name" => name, "doc" => doc, "expect" => expect} <- fixture["cases"] do
      want =
        case expect do
          [] ->
            :ok

          errors ->
            {:error, Enum.map(errors, &%{code: String.to_atom(&1["code"]), path: &1["path"]})}
        end

      assert Validate.validate(doc) == want, name
    end
  end

  test "a value 8,000 levels deep is one too_deep, without a crash" do
    assert Validate.validate(chart_at(1000)) == :ok
    assert Validate.validate(chart_at(8000)) == {:error, [%{code: :too_deep, path: first_past()}]}

    em =
      Enum.reduce(1..8000, %{"type" => "text", "value" => "x"}, fn _, node ->
        %{"type" => "em", "children" => [node]}
      end)

    assert codes(Validate.validate(%{"blocks" => [%{"type" => "paragraph", "content" => [em]}]})) ==
             [:too_deep]
  end

  test "a bare blocks array is level 1" do
    bare = fn n ->
      x = Enum.reduce(1..(n - 1)//1, [], fn _, inner -> [inner] end)
      [%{"type" => "chart", "series" => [%{"x" => x}]}]
    end

    assert Validate.validate(bare.(1000 - 4)) == :ok
    assert codes(Validate.validate(bare.(1000 - 3))) == [:too_deep]
  end

  test "a block stopped at the block depth is not counted again" do
    deep =
      Enum.reduce(1..150, %{"type" => "divider"}, fn _, inner ->
        %{"type" => "section", "blocks" => [inner]}
      end)

    assert {:error, errors} = Validate.validate(%{"blocks" => [deep]})
    assert Enum.map(errors, & &1.code) == [:too_deep]
  end

  # The renderer stops nesting marks at `max_depth/0` (100). The docs at that
  # limit are the mark edges, and they validate; `nested strong` (20000 marks)
  # is a render stress doc, refused like `@portable-doc/validate` refuses it.
  test "every mark edge at the renderer's mark-nesting limit validates" do
    marks = ~w(strong em link marks) ++ ["table cell marks"]

    at =
      for {name, block} <- Limits.edges(),
          name in Enum.map(marks, &(&1 <> " at the depth limit")),
          do: {name, block}

    assert length(at) == 5

    for {name, block} <- at do
      assert Validate.validate(%{"blocks" => [block]}) == :ok, name
    end
  end

  test "check_top_block reports a block's value-depth error after its own" do
    %{"blocks" => [chart]} = chart_at(1001)
    assert {[%{code: :too_deep, path: path}], []} = Validate.check_top_block(chart, 0)
    assert path == first_past()
  end
end
