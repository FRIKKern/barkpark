defmodule Barkpark.Quiz.CursorFrame do
  @moduledoc """
  P2 cursor fan-out wire codec (see `/papers/hyperquiz-realtime-protocol`).

  The room batches all cursor positions and broadcasts ONE frame per ~15Hz tick
  (turning O(N²) messages into O(N)); this module is the binary, quantized,
  delta-encoded representation of that frame — the individual-cursor path
  (≤ a few hundred players; the heatmap path for 10k+ is P5).

  ## Format

  Positions are normalized floats in `0.0..1.0` (resolution-independent — the
  client scales to its canvas). Each is quantized to a 16-bit grid (`0..65535`,
  ~sub-pixel on any real display) so a position is 2 bytes, not an 8-byte float.

  A frame is:

      <<count::16, (entry × count)>>      entry = <<idx::16, qx::16, qy::16>>

  i.e. 2 header bytes + 6 bytes per cursor. `idx` is the player's small integer
  slot in the room (assigned on join), not the UUID — keeping entries fixed-width
  and tiny. `delta/2` keeps only cursors whose quantized position changed since
  the last frame, so a still cursor costs nothing on the wire.
  """

  @max 0xFFFF

  @type idx :: non_neg_integer()
  @type qcoord :: 0..0xFFFF
  @type qpos :: {qcoord(), qcoord()}
  @typedoc "cursor slot → quantized {x, y}"
  @type cursors :: %{optional(idx()) => qpos()}

  @doc "Quantize a normalized `0.0..1.0` coordinate to the 16-bit grid (clamped)."
  @spec quantize(number()) :: qcoord()
  def quantize(f) when is_number(f) do
    f
    |> max(0.0)
    |> min(1.0)
    |> Kernel.*(@max)
    |> round()
  end

  @doc "Inverse of `quantize/1` — back to a `0.0..1.0` float."
  @spec dequantize(qcoord()) :: float()
  def dequantize(q) when is_integer(q) and q >= 0 and q <= @max, do: q / @max

  @doc "Encode a cursor map to a binary frame."
  @spec encode(cursors()) :: binary()
  def encode(cursors) when is_map(cursors) do
    body =
      for {idx, {x, y}} <- cursors, into: <<>> do
        <<idx::16, x::16, y::16>>
      end

    <<map_size(cursors)::16, body::binary>>
  end

  @doc "Decode a binary frame back to a cursor map."
  @spec decode(binary()) :: cursors()
  def decode(<<count::16, rest::binary>>), do: decode_entries(rest, count, %{})

  defp decode_entries(_rest, 0, acc), do: acc

  defp decode_entries(<<idx::16, x::16, y::16, rest::binary>>, n, acc),
    do: decode_entries(rest, n - 1, Map.put(acc, idx, {x, y}))

  @doc """
  Delta against the previous frame: only cursors whose quantized position
  changed (new cursors included; a still cursor is omitted). Removals are not
  encoded here — the room signals a leave out-of-band (player_left).
  """
  @spec delta(cursors(), cursors()) :: cursors()
  def delta(prev, curr) when is_map(prev) and is_map(curr) do
    for {idx, pos} <- curr, Map.get(prev, idx) != pos, into: %{}, do: {idx, pos}
  end

  @doc "Byte size of a frame carrying `n` cursors (2 header + 6/cursor)."
  @spec byte_size_for(non_neg_integer()) :: pos_integer()
  def byte_size_for(n) when is_integer(n) and n >= 0, do: 2 + 6 * n
end
