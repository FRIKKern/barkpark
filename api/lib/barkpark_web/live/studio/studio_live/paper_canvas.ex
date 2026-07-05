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
      `value` attr edited by a non-PM textarea), as of S3.5 also the 7 native
      `field-*` types (CONTROL-ATOM nodes), and as of S3.6 also `sheet` + `embed`
      (READ-ONLY ATOM nodes carrying the whole block verbatim) — all pulled INTO
      the canvas (see `assets/paper-editor/src/canvas/run-convert.js`
      `CANVAS_ATOM_TYPES` / `CANVAS_CONTENT_TYPES` / `CANVAS_ATTR_ATOM_TYPES` /
      `CANVAS_FIELD_TYPES` / `CANVAS_READONLY_ATOM_TYPES`), so none SPLIT a run
      anymore. A run of
      one-or-more adjacent canvas blocks becomes one `{:run, [block, …]}`; every
      block that is NOT canvas-eligible (a nested-structure field — `composite` /
      `arrayOf` / `codelist` / `localizedText` / `section` / …) is a run boundary
      emitted as
      `{:block, block}`. The segment order matches the input order exactly. Pure:
      no socket, no I/O.

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

  # S3.3 / S3.4: the non-prose block kinds the canvas handles as ATTR-ATOM nodes —
  # atom nodes (no PM-managed body, like the divider) whose body TEXT rides in an attr
  # and is edited by a NON-PM <textarea> island (run-convert.js
  # CANVAS_ATTR_ATOM_TYPES). `code` (S3.3) is the first: its `value` is a plain string
  # (`Render.Compose.compose_block/2`'s `code` clause reads only `value`) plus an
  # optional `lang`. `diagram` (S3.4) MIRRORS it: its `source` is the raw Mermaid
  # text (`Render.Compose.compose_block/2`'s `diagram` clause reads `source`) plus
  # an optional `caption`. Both no longer SPLIT a run. UNLIKE the divider they
  # carry a mutable body and CAN emit a patch-block; UNLIKE the callout they have no
  # inline body. field-* / sheet STILL split until their own increments.
  @canvas_attr_atom_types ~w(code diagram)

  # S3.5: the 7 NATIVE-CONTROL field-* block kinds the canvas handles as CONTROL-ATOM
  # nodes — atom nodes (no PM-managed body, like the divider/code) whose VALUE rides
  # in an attr and is edited by a NATIVE HTML control (input / textarea / checkbox /
  # select / datetime-local / color; run-convert.js CANVAS_FIELD_TYPES). UNLIKE the
  # code/diagram attr-atoms, the value is COERCED BY FIELD TYPE exactly like the
  # shipped BarkparkFieldBlockBridge (field-boolean → a BOOLEAN; the rest → a STRING).
  # These 7 no longer SPLIT a run.
  #
  # Keep aligned with run-convert.js CANVAS_NATIVE_FIELD_TYPES and
  # field-node.js BP_NATIVE_FIELD_TYPES.
  @canvas_field_types ~w(field-string field-slug field-text field-boolean field-select field-datetime field-color)

  # RUN-SPLITTER TAIL (part 1): the 2 PICKER field-* block kinds the canvas now handles
  # as CONTROL-ATOM nodes mounting the EXISTING client-side picker Web Components —
  # field-image → <bp-media-picker>, field-reference → <bp-reference-picker>. The pickers
  # are CLIENT-SIDE (they fetch their own data over HTTP; no pushEvent / phx- / liveSocket
  # — NO LiveView dependency), so they mount inside a canvas node-view exactly like a
  # native control. Each emits a bubbling `bp-change` CustomEvent the node-view coerces to
  # the block `value` IDENTICALLY to the per-block BarkparkFieldBlockBridge, so a canvas
  # picker edit persists the SAME { value } the per-block path does. These 2 no longer
  # SPLIT a run. Keep aligned with run-convert.js CANVAS_PICKER_FIELD_TYPES and
  # field-node.js BP_PICKER_FIELD_TYPES.
  #
  # STILL EXCLUDED (a separate nested-structure increment): section / composite / object /
  # arrayOf / codelist / localizedText — those are NOT in any canvas-field set and STILL
  # split a run.
  @canvas_picker_field_types ~w(field-image field-reference)

  # S3.6: the READ-ONLY ATOM block kinds the canvas handles as read-only atom nodes —
  # atom nodes (no PM-managed body, like the divider/code/field) that are REFERENCES,
  # NOT editable text (run-convert.js CANVAS_READONLY_ATOM_TYPES). `sheet` (a cached
  # value-grid embed edited in its OWN surface; `Render.Compose.compose_block/2`'s
  # `sheet` clause composes its `snapshot` read-only) and `embed` (a note
  # transclusion ![[note]] whose target is resolved at VIEW render —
  # `Render.Compose.compose_block/2`'s `embed` clause emits the `PdEmbed` node,
  # `Render.Walk`'s `PdEmbed` clause injects the pre-resolved HTML) are both pulled
  # INTO the canvas as read-only atoms
  # carrying the WHOLE block VERBATIM. UNLIKE the field control-atom (whose value is
  # edited → a patch), these NEVER emit a value/content patch — nothing is edited in
  # the editor — but they ARE canvas-eligible (no split) and DO participate in
  # structural ops. These two no longer SPLIT a run.
  #
  # After the run-splitter tail (part 1) the picker fields (field-image / field-reference)
  # ALSO ride the canvas (their WCs are client-side, no LiveView dependency), so the ONLY
  # remaining run boundaries are the NESTED-STRUCTURE fields
  # (composite/object/arrayOf/codelist/localizedText/section) — a typical paper's run now
  # spans the WHOLE doc. Keep aligned with run-convert.js CANVAS_READONLY_ATOM_TYPES
  # and embed-node.js BP_SHEET_NODE_NAME / BP_EMBED_NODE_NAME.
  @canvas_readonly_atom_types ~w(sheet embed)

  # The full set of CANVAS-ELIGIBLE block kinds: prose ∪ canvas atoms ∪ canvas
  # attr-atoms ∪ canvas content nodes ∪ canvas native field control-atoms ∪ canvas
  # PICKER field control-atoms ∪ canvas read-only atoms. A run is a maximal contiguous
  # stretch of these; any other kind is a run boundary. Keep this aligned with
  # run-convert.js (PROSE_TYPES ∪ CANVAS_ATOM_TYPES ∪ CANVAS_ATTR_ATOM_TYPES ∪
  # CANVAS_CONTENT_TYPES ∪ CANVAS_FIELD_TYPES[native ∪ picker] ∪ CANVAS_READONLY_ATOM_TYPES)
  # so the Elixir partition and the JS projection agree on what a run may contain. The
  # ONLY remaining run boundaries are the nested-structure fields (section / composite /
  # object / arrayOf / codelist / localizedText).
  @canvas_types @prose_types ++
                  @canvas_atom_types ++
                  @canvas_attr_atom_types ++
                  @canvas_content_types ++
                  @canvas_field_types ++
                  @canvas_picker_field_types ++ @canvas_readonly_atom_types

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
      content nodes `callout` PLUS canvas attr-atoms `code`/`diagram`). A MAXIMAL
      run: it extends as far as the next non-canvas boundary. As of S3.4 a divider, a
      callout, a code block AND a diagram block are all canvas-eligible, so a
      `[heading, paragraph, diagram, paragraph]` is ONE run (the diagram no longer
      splits it).
    * `{:block, boundary_block}` — a single non-canvas block (field-* / sheet /
      … ) that is a run boundary.

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
          # A maximal canvas stretch (prose ∪ dividers ∪ callouts ∪ attr-atoms ∪
          # native fields ∪ read-only sheet/embed atoms) → ONE run keyed
          # (downstream) by its first id.
          [{:run, chunk}]
        else
          # A stretch of non-canvas blocks (picker fields / composites) → each is
          # its own boundary segment.
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
  canvas attr-atom (`code` / `diagram` as of S3.3/S3.4) OR a native field
  control-atom (the 7 `field-*` types as of S3.5) OR a read-only atom (`sheet` /
  `embed` as of S3.6, carrying the whole block verbatim). Canvas-eligible blocks
  make up a `{:run, …}` segment; anything else (the picker fields `field-image` /
  `field-reference`, composites) is a `{:block, …}` boundary. This is the
  predicate `partition_runs/1` chunks on.
  """
  @spec canvas?(map()) :: boolean()
  def canvas?(block) when is_map(block), do: Map.get(block, "type") in @canvas_types
  def canvas?(_), do: false

  @doc """
  The STABLE run id for a run at ORDINAL `i` in the ordered `partition_runs/1`
  output: `"run-" <> i`.

  Bug #1a fix — run identity is now the run's ORDINAL, NOT its first-block id.
  The first-block id is MUTABLE: when a run's leading block is deleted / merged /
  front-reordered, the re-partitioned run's first id becomes the NEW first id. The
  old first-block-id keying then broke two ways:

    * the echo `bp:canvas-update {run_id: newId}` no longer matched the still-
      mounted wrapper `paper-canvas-oldId` → the hook dropped it → the canvas diff
      baseline never advanced; and
    * the re-render computed a new wrapper id → under `phx-update="ignore"` an id
      change is remove+add → the editor REMOUNTED (caret + in-flight edit lost).

  The ordinal is STABLE under a leading-block delete / merge / front-reorder: the
  run stays at the same index `i` in `partition_runs/1`, so the wrapper id is
  unchanged → no remount → the echo (keyed by the same ordinal) still matches the
  mounted wrapper → the baseline advances. (A WHOLE-run delete or a split/merge DOES
  shift ordinals → a remount — acceptable and out of scope: the remount re-seeds the
  run from the confirmed blocks, so no data is lost.)

  Returns a STRING (`"run-0"`, `"run-1"`, …), NOT a bare integer: the inbound hook
  guards with `if (!run.run_id) return;`, so a bare `0` (the first run's ordinal)
  would be falsy and the first run's echo would be silently dropped. The `"run-"`
  prefix makes every ordinal id truthy, so the hook needs no change.
  """
  @spec run_id(non_neg_integer()) :: String.t()
  def run_id(ordinal) when is_integer(ordinal) and ordinal >= 0,
    do: "run-" <> Integer.to_string(ordinal)

  @doc """
  Pair each `{:run, blocks}` segment from `partition_runs/1` with its run ORDINAL
  (0, 1, 2 … over runs in document order). `{:block, _}` boundaries pass through
  with `nil` for the ordinal (they have no run identity).

  This is the SINGLE source of truth for run-ordinal assignment, used by BOTH the
  render path (the `phx-update="ignore"` wrapper id) and the echo path
  (`push_canvas_echo` keys each `bp:canvas-update` entry by the same ordinal). Both
  walking the SAME helper guarantees the echo for run `i` always routes to the
  wrapper for run `i`.

  Returns a list of `{:run, blocks, ordinal}` / `{:block, block}` tuples in input
  order.
  """
  @spec with_run_ordinals([{:run, [map()]} | {:block, map()}]) ::
          [{:run, [map()], non_neg_integer()} | {:block, map()}]
  def with_run_ordinals(segments) when is_list(segments) do
    {out, _i} =
      Enum.map_reduce(segments, 0, fn
        {:run, blocks}, i -> {{:run, blocks, i}, i + 1}
        {:block, block}, i -> {{:block, block}, i}
      end)

    out
  end

  # ── t6: WordPress-style metadata sidebar (doctrine Rule 4) ───────────────────
  #
  # The sidebar is the calm right document panel: everything that FAILS the
  # article test (status/visibility, slug, context, labels, relations) lives
  # HERE, never in the body. The title + featured image stay LOCKED body blocks
  # (t1/t4 derive doc.title from the title block) — this module deliberately
  # never surfaces either into the sidebar (no duplication).
  #
  # These pure helpers are the seam the LiveView handlers + the render component
  # ride, so the doctrine's two hard invariants are UNIT-testable with no DB:
  #
  #   * A sidebar edit is a DOCUMENT-FIELD update, structurally distinct from a
  #     body block op — `sidebar_meta_op/2` returns a `{:doc_field, …}` tuple,
  #     NEVER the `%{"op" => …}` block-op shape `Shared.paper_op/2` consumes. A
  #     sidebar edit therefore CANNOT touch blocks.
  #   * Slug validation is INSTANT + format-only — `slug_feedback/1` is a pure
  #     status verdict the change handler assigns without persisting or hitting
  #     the DB (uniqueness is a save-time concern, not a keystroke one).

  # The fixed, ordered sidebar sections. Each is independently collapsible.
  @sidebar_sections ~w(publish slug context labels relations)

  @doc "The ordered sidebar section keys (each a collapsible chrome section)."
  @spec sidebar_sections() :: [String.t()]
  def sidebar_sections, do: @sidebar_sections

  @doc """
  A sidebar metadata edit expressed as a DOCUMENT-FIELD op — deliberately NOT a
  body block op. Returns `{:doc_field, field, value}`; the handler routes it
  through the document autosave/publish path (`handlers/fields.ex`), never
  `Shared.paper_op/2`. This tuple shape is the structural proof that a sidebar
  edit cannot reach a block: it carries none of the `"op"` / `"block"` / `"id"`
  keys the block-op applier reads.
  """
  @spec sidebar_meta_op(String.t(), term()) :: {:doc_field, String.t(), term()}
  def sidebar_meta_op(field, value) when is_binary(field), do: {:doc_field, field, value}

  # WordPress-style slug: lowercase a–z / 0–9 in hyphen-joined segments — no
  # leading, trailing, or doubled hyphen, no spaces, no capitals. Empty ⇒ invalid.
  @slug_re ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/

  @doc "True when `slug` is a valid WordPress-style slug (format only)."
  @spec sidebar_slug_valid?(term()) :: boolean()
  def sidebar_slug_valid?(slug) when is_binary(slug), do: Regex.match?(@slug_re, slug)
  def sidebar_slug_valid?(_), do: false

  @doc """
  Instant slug format feedback as `{tone, message}` where `tone` is one of the
  status-vocabulary atoms `:ok | :warn | :danger`. Pure — no DB, no uniqueness
  check. This is the keystroke-level format guard the Slug section renders live.
  """
  @spec slug_feedback(term()) :: {:ok | :warn | :danger, String.t()}
  def slug_feedback(slug) when is_binary(slug) do
    cond do
      slug == "" -> {:warn, "Slug is required"}
      sidebar_slug_valid?(slug) -> {:ok, "Looks good"}
      slug =~ ~r/[A-Z]/ -> {:danger, "Lowercase only — no capitals"}
      slug =~ ~r/\s/ -> {:danger, "No spaces — use hyphens"}
      slug =~ ~r/(^-|-$|--)/ -> {:warn, "No leading, trailing, or doubled hyphens"}
      true -> {:danger, "Only lowercase letters, numbers, and hyphens"}
    end
  end

  def slug_feedback(_), do: {:danger, "Only lowercase letters, numbers, and hyphens"}

  @doc """
  Reader visibility derived from publish status (papers publish to
  /papers/:slug). "published" ⇒ "Public". Anything else is just "Draft" — NOT
  "not public": the public reader (`Content.get_paper/3`) fetches by exact
  doc_id with no status filter, so a non-published row at `doc_id = slug` is
  still publicly reachable and the stronger claim would lie.
  """
  @spec visibility_label(term()) :: String.t()
  def visibility_label("published"), do: "Public"
  def visibility_label(_), do: "Draft"

  @doc """
  Taxonomy labels for the sidebar Labels section — the paper's `content["tags"]`,
  filtered to non-blank strings. `[]` when a paper carries no tags. Pure.
  """
  @spec paper_labels(term()) :: [String.t()]
  def paper_labels(%{content: %{"tags" => tags}}) when is_list(tags),
    do: Enum.filter(tags, &(is_binary(&1) and String.trim(&1) != ""))

  def paper_labels(_), do: []

  @doc """
  Outbound relations for the sidebar Relations section: each `field-reference`
  block that carries a non-blank value, as `%{id: value, label: label}`. Pure —
  reads the ALREADY-loaded block list, never the DB. `[]` when there are none.
  """
  @spec paper_relations(term()) :: [%{id: term(), label: String.t()}]
  def paper_relations(blocks) when is_list(blocks) do
    blocks
    |> Enum.filter(fn b ->
      is_map(b) and Map.get(b, "type") == "field-reference" and present?(Map.get(b, "value"))
    end)
    |> Enum.map(fn b ->
      %{
        id: Map.get(b, "value"),
        label: Map.get(b, "label") || Map.get(b, "fieldName") || "Reference"
      }
    end)
  end

  def paper_relations(_), do: []

  defp present?(v) when is_binary(v), do: String.trim(v) != ""
  defp present?(nil), do: false
  defp present?(_), do: true

  @doc """
  True when a sidebar section is EXPANDED, given the `collapsed` set (a MapSet of
  collapsed section keys). Absent / non-MapSet `collapsed` ⇒ open (the default is
  every section expanded).
  """
  @spec sidebar_section_open?(term(), String.t()) :: boolean()
  def sidebar_section_open?(%MapSet{} = collapsed, key), do: not MapSet.member?(collapsed, key)
  def sidebar_section_open?(_collapsed, _key), do: true

  @doc """
  Flip a section's collapsed state in the `collapsed` MapSet, returning the new
  set. A nil / non-MapSet input seeds an empty set first, so the first toggle of
  a section collapses it.
  """
  @spec toggle_section(term(), String.t()) :: MapSet.t()
  def toggle_section(collapsed, key) do
    set = if match?(%MapSet{}, collapsed), do: collapsed, else: MapSet.new()
    if MapSet.member?(set, key), do: MapSet.delete(set, key), else: MapSet.put(set, key)
  end
end
