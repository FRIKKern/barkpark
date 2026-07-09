defmodule Barkpark.Quiz.HeatmapTest do
  @moduledoc "P5 hq-p5-heatmap: fixed-size O(1) occupancy-grid encoder."
  use ExUnit.Case, async: true

  alias Barkpark.Quiz.Heatmap

  test "frame is fixed-size regardless of cursor count (O(1))" do
    g = Heatmap.grid()
    small = Heatmap.encode(%{0 => {100, 100}})
    big = Heatmap.encode(Map.new(0..9_999, &{&1, {rem(&1 * 7, 65_535), rem(&1 * 13, 65_535)}}))
    assert byte_size(small) == Heatmap.byte_size_for(g)
    assert byte_size(big) == Heatmap.byte_size_for(g)
    assert byte_size(small) == byte_size(big)
  end

  test "counts sum to the number of cursors" do
    cursors = Map.new(0..499, &{&1, {rem(&1 * 131, 65_535), rem(&1 * 251, 65_535)}})
    assert cursors |> Heatmap.encode() |> Heatmap.decode() |> Enum.sum() == 500
  end

  test "empty input is all zeros, still fixed-size" do
    bin = Heatmap.encode(%{})
    assert byte_size(bin) == Heatmap.byte_size_for(Heatmap.grid())
    assert bin |> Heatmap.decode() |> Enum.sum() == 0
  end

  test "corner positions land in the first and last cells" do
    g = Heatmap.grid()
    counts = %{0 => {0, 0}, 1 => {65_535, 65_535}} |> Heatmap.encode() |> Heatmap.decode()
    assert Enum.at(counts, 0) == 1
    assert Enum.at(counts, g * g - 1) == 1
  end

  test "co-located cursors stack in one cell" do
    counts =
      %{0 => {500, 500}, 1 => {510, 505}, 2 => {490, 495}} |> Heatmap.encode() |> Heatmap.decode()

    assert Enum.max(counts) == 3
    assert Enum.sum(counts) == 3
  end
end
