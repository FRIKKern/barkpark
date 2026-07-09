defmodule Barkpark.Quiz.CursorFrameTest do
  @moduledoc "P2 unit tests for the binary/quantized/delta cursor frame codec."
  use ExUnit.Case, async: true

  alias Barkpark.Quiz.CursorFrame

  test "quantize clamps to 0..0xFFFF and round-trips within grid resolution" do
    assert CursorFrame.quantize(0.0) == 0
    assert CursorFrame.quantize(1.0) == 0xFFFF
    assert CursorFrame.quantize(-5.0) == 0
    assert CursorFrame.quantize(9.0) == 0xFFFF

    for f <- [0.0, 0.25, 0.5, 0.7777, 1.0] do
      assert_in_delta CursorFrame.dequantize(CursorFrame.quantize(f)), f, 1.0e-4
    end
  end

  test "encode/decode round-trips a cursor map" do
    cursors = %{0 => {10, 20}, 7 => {65535, 0}, 2000 => {123, 456}}
    assert cursors |> CursorFrame.encode() |> CursorFrame.decode() == cursors
  end

  test "an empty frame is just the 2-byte count header" do
    bin = CursorFrame.encode(%{})
    assert byte_size(bin) == 2
    assert CursorFrame.decode(bin) == %{}
  end

  test "frame size is 2 + 6*n bytes" do
    cursors = Map.new(0..49, &{&1, {&1, &1}})
    assert byte_size(CursorFrame.encode(cursors)) == CursorFrame.byte_size_for(50)
    assert CursorFrame.byte_size_for(50) == 2 + 6 * 50
  end

  test "delta keeps only moved/new cursors" do
    prev = %{0 => {10, 10}, 1 => {20, 20}, 2 => {30, 30}}
    curr = %{0 => {10, 10}, 1 => {99, 20}, 2 => {30, 30}, 3 => {1, 1}}

    delta = CursorFrame.delta(prev, curr)
    assert delta == %{1 => {99, 20}, 3 => {1, 1}}
    # encodes only the changed entries
    assert byte_size(CursorFrame.encode(delta)) == CursorFrame.byte_size_for(2)
  end

  test "no-change delta is empty" do
    frame = %{0 => {1, 2}, 1 => {3, 4}}
    assert CursorFrame.delta(frame, frame) == %{}
  end
end
