defmodule Barkpark.Quiz.Heatmap do
  @moduledoc """
  P5 aggregate crowd-density encoder (`/papers/hyperquiz-scaling`). Buckets every
  cursor into a fixed `@grid x @grid` occupancy grid and encodes it as a
  FIXED-SIZE binary (one u16 count per cell). The payload size is constant
  regardless of player count — `O(1)`, not the `O(N²)` of individual cursors —
  so it scales to 10k+ players (the crossover above the individual-cursor
  threshold; see `Barkpark.Quiz.Room`).

  Input positions are the same int16-quantized coords as `CursorFrame`
  (`0..65535`). Wire format: `@grid*@grid` consecutive u16 cells, row-major
  (`cell = cy*grid + cx`). Decoded client-side into a density cloud.
  """

  @grid 32
  @qmax 65_536

  @doc "The grid dimension (cells per side)."
  @spec grid() :: pos_integer()
  def grid, do: @grid

  @doc "Byte size of a frame for a `grid`×`grid` heatmap (constant: 2 bytes/cell)."
  @spec byte_size_for(pos_integer()) :: pos_integer()
  def byte_size_for(grid \\ @grid), do: grid * grid * 2

  @doc "Encode quantized cursors (`%{idx => {qx, qy}}`) into a fixed-size grid binary."
  @spec encode(map(), pos_integer()) :: binary()
  def encode(cursors, grid \\ @grid) when is_map(cursors) do
    counts =
      Enum.reduce(cursors, %{}, fn {_idx, {qx, qy}}, acc ->
        Map.update(acc, cell_index(qx, qy, grid), 1, &(&1 + 1))
      end)

    for cell <- 0..(grid * grid - 1),
        into: <<>>,
        do: <<min(Map.get(counts, cell, 0), 0xFFFF)::16>>
  end

  @doc "Decode a heatmap binary into a flat list of `grid*grid` cell counts (row-major)."
  @spec decode(binary()) :: [non_neg_integer()]
  def decode(bin) when is_binary(bin), do: for(<<c::16 <- bin>>, do: c)

  # Map a quantized position to its row-major cell index, clamped into the grid.
  defp cell_index(qx, qy, grid) do
    cx = min(grid - 1, div(qx * grid, @qmax))
    cy = min(grid - 1, div(qy * grid, @qmax))
    cy * grid + cx
  end
end
