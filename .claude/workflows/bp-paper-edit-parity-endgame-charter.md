<!-- doc-tier: agent | canonical-for: paper-edit-parity-endgame | budget: 4000tok -->
# Paper edit ⇄ reader — the 1:1 parity endgame (pass 2+)

**Goal (user):** the PortableDoc EDIT canvas must look **100% identical** to the
published READER article. "Edit mode should not be lackluster." No forms in the
flow, no mode-switch, no chrome the reader lacks. Editing IS previewing.

**Pass 1 (SHIPPED, PR #1203):** heading rhythm (shared top-only margins),
measure (720/640), line-height (1.65), removed redundant Save buttons.

**Pass 2+ = the STRUCTURAL divergences** — where the edit node-view DOM differs
from the reader's HTML producer. Each is a SLICE.

## The render topology (do not relearn — this is ground truth)

- READER: server HTML. `Barkpark.PortableDoc.{Compose,Walk,Render,Figures}` →
  `:article` style emits semantic HTML. Styled by the SHARED
  `api/assets/paper-surface/paper-surface.css` (via
  `Barkpark.PortableDoc.Render.Stylesheet.css/0`) + the reader skin in
  `api/lib/barkpark_web/layouts/bulldocs.html.heex`.
- EDIT: TipTap/ProseMirror. `api/assets/paper-editor/src/canvas/*.js` node-views,
  registered in `index.js`. Styled by root.html.heex inline `<style>` (Studio) and
  `paper-editor/src/styles.css` (embedders) — the `.bp-paper-editor-body` +
  `.bp-canvas-*` rules. Round-trip: `run-convert.js` (blockToTiptap / runToOps).
- The paper_editor.ex LiveView PARTITIONS blocks: prose (paragraph/heading/list)
  + canvas-eligible atoms (callout/code/diagram/divider/embed/fleet) → the WC;
  everything else → `paper_block_fields/1` FORMS (the lackluster path).
- Token VALUES are single-sourced + mirror-checked (paper-editor-mirror-check.sh);
  do NOT hand-edit the generated token block — run `--write`.

## The parity GATES (extend these; they are the harness)

- `test/barkpark_web/live/studio/view_edit_parity_test.exs` — byte-compares
  `.bp-paper-surface <el>` vs `.bp-paper-editor-body <el>` CSS. Any new shared
  element rule must be lockstepped across paper-surface.css + root.html.heex +
  styles.css or §5 trips.
- `test/barkpark/portable_doc/canvas_reader_parity_gate_test.exs` — HTML-producer
  parity for fleet blocks; JS may contain NO competing producer.
- Each slice ADDS an assertion proving its block's edit render matches the reader.

## The SLICES (each = one worktree branch, node --check + the mjs suite must pass)

| # | Slice | Divergence (reader ↔ edit) | Fix |
|---|---|---|---|
| S1 | **divider-glyph** | reader = centered `§` on a hairline, `margin:2.4rem 0` (figures.ex:33-37); edit = bare `<hr>` 12pt (divider-node.js:81-83) | divider-node emits the § structure + matching CSS; keep it an atom |
| S2 | **callout-dark-tone** | reader tone via `--bp-tone-*` tokens (dark-swaps); edit paints LIGHT-ONLY hex inline (callout-node.js:67-73,258-260) → wrong color in dark | paint via the `--bp-tone-*` CSS custom props / `bp-callout--<tone>` classes, not inline hex; drop the hand-copied hex map |
| S3 | **callout-structure** | reader = inline `<strong>` run-in title + body on one line, NO icon, native `<details>` (walk.ex:1285-1347); edit = separate head row + icon + fold button | restructure callout-node to a run-in title (contentDOM body), drop the icon, OR justify the delta in the parity test. Preserve fold via `<details>`-equivalent |
| S4 | **callout-margin** | reader `.bp-callout` NO block margin; edit `.bp-canvas-callout { margin:1em 0 }` | align margins |
| S5 | **eyebrow-nodeview** | reader = styled `<p class="bp-eyebrow">` (uppercase evergreen); edit = form text input | new `bpEyebrow` node-view rendering the eyebrow inline, edited in place; partition routes it into the canvas; convert.js round-trip |
| S6 | **byline-nodeview** | reader = styled byline; edit = form input (` · `-joined) | new node-view; same pattern as S5 |
| S7 | **ingress-nodeview** | reader = styled lead paragraph; edit = form `<textarea>` (resize handle visible) | new node-view rendering the ingress as prose |
| S8 | **pullquote-nodeview** | reader = styled pullquote; edit = form textarea | new node-view |
| S9 | **code-interior** | reader = static `<pre>` text; edit = lang input + textarea island (frame aligned) | align interior whitespace/structure; lower priority, may stay an editing island (justify in test) |

## Rules for every slice

1. NO new competing HTML producer in JS for fleet blocks (gate §3). Reuse the
   reader's emitter where the block is server-painted; for prose-like blocks
   (eyebrow/byline/ingress/pullquote) the node-view renders editable DOM that
   MATCHES the reader's element + classes.
2. Match the reader's exact tag + class + token bindings so shared CSS applies —
   don't hand-mirror hex.
3. Round-trip: any new node type needs blockToTiptap + runToOps in
   run-convert.js, and the block's attrs must survive (bp-attrs.js).
4. `cd api/assets/paper-editor && npm test` (the mjs suite) + `node --check`
   every touched JS file. Add an mjs test for each new node-view.
5. Behavior-preserving for the LiveView partition — a converted block leaves the
   FORM path and enters the canvas; keep the paper-edit-block fallback handler.
6. Return your branch name, touched files, and the parity assertion you added.

## Integration (lead owns)

Slices land as `loop-epic/parity-<slice>` branches. Integrate in the order above
(S1-S4 callout/divider first — self-contained; S5-S8 article-chrome node-views
share index.js + paper_editor.ex partition + convert.js → source-union + REBUILD
the bundle once). Full suite (baseline ~7400/0) + mirror-check + status-manifest +
the extended parity gates. Lead browser-verifies each on localhost:4000 before PR.

## Wave 2 candidates — the pass-2 divergence audit (W1.4, 2026-07-09)

Method: dual-rendered the 91-block `portabledoc-showcase` (50 distinct block
types). READER via the standalone harness `cd api && mix run --no-start
scripts/pass2_audit_harness.exs` (calls `Render.render_block(block, %{style:
:article})` — the SAME call the canvas paint makes — never `mix phx.server`);
EDIT at spec/source level (node-view `renderHTML` / `dom.className`, node-views
can't mount headless). Every block type classified into four buckets:

**A. SERVER-PAINTED-BY-CONSTRUCTION** (reader HTML painted into the canvas or
carried verbatim — parity by construction, gated). NO wave-2 slice.
`figure` (child rides `bpChild` verbatim → `data-bp-fleet-body` paint hole,
figure-node.js:156-174), `task-list` (rows are the ONE server producer via
TaskResolver → `data-bp-fleet-body`, task-list-node.js:196-215), `diagram`
(edit island edits source, reader renders the figure — fleet §1,
diagram-node.js:205-224), and the verbatim chips `tasks`/`task-board`/`roadmap`/
`task-detail`/`cards`/`notes`/`pipeline`/`status-legend`/`form`/`asciicast`/
`sheet`/`embed`. Gate: `canvas_reader_parity_gate_test.exs` §1/§3/§4.

**B. GATED editable node-views** (each has a dedicated source-level edit⇄reader
parity assertion). NO wave-2 slice. `divider` (S1, `__divider_parity.test.mjs`,
14 parity refs), `callout` (S2-S3, `__callout_parity.test.mjs`, 22 refs), `code`
(S9, `__code_interior.test.mjs`, 10 refs).

**C. PROSE** (paragraph/heading/list/eyebrow/byline/ingress/pullquote + fields):
bare semantic tags, styled by the shared surface CSS; locked by
`view_edit_parity_test.exs` (element-rule byte-compare). NO wave-2 slice.

**D. UNGATED DIVERGENCE** — post-07-07 structural node-views wrap reader-shaped
inner DOM in `bp-canvas-*` chrome with a **round-trip-only** test (`run-convert`
diff, ZERO reader-parity refs) and **no** structural edit⇄reader assertion. These
are the wave-2 slices — each adds a `__<block>_parity.test.mjs` in the S1/S2/S9
mould (assert the node-view `renderHTML`/`dom` source matches the reader emitter's
tags + classes). The two `LIVE BUG` rows also have a filed parity bug task.

| # | Slice | Reader emits (file:line) | Edit node-view emits (file:line) | Divergence / why ungated |
|---|---|---|---|---|
| S10 | **card-slot-parity** `LIVE BUG` | `Components.card_html/2` — bare `<h_>`/`<p>`/`<img>`/`<a>` under `<div class="bp-card[ --tone]">`, "no bp-card__ chrome" (components.ex:328,349-364) | `bp-canvas-card bp-card` with children wrapped in `bp-card__t`/`__d`/`__media`/`__action` (card-node.js:157-161,236) | Edit mirrors the LEGACY `cards` fleet chrome (`Components.cards_html`, components.ex:308-310), NOT the reader `card` widget. Shared CSS `.bp-card h3` vs `.bp-card__t` will not cross-apply → wrong look. `__cards.test.mjs` is round-trip only. |
| S11 | **section-grid-parity** | `bp-section__grid` (`--bp-tracks`, `--bp-grid-gap`) with `bp-section__cell` per child (compose.ex ~967) | `bp-canvas-section` with `bp-section__title` + `bp-section__body` — NO `bp-section__grid`/`__cell`, no track vars (section-node.js:249-266) | Reader lays children on a CSS grid; edit stacks them in a plain body. `canvas_reader_parity_gate` §6 is a SELF-DECLARED WEAK textual proxy ("NOT render parity"). |
| S12 | **note-island-parity** | `bp-note` › `bp-note__k` (span) + `bp-note__d` (`<b>` lead + body) | `bp-canvas-note` › `bp-canvas-note__k`/`__lead`/`__body` inputs — its OWN class family, never the reader's `bp-note*` (note-node.js:119-134) | Two separate CSS producers hand-matched for one look; no assertion the island resembles `bp-note`. `__note.test.mjs` round-trip only. |
| S13 | **stage-island-parity** | `bp-pnode[ bp-pnode--src]` › `bp-pnode__k`/`__t`/`__d` (`Components.pipeline_html`) | `bp-canvas-stage[ --src]` with inputs (stage-node.js:143-197) | DESIGN-1 mandates `bp-canvas-stage` (§7 asserts only the NEGATIVE — no `bp-pnode` leak); nothing asserts the POSITIVE look-parity to `bp-pnode`. |
| S14 | **columns-parity-assertion** | `<div class="bp-cols" style="--bp-cols:N">` › `bp-cols__c` (walk/compose) | `renderHTML` `class:"bp-cols"` (columns-node.js:115-121), `bp-cols__c` (:150), non-first-class child → `bp-cols__atom` (:250) | Reuses reader classes (parity by construction) but `__columns.test.mjs` has 0 reader-parity refs — a reader `bp-cols` restructure or a node drift ships silently. |
| S15 | **terminal-parity-assertion** | `bp-term` › `bp-term__bar`(`__dots`/`__title`/`__live`) + `bp-term__body` + `bp-term__foot` | `bp-term bp-canvas-term` › `bp-term__bar`/`__title`(input)/`__live` (terminal-node.js:178-205) | Reuses reader classes; `__terminal.test.mjs` is round-trip only (1 ref). Verify `__body`/`__foot` structural coverage. |
| S16 | **table-parity-assertion** | `<table class="bp-table">` › `thead`/`tbody` › `bp-table__th`/`__td` (span cells) | `bp-canvas-table` wrapper + `table.bp-table` + col/row rails (table-node.js:243,270-285) | Reuses reader classes; `__table.test.mjs` round-trip only. |
| S17 | **action-preview-parity** | `<a class="bp-button[ bp-button--primary]">` | `bp-canvas-action` with a LIVE `bp-button` preview + edit islands (action-node.js:14-15,187-206) | Preview reuses reader classes but no test pins the preview to the reader button emitter. |

**Filed bugs** (under `paper-edit-parity-endgame`): S10 card-slot mismatch
(`parity2-bug-card-slot-chrome`); the `task-detail` reader has NO empty-state —
an unresolved task-detail returns `""` while sibling widgets render
`bp-tasks--empty` (components.ex:80-83,106 vs :39) (`parity2-bug-taskdetail-empty-state`).

Integration: S10-S13 are self-contained (card/section/note/stage node-views —
no shared partition). S14-S17 add assertions only (no node-view edit) → can batch.
Prefer LIVE-BUG slices (S10, then S11) first.
