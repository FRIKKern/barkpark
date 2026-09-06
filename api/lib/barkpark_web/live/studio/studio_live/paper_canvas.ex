defmodule BarkparkWeb.Studio.StudioLive.PaperCanvas do
  @moduledoc """
  Phase-4 Stage S2 — the Studio-side seam for the continuous `<bp-paper-canvas>`.

  Two pure pieces, both unit-tested directly, both with ZERO effect on the
  shipped per-block editor when the flag is OFF:

    * `paper_canvas_enabled?/0` — the feature flag. Reads `BARKPARK_PAPER_CANVAS`
      from the environment. **Default TRUE (the pd-doctrine cutover — D7/D9).**
      The canvas is now the mainline editor: unset, empty, `"1"`, `"true"`, or
      ANY value that is not an explicit opt-out ⇒ true ⇒ opening a paper IS the
      always-editable canvas. Only the literal opt-out strings `"0"` / `"false"`
      (case-insensitive, surrounding whitespace trimmed) disable it ⇒ the shipped
      per-block stream render runs verbatim. This is the EXPLICIT OPT-OUT guard:
      `BARKPARK_PAPER_CANVAS=0` (or `=false`) is byte-identical to the legacy
      per-block path (D3). The flag FAILS TOWARD THE MAINLINE — a typo or an
      unexpected value keeps the canvas on, never silently reverting.

    * `partition_runs/1` — partitions an ordered top-level block list into
      MAXIMAL CONTIGUOUS CANVAS RUNS. A run is a maximal stretch of CANVAS-
      ELIGIBLE blocks: prose (`paragraph | heading | list`) PLUS the canvas atom
      types the canvas handles inline. As of S3 that is `divider` (a ProseMirror
      ATOM node), as of S3.2 also `callout` (a CONTENT node with an editable
      body), and as of S3.3 also `code` (an ATTR-ATOM node whose text rides in a
      `value` attr edited by a non-PM textarea), as of S3.5 also the 7 native
      `field-*` types (CONTROL-ATOM nodes), and as of S3.6 also `sheet` + `embed`
      (READ-ONLY ATOM nodes carrying the whole block verbatim), and as of t12a also
      the 10 contextual FLEET kinds (`tasks`/`task-board`/`cards`/… — SERVER-
      PAINTED read-only atoms, the whole block verbatim on `bpFleet`), and as of S10
      also the `columns` CONTAINER (a RECURSIVE nested-block node `bpColumns >
      bpColumn+ > child` — the first canvas node whose interior is a nested BLOCK
      TREE, not inline runs nor an opaque carry) — all pulled
      INTO the canvas (see `assets/paper-editor/src/canvas/run-convert.js`
      `CANVAS_ATOM_TYPES` / `CANVAS_CONTENT_TYPES` / `CANVAS_ATTR_ATOM_TYPES` /
      `CANVAS_FIELD_TYPES` / `CANVAS_READONLY_ATOM_TYPES` / `CANVAS_FLEET_TYPES` /
      `CANVAS_CONTAINER_TYPES`), so
      none SPLIT a run anymore. A run of
      one-or-more adjacent canvas blocks becomes one `{:run, [block, …]}`; every
      block that is NOT canvas-eligible (a contextual editor such as `form` /
      `questionnaire`, or a deep nested-structure field — `composite` / `arrayOf` /
      `codelist` / `localizedText`) is a run boundary
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
  # increments. The notes-grid split adds `note` (the singular annotated-item WIDGET):
  # like callout it is a CONTENT node with an editable inline body, but a SUPERSET —
  # it ALSO exposes label + lead as input islands. It FOLDS INTO a run (canvas-eligible),
  # ADDITIVE alongside the still-verbatim-carried legacy `notes` grid (@canvas_fleet_types).
  # THREE-WAY LOCKSTEP: run-convert.js CANVAS_CONTENT_TYPES ⇄ index.js (Note) ⇄ here.
  @canvas_content_types ~w(callout note)

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
  # STILL EXCLUDED (a separate nested-structure increment): composite / object /
  # arrayOf / codelist / localizedText — those are NOT in any canvas-field set and STILL
  # split a run. (`section` is NO LONGER excluded — it rides its own CONTAINER node; see
  # @canvas_container_types.)
  @canvas_picker_field_types ~w(field-image field-reference)

  # editable-action: the CTA `action` block the canvas handles as a CONTROL-ATOM node
  # (bpAction) — a LEAF whose href/label/priority ride attrs, edited by native controls
  # (like the field-* set, but one bpType and no BarkparkFieldBlockBridge coercion). Its
  # node-view renders the reader's own bp-button anchor byte-identically. No longer
  # SPLITS a run. KEEP LOCKSTEP with run-convert.js CANVAS_ACTION_TYPES and action-node.js.
  @canvas_action_types ~w(action)

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
  # (composite/object/arrayOf/codelist/localizedText) — `section` now rides its own
  # CONTAINER node (see @canvas_container_types), so a typical paper's run now
  # spans the WHOLE doc. Keep aligned with run-convert.js CANVAS_READONLY_ATOM_TYPES
  # and embed-node.js BP_SHEET_NODE_NAME / BP_EMBED_NODE_NAME.
  @canvas_readonly_atom_types ~w(sheet embed)

  # t12a (pdd-t12 partition flip): the contextual FLEET block kinds the canvas handles as
  # SERVER-PAINTED read-only atoms (run-convert.js CANVAS_FLEET_TYPES → the single
  # `bpFleet` node, the same multiplexing bpField uses for the field-* set).
  # Structurally IDENTICAL to the sheet/embed read-only atoms — the WHOLE block rides
  # VERBATIM on bpBlock with ZERO value/content ops (D5), structural-only participation
  # — but the DISPLAY HTML is the reader's OWN `Render.render_block(block, %{style:
  # :article})` pushed server-side on the `bp:block-html` channel (D8: ONE producer,
  # never hand-mirrored) and painted into the atom's hole; until it arrives the node
  # shows a loading chip.
  #
  # Wave 2 (#1175) shipped the ENTIRE fleet-in-canvas pipeline — the JS projection
  # (run-convert.js → embed-node.js bpFleet), the Studio hook (root.html.heex consuming
  # bp:block-html), and shared/paper.ex push_block_renders — EXCEPT this partition
  # entry, so every fleet block still fell through to a `{:block, boundary}` widget and
  # the bpFleet atom never mounted. Adding the kinds here folds them INTO runs so the
  # atom finally mounts (the Elixir-side flip; the JS is untouched).
  #
  # `diagram` is DELIBERATELY ABSENT — it rides its own EDITABLE bpDiagram attr-atom
  # (a `source` textarea; see @canvas_attr_atom_types), NOT the read-only paint.
  #
  # `form` and `questionnaire` are DELIBERATELY ABSENT here: both have contextual
  # authored-field editors, so they must be emitted as `{:block, block}` boundaries
  # instead of opaque bpFleet atoms. The JS projection and shared renderer may retain
  # receive-only recognition for legacy mounted canvases / server-paint compatibility;
  # that compatibility surface does not make either kind eligible for newly partitioned
  # canvas runs. paper_editor.ex owns their contextual boundary previews separately.
  @canvas_fleet_types ~w(tasks task-list task-detail task-board roadmap notes cards pipeline status-legend asciicast)

  # Article-chrome ROLE prose (eyebrow / byline / ingress / pullquote) — chrome-free
  # STYLED prose the canvas handles as plain ProseMirror nodes (run-convert.js
  # CANVAS_ROLE_TYPES → same-named nodes; role-nodes.js). UNLIKE the callout content
  # node (tone frame + fold chrome around a contentDOM), these emit ONE styled element
  # with a `bp-role-*` class — NO node-view. Their bodies persist per role (eyebrow
  # `text` string, byline `items` list, ingress/pullquote inline `content`); each CAN
  # emit a patch-block on a body edit and no longer SPLITS a run.
  #
  # KEEP LOCKSTEP with run-convert.js CANVAS_ROLE_TYPES and role-nodes.js.
  @canvas_role_types ~w(eyebrow byline ingress pullquote)

  # New mounts use the lossless contextual Table editor. JS retains the node,
  # coarse save receiver and slash insertion for already-mounted legacy runs.
  @canvas_table_types []

  # `figure` intentionally remains a server-rendered run boundary. Its singular
  # child receives a nested contextual canvas. JS retains the old bpFigure atom
  # only as a compatibility receiver for already-mounted/in-flight clients.

  # live-data task-list: a `task-list` carrying a `query` map is the LIVE editable
  # WIDGET (bpTaskList; run-convert.js CANVAS_TASK_LIST_NODE_NAME → task-list-node.js).
  # Its QUERY is the sole authored datum (an <input> island, patch-block{query}); its
  # ROWS are a resolve-at-read PROJECTION the server paints via the SAME
  # `bp:block-html` channel the fleet atoms use (query → TaskResolver.preview →
  # apply_preview → render_block, keyed by the block id — shared/paper.ex).
  #
  # DUAL-ENCODING NOTE (backward-compat): `task-list` ALSO stays in @canvas_fleet_types
  # above — a SNAPSHOT-ONLY (author-pinned, no query) task-list falls through to the
  # read-only bpFleet atom (the presence-of-query discriminant lives in run-convert.js's
  # blockToNode). So @canvas_types carries `task-list` via BOTH sets; because
  # @canvas_types feeds ONLY `canvas?/1` (a set-membership `in` check), the overlap is a
  # harmless no-op — it never double-counts. task-list MUST remain in @canvas_fleet_types
  # for the snapshot fallback AND for JS-lockstep with run-convert.js:CANVAS_FLEET_TYPES.
  #
  # KEEP LOCKSTEP with run-convert.js CANVAS_TASK_LIST_NODE_NAME / isLiveTaskListBlock
  # and task-list-node.js BP_TASK_LIST_NODE_NAME.
  @canvas_task_list_types ~w(task-list)

  # Direct canvas container kinds. Section and Columns retain JS receive
  # compatibility for legacy mounted canvases, but new Elixir rendering routes
  # them to contextual reader-shaped boundaries with scoped child runs.
  # `terminal` remains a direct canvas container:
  # a bpTerminal holding prose/divider body children (+ a bpTerminalAtom verbatim
  # carrier for any non-first-class child) wrapped in reader chrome (title bar + live
  # badge + footer); EDITABLE, emitting a COARSE whole-body+chrome patch-block.
  #
  # This new-mount partition set is intentionally narrower than the JS legacy
  # receive vocabulary.
  @canvas_container_types ~w(terminal)

  # STEP 4: the card WIDGET — a slots-native block (media/title/body/action slots)
  # the canvas mounts as its OWN node (bpCard) so a card FOLDS INTO a run instead of
  # folding into a run/opaque boundary. UNLIKE a fleet grid (verbatim-carried, server-
  # painted), the card is EDITABLE: body = an inline contentDOM, title = an attr island,
  # tone/media/action = present-only attrs. Its body flattens to plain text
  # (Slots.card_body_text/1) so the reader byte-matches ONE legacy `cards` grid item —
  # the legacy `cards` fleet stays in @canvas_fleet_types, verbatim-carried and UNTOUCHED.
  # MUST stay in lockstep with run-convert.js (bpCard / isCanvasCard*) and card-node.js.
  #
  # `stage` is the SECOND widget: the editable per-node twin of ONE legacy `pipeline`
  # node (kind/title/detail text + files/source chrome), mounted as bpStage (an atom
  # whose fields ride attrs, edited by native controls). Its reader `stage_html/1` emits
  # the identical pnode cell, so it renders == one legacy pipeline node; the legacy
  # `pipeline` fleet stays in @canvas_fleet_types, verbatim-carried and UNTOUCHED. MUST
  # stay in lockstep with run-convert.js (isCanvasStage*) and stage-node.js.
  @canvas_widget_types ~w(card stage)

  # pd-ee-dataviz-editors (charter D3): the 5 DATA-VIZ kinds the canvas handles as
  # SERVER-PAINTED atoms — the SAME bpFleet node + `bp:block-html` paint channel the
  # component fleet rides (run-convert.js CANVAS_DATAVIZ_TYPES → bpFleet; display HTML
  # is `Render.render_block(block, %{style: :article})` → the Render.DataViz emitters,
  # ONE producer, byte-parity by construction). Authored config is edited in the
  # bpFleet node-view's JSON edit island (embed-node.js FLEET_CONFIG_EDITORS /
  # FLEET_ITEM_EDITORS) → ONE patch-block → server repaint.
  #
  # A PARALLEL set, deliberately NOT folded into @canvas_fleet_types: that set rides
  # a 4-way lockstep with paper_editor.ex @fleet_preview_types (the classic-mode
  # boundary widget), and DataViz must stay OUT of the classic boundary paint —
  # classic (canvas-off) mode keeps the read-only catch-all for these kinds (charter
  # D2: C1 is scoped to the mainline canvas surface). `stat-grid` is the accepted
  # alias of `stats` (compose.ex); both are enumerated.
  #
  # MUST stay in LOCKSTEP with run-convert.js CANVAS_DATAVIZ_TYPES and
  # shared/paper.ex @dataviz_render_types (7 kinds in every one). D4: these kinds are
  # deliberately ABSENT from slash-insert.js CANVAS_SLASH_TYPES (data-bearing,
  # API-authored — an empty slash insert is meaningless).
  @canvas_dataviz_types ~w(stat stats stat-grid heatmap chart duel lineage)

  # The full set of CANVAS-ELIGIBLE block kinds: prose ∪ canvas atoms ∪ canvas
  # attr-atoms ∪ canvas content nodes ∪ canvas native field control-atoms ∪ canvas
  # PICKER field control-atoms ∪ canvas read-only atoms ∪ canvas FLEET server-paint
  # atoms (t12a, excluding contextual `form` / `questionnaire` boundaries) ∪ canvas
  # article-chrome ROLE prose ∪ canvas
  # direct CONTAINER nodes (terminal). A run is a maximal contiguous stretch of
  # these; any other kind is a run boundary. Keep this aligned with run-convert.js
  # (PROSE_TYPES ∪ CANVAS_ATOM_TYPES ∪ CANVAS_ATTR_ATOM_TYPES ∪ CANVAS_CONTENT_TYPES ∪
  # CANVAS_FIELD_TYPES[native ∪ picker] ∪ CANVAS_READONLY_ATOM_TYPES ∪
  # CANVAS_FLEET_TYPES ∪ CANVAS_ROLE_TYPES ∪ CANVAS_TABLE_TYPES ∪ CANVAS_CONTAINER_TYPES),
  # except that JS keeps receive-only legacy recognition for form/questionnaire/figure/
  # section/columns/table while this partition intentionally routes them to contextual
  # boundary editors. The
  # remaining boundaries also include nested-structure fields (composite / object /
  # arrayOf / codelist / localizedText).
  @canvas_types @prose_types ++
                  @canvas_atom_types ++
                  @canvas_attr_atom_types ++
                  @canvas_content_types ++
                  @canvas_field_types ++
                  @canvas_picker_field_types ++
                  @canvas_action_types ++
                  @canvas_readonly_atom_types ++
                  @canvas_fleet_types ++
                  @canvas_role_types ++
                  @canvas_table_types ++
                  @canvas_task_list_types ++
                  @canvas_container_types ++
                  @canvas_widget_types ++
                  @canvas_dataviz_types

  @doc """
  The `BARKPARK_PAPER_CANVAS` feature flag. **Default TRUE (the D7/D9 cutover).**

  The canvas is the mainline editor. Unset / empty / `"1"` / `"true"` / any value
  that is NOT an explicit opt-out ⇒ true. ONLY the literal opt-out strings `"0"`
  or `"false"` (case-insensitive, trimmed) ⇒ false ⇒ the shipped per-block render
  path, byte-identical to legacy (D3). Fails toward the mainline: an unexpected
  value keeps the canvas on.
  """
  @spec paper_canvas_enabled?() :: boolean()
  def paper_canvas_enabled? do
    case System.get_env("BARKPARK_PAPER_CANVAS") do
      nil -> true
      raw -> raw |> String.trim() |> String.downcase() |> not_opted_out?()
    end
  end

  # The ONLY two values that disable the canvas. Everything else — including the
  # empty string and any typo — keeps it on (fail toward the mainline).
  defp not_opted_out?("0"), do: false
  defp not_opted_out?("false"), do: false
  defp not_opted_out?(_), do: true

  @doc """
  Partition an ordered block list into maximal contiguous canvas runs.

  Returns a list of segments, in input order, each either:

    * `{:run, [canvas_block, …]}` — one-or-more adjacent CANVAS-ELIGIBLE blocks
      (prose `paragraph|heading|list` PLUS canvas atoms `divider` PLUS canvas
      content nodes `callout` PLUS canvas attr-atoms `code`/`diagram` PLUS
      article-chrome ROLE prose `eyebrow`/`byline`/`ingress`/`pullquote`). A MAXIMAL
      run: it extends as far as the next non-canvas boundary. As of S3.4 a divider, a
      callout, a code block AND a diagram block are all canvas-eligible, so a
      `[heading, paragraph, diagram, paragraph]` is ONE run (the diagram no longer
      splits it); the role blocks fold in the same way.
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
  `embed` as of S3.6, carrying the whole block verbatim) OR a FLEET server-paint
  atom (the contextual `tasks`/`task-board`/`cards`/… kinds as of t12a, whole block
  verbatim on `bpFleet`, painted with the reader's own HTML) OR an article-chrome
  ROLE prose node (`eyebrow` / `byline` / `ingress` / `pullquote`, chrome-free styled
  prose matching the reader) OR the canvas TABLE node tree (`table` as of
  editable-table — a bpTable > bpTableRow > cell nested tree whose cell bodies are
  editable inline runs) OR the direct `terminal` CONTAINER node. `form`, `questionnaire`,
  `figure`, `section`, and `columns` are intentionally NOT canvas-eligible:
  they remain boundary blocks so their contextual authored-field editors render.
  Canvas-eligible blocks
  make up a `{:run, …}` segment; anything else (the picker fields `field-image` /
  `field-reference` RIDE a run too — contextual form/questionnaire/figure/section/columns
  editors and the DEEP
  nested-structure fields composite / arrayOf / codelist / localizedText stay
  boundaries) is a `{:block, …}`
  boundary. This is the predicate `partition_runs/1` chunks on.
  """
  @spec canvas?(map()) :: boolean()
  def canvas?(block) when is_map(block), do: Map.get(block, "type") in @canvas_types
  def canvas?(_), do: false

  @doc """
  The STABLE run id for a run at ORDINAL `i` of the paper `slug`, in the ordered
  `partition_runs/1` output: `slug <> "-run-" <> i`.

  Bug #1a fix — run identity WITHIN a paper is the run's ORDINAL, NOT its
  first-block id. The first-block id is MUTABLE: when a run's leading block is
  deleted / merged / front-reordered, the re-partitioned run's first id becomes
  the NEW first id. The old first-block-id keying then broke two ways:

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

  Bug #1c fix — run identity ACROSS papers is namespaced by the paper `slug`.
  A bare-ordinal id (`"run-0"`) is IDENTICAL for every paper, and morphdom does
  GLOBAL keyed-node reuse: on a paper→paper patch-navigation it finds the OLD
  paper's `paper-canvas-run-0` wrapper by id and TRANSPLANTS it into the new
  paper's editor subtree instead of creating a fresh node. Under
  `phx-update="ignore"` the transplanted node's children are never touched and
  the hook's `mounted()` (the only place `data-canvas-blocks` is seeded into the
  WC) never re-fires — so the canvas kept showing the PREVIOUS paper while
  everything outside the ignore wrappers (sidebar, backlinks, title) moved on.
  The slug prefix makes the id change on navigation → remove+add → a fresh
  mount seeds the new paper. Within one paper the slug is constant, so every
  Bug #1a stability property above is preserved verbatim. (The read-only stream
  container solved the same collision the same way: `paper-body-<slug>`.)

  Returns a STRING (`"<slug>-run-0"`, …), NOT a bare integer: the inbound hook
  guards with `if (!run.run_id) return;`, so a bare `0` (the first run's ordinal)
  would be falsy and the first run's echo would be silently dropped. The slug +
  `"-run-"` prefix makes every ordinal id truthy, so the hook needs no change.
  """
  @spec run_id(String.t(), non_neg_integer()) :: String.t()
  def run_id(slug, ordinal)
      when is_binary(slug) and is_integer(ordinal) and ordinal >= 0,
      do: slug <> "-run-" <> Integer.to_string(ordinal)

  @doc false
  @spec expandable_run_slug(String.t(), String.t()) :: String.t()
  def expandable_run_slug(slug, expandable_id)
      when is_binary(slug) and is_binary(expandable_id),
      do: slug <> "-expandable-" <> expandable_id

  @doc false
  @spec steps_run_slug(String.t(), String.t(), String.t()) :: String.t()
  def steps_run_slug(slug, steps_id, row_id)
      when is_binary(slug) and is_binary(steps_id) and is_binary(row_id),
      do:
        slug <> "-steps-" <> Base.url_encode64(Jason.encode!([steps_id, row_id]), padding: false)

  @doc false
  @spec tabs_run_slug(String.t(), String.t(), String.t()) :: String.t()
  def tabs_run_slug(slug, tabs_id, row_id)
      when is_binary(slug) and is_binary(tabs_id) and is_binary(row_id),
      do: slug <> "-tabs-" <> Base.url_encode64(Jason.encode!([tabs_id, row_id]), padding: false)

  @doc false
  @spec figure_run_slug(String.t(), String.t()) :: String.t()
  def figure_run_slug(slug, figure_id)
      when is_binary(slug) and is_binary(figure_id),
      do: slug <> "-figure-" <> Base.url_encode64(Jason.encode!([figure_id]), padding: false)

  @doc false
  @spec terminal_run_slug(String.t(), String.t()) :: String.t()
  def terminal_run_slug(slug, terminal_id)
      when is_binary(slug) and is_binary(terminal_id),
      do: slug <> "-terminal-" <> Base.url_encode64(Jason.encode!([terminal_id]), padding: false)

  @doc false
  @spec section_run_slug(String.t(), String.t()) :: String.t()
  def section_run_slug(slug, section_id)
      when is_binary(slug) and is_binary(section_id),
      do: slug <> "-section-" <> Base.url_encode64(Jason.encode!([section_id]), padding: false)

  @doc false
  @spec columns_run_slug(String.t(), String.t(), non_neg_integer()) :: String.t()
  def columns_run_slug(slug, columns_id, column_index)
      when is_binary(slug) and is_binary(columns_id) and is_integer(column_index) and
             column_index >= 0,
      do:
        slug <>
          "-columns-" <>
          Base.url_encode64(Jason.encode!([columns_id, column_index]), padding: false)

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
  Taxonomy labels for the sidebar Labels section — the paper's `content["tags"]`
  as tag NAMES. Dual-shape (authoring-excellence D18): a weighted entry
  `%{"tag" => name, …}` (post-wall) reads as its name; a legacy flat string
  reads as itself; blanks and anything else are dropped. `[]` when a paper
  carries no tags. Pure.
  """
  @spec paper_labels(term()) :: [String.t()]
  def paper_labels(%{content: %{"tags" => tags}}) when is_list(tags) do
    tags
    |> Enum.map(&label_name/1)
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
  end

  def paper_labels(_), do: []

  # Both label shapes name a tag; a tagless map falls through to the filter
  # above (non-binary → dropped) rather than raising.
  defp label_name(%{"tag" => name}), do: name
  defp label_name(other), do: other

  @doc """
  Rich Labels entries for the sidebar — `content["tags"]` WITH the weight the
  publish wall enforces (authoring-excellence D76): each entry is
  `%{name, strength, rationale, main?}`. Dual-shape: a weighted map carries
  its strength/rationale; a legacy flat string reads as its name with nil
  strength and nil rationale. `main?` marks the entry whose name equals the
  stamped `content["main_tag"]`, case-insensitive. Entries sort strength DESC
  with nil-strength (legacy) LAST; the sort is stable, so document order holds
  within ties. A non-numeric strength (an unwalled type's content is
  untrusted — D21's crash-safety precedent) degrades to the legacy shape
  rather than raising. `paper_labels/1` above stays the names-only reader in
  document order. Pure.
  """
  @spec paper_label_entries(term()) :: [
          %{
            name: String.t(),
            strength: number() | nil,
            rationale: String.t() | nil,
            main?: boolean()
          }
        ]
  def paper_label_entries(%{content: %{"tags" => tags} = content}) when is_list(tags) do
    main = Map.get(content, "main_tag")

    tags
    |> Enum.map(&label_entry(&1, main))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn
      %{strength: s} when is_number(s) -> {0, -s}
      _ -> {1, 0}
    end)
  end

  def paper_label_entries(_), do: []

  defp label_entry(%{"tag" => name} = entry, main) when is_binary(name) do
    label_entry_for(
      name,
      numeric_or_nil(Map.get(entry, "strength")),
      string_or_nil(Map.get(entry, "rationale")),
      main
    )
  end

  defp label_entry(name, main) when is_binary(name), do: label_entry_for(name, nil, nil, main)
  defp label_entry(_, _), do: nil

  defp label_entry_for(name, strength, rationale, main) do
    case String.trim(name) do
      "" -> nil
      _ -> %{name: name, strength: strength, rationale: rationale, main?: main_tag?(name, main)}
    end
  end

  defp main_tag?(name, main) when is_binary(main),
    do: String.downcase(String.trim(name)) == String.downcase(String.trim(main))

  defp main_tag?(_name, _main), do: false

  defp numeric_or_nil(v) when is_number(v), do: v
  defp numeric_or_nil(_), do: nil

  defp string_or_nil(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      _ -> v
    end
  end

  defp string_or_nil(_), do: nil

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
        ref_type: Map.get(b, "refType"),
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
