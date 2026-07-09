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
