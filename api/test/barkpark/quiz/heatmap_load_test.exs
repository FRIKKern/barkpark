defmodule Barkpark.Quiz.HeatmapLoadTest do
  @moduledoc """
  P5 hq-p5-load: 10k cursors prove the heatmap path is O(1) — the frame stays a
  constant 2048 bytes regardless of crowd size, and encoding stays fast.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Quiz.Heatmap

  test "10k cursors encode to a fixed 2048-byte frame, fast, sum preserved" do
    cursors = Map.new(0..9_999, &{&1, {rem(&1 * 131, 65_535), rem(&1 * 251, 65_535)}})

    {us, bin} = :timer.tc(fn -> Heatmap.encode(cursors) end)

    assert byte_size(bin) == Heatmap.byte_size_for(Heatmap.grid())
    assert byte_size(bin) == 2048
    assert bin |> Heatmap.decode() |> Enum.sum() == 10_000
    assert us < 1_000_000, "encode took #{us}µs (expected < 1s)"
  end

  test "frame size is identical for 100 vs 10k cursors (O(1))" do
    small = Heatmap.encode(Map.new(0..99, &{&1, {&1 * 100, &1 * 100}}))
    big = Heatmap.encode(Map.new(0..9_999, &{&1, {rem(&1 * 7, 65_535), rem(&1 * 13, 65_535)}}))
    assert byte_size(small) == byte_size(big)
  end
end
