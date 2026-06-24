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
      MAXIMAL CONTIGUOUS CANVAS RUNS. A run is a maximal stretch of CANVAS-
      ELIGIBLE blocks: prose (`paragraph | heading | list`) PLUS the canvas atom
      types the canvas handles inline. As of S3 that is `divider` (a ProseMirror
      ATOM node), as of S3.2 also `callout` (a CONTENT node with an editable
      body), and as of S3.3 also `code` (an ATTR-ATOM node whose text rides in a
      `value` attr edited by a non-PM textarea) — all pulled INTO the canvas (see
      `assets/paper-editor/src/canvas/run-convert.js` `CANVAS_ATOM_TYPES` /
      `CANVAS_CONTENT_TYPES` / `CANVAS_ATTR_ATOM_TYPES`), so none SPLIT a run
      anymore. A run of
      one-or-more adjacent canvas blocks becomes one `{:run, [block, …]}`; every
      block that is NOT canvas-eligible (field-* / sheet / diagram / section /
      embed / …) is a run boundary emitted as `{:block, block}`. The
      segment order matches the input order exactly. Pure: no socket, no I/O.

  Neither function is wired into the OFF path — `partition_runs/1` is only ever
  walked inside the `if paper_canvas_enabled?()` branch in
  `Components.PaperEditor.paper_block_editor/1`.
  """

  # Exactly the block kinds S0's run-convert.js treats as PROSE (PROSE_TYPES):
  # the ones a single ProseMirror document can hold as native textblock siblings,
  # giving cross-block caret / selection / split / merge for free.
  @prose_types ~w(paragraph heading list)

  # S3: the non-prose block kinds the canvas handles INLINE as atom nodes
  # (run-convert.js CANVAS_ATOM_TYPES). The divider is the first — a leaf atom
  # node-view — so it no longer SPLITS a run. Later increments add code / sheet /
  # field here as their atom node-views land.
  @canvas_atom_types ~w(divider)

  # S3.2: the non-prose block kinds the canvas handles as CONTENT nodes — nodes
  # with an EDITABLE body living INSIDE the run (run-convert.js
  # CANVAS_CONTENT_TYPES). The callout is the first: its prose body becomes a real
  # editable PM region and its chrome (tone/title/fold) renders around it, so it
  # no longer SPLITS a run. field-* / sheet STILL split until their own S3
  # increments.
  @canvas_content_types ~w(callout)

  # S3.3: the non-prose block kinds the canvas handles as ATTR-ATOM nodes — atom
  # nodes (no PM-managed body, like the divider) whose body TEXT rides in an attr
  # and is edited by a NON-PM <textarea> island (run-convert.js
  # CANVAS_ATTR_ATOM_TYPES). The code block is the first: its `value` is a plain
  # string (compose.ex:272 reads only `value`) plus an optional `lang`, so it no
  # longer SPLITS a run. UNLIKE the divider it carries a mutable value/lang and CAN
  # emit a patch-block; UNLIKE the callout it has no inline body. field-* / sheet /
  # diagram STILL split until their own increments (diagram reuses this shape next).
  @canvas_attr_atom_types ~w(code)

  # The full set of CANVAS-ELIGIBLE block kinds: prose ∪ canvas atoms ∪ canvas
  # attr-atoms ∪ canvas content nodes. A run is a maximal contiguous stretch of
  # these; any other kind is a run boundary. Keep this aligned with run-convert.js
  # (PROSE_TYPES ∪ CANVAS_ATOM_TYPES ∪ CANVAS_ATTR_ATOM_TYPES ∪ CANVAS_CONTENT_TYPES)
  # so the Elixir partition and the JS projection agree on what a run may contain.
  @canvas_types @prose_types ++
                  @canvas_atom_types ++ @canvas_attr_atom_types ++ @canvas_content_types

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
  Partition an ordered block list into maximal contiguous canvas runs.

  Returns a list of segments, in input order, each either:

    * `{:run, [canvas_block, …]}` — one-or-more adjacent CANVAS-ELIGIBLE blocks
      (prose `paragraph|heading|list` PLUS canvas atoms `divider` PLUS canvas
      content nodes `callout` PLUS canvas attr-atoms `code`). A MAXIMAL run: it
      extends as far as the next non-canvas boundary. As of S3.3 a divider, a
      callout AND a code block are all canvas-eligible, so a
      `[heading, paragraph, code, paragraph]` is ONE run (the code no longer
      splits it).
    * `{:block, boundary_block}` — a single non-canvas block (field-* / sheet /
      diagram / …) that is a run boundary.

  Pure. An empty list ⇒ `[]`. A list with no canvas blocks ⇒ all `{:block, _}`.
  A list that is all canvas-eligible ⇒ a single `{:run, _}` (even a lone divider).
  """
  @spec partition_runs([map()]) :: [{:run, [map()]} | {:block, map()}]
  def partition_runs(blocks) when is_list(blocks) do
    blocks
    # Group adjacent blocks by their canvas-eligibility, preserving order.
    # `chunk_by` cuts a new chunk every time the boolean flips, so each chunk is
    # a maximal contiguous stretch of either all-canvas or all-non-canvas blocks.
    |> Enum.chunk_by(&canvas?/1)
    |> Enum.flat_map(fn
      [first | _] = chunk ->
        if canvas?(first) do
          # A maximal canvas stretch (prose ∪ dividers ∪ callouts) → ONE run keyed
          # (downstream) by its first id.
          [{:run, chunk}]
        else
          # A stretch of non-canvas blocks → each is its own boundary segment.
          Enum.map(chunk, fn b -> {:block, b} end)
        end
    end)
  end

  @doc """
  True when a block is a prose block (`paragraph | heading | list`) — a native
  textblock in the canvas document.
  """
  @spec prose?(map()) :: boolean()
  def prose?(block) when is_map(block), do: Map.get(block, "type") in @prose_types
  def prose?(_), do: false

  @doc """
  True when a block is CANVAS-ELIGIBLE — prose (`paragraph | heading | list`) OR
  a canvas atom (`divider`) OR a canvas content node (`callout` as of S3.2) OR a
  canvas attr-atom (`code` as of S3.3). Canvas-eligible blocks make up a
  `{:run, …}` segment; anything else is a `{:block, …}` boundary. This is the
  predicate `partition_runs/1` chunks on.
  """
  @spec canvas?(map()) :: boolean()
  def canvas?(block) when is_map(block), do: Map.get(block, "type") in @canvas_types
  def canvas?(_), do: false

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
