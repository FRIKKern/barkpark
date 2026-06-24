defmodule BarkparkWeb.Studio.StudioLive.PaperCanvas do
  @moduledoc """
  Phase-4 Stage S2 — the Studio-side seam for the continuous `<bp-paper-canvas>`.

  Two pure pieces, both unit-tested directly, both with ZERO effect on the
  shipped per-block editor when the flag is OFF:

    * `paper_canvas_enabled?/0` — the feature flag. Reads `BARKPARK_PAPER_CANVAS`
      from the environment. **Default FALSE.** Only the literal truthy strings
      `"1"` / `"true"` (case-insensitive, surrounding whitespace trimmed) enable
      the canvas. Unset, empty, or anything else ⇒ false ⇒ the EXISTING per-block
      stream render runs verbatim. This is the prime-directive guard: flag-OFF is
      byte-identical to today.

    * `partition_runs/1` — partitions an ordered top-level block list into
      MAXIMAL CONTIGUOUS PROSE RUNS. Prose is exactly `paragraph | heading |
      list` (the same set S0's `run-convert.js` round-trips — see
      `assets/paper-editor/src/canvas/run-convert.js` `PROSE_TYPES`). A run of
      one-or-more adjacent prose blocks becomes one `{:run, [block, …]}`; every
      non-prose block (callout / field-* / sheet / diagram / divider / section /
      code / embed / …) is a run boundary emitted as `{:block, block}`. The
      segment order matches the input order exactly. Pure: no socket, no I/O.

  Neither function is wired into the OFF path — `partition_runs/1` is only ever
  walked inside the `if paper_canvas_enabled?()` branch in
  `Components.PaperEditor.paper_block_editor/1`.
  """

  # Exactly the block kinds S0's run-convert.js treats as PROSE (PROSE_TYPES):
  # the ones a single ProseMirror document can hold as native siblings, giving
  # cross-block caret / selection / split / merge for free. Everything else is a
  # run boundary rendered by its existing per-block widget.
  @prose_types ~w(paragraph heading list)

  @doc """
  The `BARKPARK_PAPER_CANVAS` feature flag. **Default FALSE.**

  True only for `"1"` or `"true"` (case-insensitive, trimmed). Unset / empty /
  any other value ⇒ false ⇒ the shipped per-block render path, unchanged.
  """
  @spec paper_canvas_enabled?() :: boolean()
  def paper_canvas_enabled? do
    case System.get_env("BARKPARK_PAPER_CANVAS") do
      nil -> false
      raw -> raw |> String.trim() |> String.downcase() |> truthy?()
    end
  end

  defp truthy?("1"), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false

  @doc """
  Partition an ordered block list into maximal contiguous prose runs.

  Returns a list of segments, in input order, each either:

    * `{:run, [prose_block, …]}` — one-or-more adjacent `paragraph|heading|list`
      blocks (a MAXIMAL run: it extends as far as the next non-prose boundary).
    * `{:block, non_prose_block}` — a single non-prose block (a run boundary).

  Pure. An empty list ⇒ `[]`. A list with no prose ⇒ all `{:block, _}`. A list
  that is all prose ⇒ a single `{:run, _}`.
  """
  @spec partition_runs([map()]) :: [{:run, [map()]} | {:block, map()}]
  def partition_runs(blocks) when is_list(blocks) do
    blocks
    # Group adjacent blocks by their prose-ness, preserving order. `chunk_by`
    # cuts a new chunk every time the boolean flips, so each chunk is a maximal
    # contiguous stretch of either all-prose or all-non-prose blocks.
    |> Enum.chunk_by(&prose?/1)
    |> Enum.flat_map(fn
      [first | _] = chunk ->
        if prose?(first) do
          # A maximal prose stretch → ONE run keyed (downstream) by its first id.
          [{:run, chunk}]
        else
          # A stretch of non-prose blocks → each is its own boundary segment.
          Enum.map(chunk, fn b -> {:block, b} end)
        end
    end)
  end

  @doc """
  True when a block is a prose block (`paragraph | heading | list`) — the unit a
  `<bp-paper-canvas>` run is made of.
  """
  @spec prose?(map()) :: boolean()
  def prose?(block) when is_map(block), do: Map.get(block, "type") in @prose_types
  def prose?(_), do: false

  @doc """
  The STABLE run id for a `{:run, blocks}` segment: the first block's id.

  Keys the `phx-update="ignore"` wrapper so a run survives re-renders in place
  (caret/editor preserved) as long as its leading block id is unchanged. A
  mid-edit re-partition that changes the leading block re-keys the wrapper — a
  clean remount of just that run, not the whole list.
  """
  @spec run_id([map()]) :: String.t() | nil
  def run_id([first | _]), do: Map.get(first, "id")
  def run_id(_), do: nil
end
