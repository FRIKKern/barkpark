// __section_parity.test.mjs — S3 (section) edit ⇄ reader parity gate.
//
// The recursive editable SECTION container (section-node.js, shipped #1231; layout
// engine #1244; grid cells #1251) must render the SAME structure the /papers article
// reader emits. This gate locks the MOUNTED node-view DOM SHAPE against the reader's
// HTML producer, and gives each remaining micro-divergence an explicit
// RECONCILE-or-JUSTIFY verdict backed by reader evidence (the charter S3 precedent:
// "restructure … OR justify the delta in the parity test").
//
// It replaces the weak §6 TEXTUAL PROXY in
// api/test/barkpark/portable_doc/render/canvas_reader_parity_gate_test.exs (that test
// only grepped section-node.js for `gridColumn`/`order`/`data-bp-id` writes — it
// proved the paint path was not DELETED, never that the shape matches the reader).
//
// WHY SPEC/SOURCE, NOT jsdom: a TipTap NodeView cannot mount without a browser
// (addNodeView's factory calls `document.createElement`), so — like
// __atom_chrome.test.mjs and __divider_parity.test.mjs — this test asserts (1) the
// IMPORTABLE spec (content roster, schema-fallback renderHTML, present-only attrs)
// and (2) the node-view SOURCE that builds the DOM. Both run in pure Node.
//
// ── READER GROUND TRUTH (verified in this slice) ─────────────────────────────────
//   STACK (compose.ex compose_section_stack → walk.ex box/hr/text):
//     <div style="display:flex;flex-direction:column">        ← PdBox flex column (NO class)
//       <hr class="bp-hr">                                    ← leading PdHr
//       <span style="font-weight:bold">TITLE</span>           ← title PdText → walk.ex text/3
//                                                               L257 (a bare bold SPAN, NO class,
//                                                               ONLY when title set)
//       …children…
//       <hr class="bp-hr">                                    ← trailing PdHr
//     </div>
//   GRID (compose.ex section_grid_html):
//     <div style="display:flex;flex-direction:column">
//       <hr class="bp-hr">
//       <div class="bp-section__title" style="font-weight:bold">TITLE</div>  ← DIV in grid only
//       <div class="bp-section__grid" style="--bp-tracks:N;--bp-grid-gap:…">
//         <div class="bp-section__cell" style="grid-column:span N;order:K">child</div>  ← CELL wrapper
//         …
//       </div>
//       <hr class="bp-hr">
//     </div>
//   Shared reader CSS: `.bp-section__cell { min-width: 0 }` and `> :first-child {
//   margin-top: 0 }` (paper-surface.css:691-692, mirrored root.html.heex).
//
// Run: node src/__section_parity.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import {
  Section,
  BP_SECTION_CONTENT,
  BP_SECTION_NODE_NAME,
  BP_SECTION_BP_TYPE,
} from "./canvas/section-node.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const readSrc = (rel) => readFileSync(join(__dirname, rel), "utf8");
const SRC = readSrc("./canvas/section-node.js");

let failures = 0;
function check(name, fn) {
  try {
    fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures++;
    console.log(`FAIL  ${name}`);
    console.log(`      ${e.message}`);
  }
}

// ── 1. SPEC: the content roster forbids a nested section (the container-in-
//        container guard is the schema, not a runtime check) ──────────────────
check("BP_SECTION_CONTENT forbids nesting bpSection (schema is the guard)", () => {
  // The section body may hold any canvas child EXCEPT bpSection — a nested section
  // rides as a read-only bpOpaque carry (run-convert depth-guard). If PM could
  // AUTHOR bpSection inside the roster, setContent would either accept an illegal
  // nesting or LIFT it, restructuring data on open. The roster string is the guard.
  assert.ok(
    !/\bbpSection\b/.test(BP_SECTION_CONTENT),
    `BP_SECTION_CONTENT must NOT list bpSection (found it): ${BP_SECTION_CONTENT}`,
  );
  // Non-vacuous: it IS a real roster (paragraph/heading canvas children + the
  // bpOpaque verbatim carry that stops a non-canvas child from being lifted out).
  for (const t of ["paragraph", "heading", "callout", "divider", "bpOpaque"]) {
    assert.ok(
      new RegExp(`\\b${t}\\b`).test(BP_SECTION_CONTENT),
      `BP_SECTION_CONTENT lost its ${t} child — the roster no longer tracks the canvas node set`,
    );
  }
});

// ── 2. SPEC: the schema-fallback renderHTML is chrome-free with a single content
//        hole — chrome (HRs/title/controls) lives ONLY in the node-view, so a
//        non-editable export / setContent round-trip never mis-parses it ───────
check("schema-fallback renderHTML is a chrome-free div + one content hole", () => {
  const spec = Section.config.renderHTML({
    HTMLAttributes: { "data-bp-id": "s1", "data-bp-type": "section" },
  });
  assert.equal(spec[0], "div", "outer element must be a <div>");
  assert.equal(spec[1]["data-bp-type"], "section", "outer carries the bp-attrs type stamp");
  // The fallback holds a single body hole (`0`) and NO title/HR chrome — the reader
  // stack/grid chrome is emitted by the node-view, never the schema fallback.
  const body = spec[2];
  assert.equal(body[0], "div");
  assert.ok("data-section-body" in body[1], "the fallback body div is the content hole");
  assert.equal(body[body.length - 1], 0, "the content hole is PM's `0` block+ region");
  assert.equal(BP_SECTION_NODE_NAME, "bpSection");
  assert.equal(BP_SECTION_BP_TYPE, "section");
});

// ── 3. SPEC: title is PRESENT-ONLY (a null title round-trips ABSENT, never "") —
//        byte-mirrors the reader, which emits NO title node when unset ─────────
check("title attr is present-only — null renders no data-title (reader emits no title)", () => {
  const attrs = Section.config.addAttributes();
  assert.deepEqual(attrs.title.renderHTML({ title: null }), {}, "null title ⇒ NO data-title");
  assert.deepEqual(
    attrs.title.renderHTML({ title: "Hi" }),
    { "data-title": "Hi" },
    "a set title rides data-title",
  );
});

// ── 4. SOURCE: the mounted node-view shape — the DOM the reader must match ────
//
// contentDOM body: PM fills `bp-section__body`; chrome sits OUTSIDE it.
check("contentDOM is the bp-section__body hole (chrome is outside PM content)", () => {
  assert.ok(
    /body\.className\s*=\s*"bp-section__body"/.test(SRC),
    "node-view body is no longer class bp-section__body",
  );
  assert.ok(/contentDOM:\s*body/.test(SRC), "contentDOM is no longer the body element");
});

// Grid mode swaps the body to the SHARED reader class (parity by construction, no
// second producer) — never a hand-mirrored grid.
check("grid mode uses the SHARED bp-section__grid class, not a hand-rolled grid", () => {
  assert.ok(
    /body\.className\s*=\s*"bp-section__grid"/.test(SRC),
    "grid mode no longer swaps the body to the shared bp-section__grid class",
  );
});

// The wrapper still carries the reader's inline flex-column (route a — no reader
// change): the geometry matches even though the class differs (see divergence b).
check("wrapper carries the reader's inline display:flex;flex-direction:column", () => {
  assert.ok(/dom\.style\.display\s*=\s*"flex"/.test(SRC), "wrapper lost display:flex");
  assert.ok(
    /dom\.style\.flexDirection\s*=\s*"column"/.test(SRC),
    "wrapper lost flex-direction:column",
  );
});

// ── 5. DIVERGENCE (a) — STACK TITLE: reader <span style=font-weight:bold> vs
//        editor <div class=bp-section__title style=font-weight:bold>.
//        VERDICT: JUSTIFY.
//        Reader stack title is a bare bold SPAN (walk.ex text/3 L257); the editor
//        renders a bold DIV with class `bp-section__title` (which the reader itself
//        uses in GRID mode, compose.ex section_grid_html). The delta is visually
//        INERT: (1) both apply `font-weight:bold` (the class rule is font-weight:700
//        == bold — no extra paint), so the typography is byte-matched; (2) inside a
//        `display:flex;flex-direction:column` container a <span> flex item is
//        blockified onto its own line exactly like a <div>, so the box is identical.
//        The class is LOAD-BEARING for editing (the contentEditable title island +
//        its data-test-id + hidden-when-empty reveal) — a bare classless span could
//        not carry that affordance. So we keep the class and JUSTIFY the delta. ───
check("(a) title binds font-weight:bold — typography byte-matches the reader span", () => {
  assert.ok(
    /titleEl\.className\s*=\s*"bp-section__title"/.test(SRC),
    "title element lost its bp-section__title binding",
  );
  assert.ok(
    /titleEl\.style\.fontWeight\s*=\s*"bold"/.test(SRC),
    "title lost font-weight:bold — it no longer matches the reader's bold span/div",
  );
});

// ── 6. DIVERGENCE (b) — WRAPPER + CONTROLS: reader = classless flex-column div;
//        editor = `.bp-canvas-section` mount hook + `data-bp-type` stamp + a layout
//        controls toolbar.
//        VERDICT: JUSTIFY.
//        `.bp-canvas-section` is the node-view mount hook and `data-bp-type=section`
//        is the bp-attrs stamp parseHTML round-trips on (the reader needs neither).
//        The wrapper still carries the SAME inline flex-column (asserted above), so
//        the box matches. The controls toolbar is EDIT-ONLY chrome the reader lacks:
//        it is `display:none` whenever the editor is NOT editable (view mode = the
//        reader-parity target), and in edit mode it sits at opacity:0 until
//        hover/focus. RESIDUAL (honest): in edit mode the opacity:0 controls still
//        reserve a small top gap (margin:4px 0) — an accepted "editing IS previewing"
//        affordance delta, not present in view mode. We lock the load-bearing
//        invariant: controls VANISH (display:none) at rest in view mode. ──────────
check("(b) layout controls are edit-only — display:none when not editable (view = reader)", () => {
  assert.ok(
    /controls\.style\.display\s*=\s*editor\.isEditable\s*\?\s*""\s*:\s*"none"/.test(SRC),
    "controls are no longer hidden (display:none) in view mode — edit chrome would leak into the reader-parity view",
  );
  // The mount hook + stamp that JUSTIFY the wrapper-class delta must still be present.
  assert.ok(
    /dom\.className\s*=\s*"bp-canvas-section"/.test(SRC),
    "wrapper lost its bp-canvas-section mount hook",
  );
  assert.ok(
    /dom\.setAttribute\("data-bp-type",\s*"section"\)/.test(SRC),
    "wrapper lost its data-bp-type round-trip stamp",
  );
});

// ── 7. DIVERGENCE (c) — GRID CELLS: reader wraps each grid child in
//        `<div class="bp-section__cell" style="grid-column:span N;order:K">` carrying
//        `min-width:0` (paper-surface.css:691); the editor has NO wrapper.
//        VERDICT: RECONCILE (min-width) + JUSTIFY (wrapper absence + first-child).
//        The canvas CANNOT add the `.bp-section__cell` wrapper: a PM contentDOM child
//        IS the block, and emitting the `bp-section__cell` class would be a second
//        HTML producer (canvas_reader_parity_gate_test.exs §3 RED). So it mirrors the
//        wrapper's RESOLVED geometry onto the wrapper-less grid item — grid-column /
//        order keyed by data-bp-id (already shipped), AND, added in THIS slice, the
//        cell's `min-width:0` so a wide child (<pre>, a long word) cannot blow out its
//        `minmax(0,1fr)` track exactly as it can't in the reader. RESIDUAL (honest):
//        the reader cell's `> :first-child { margin-top: 0 }` is NOT mirrored — on the
//        wrapper-less item that would fight the block's own margin logic and the
//        empty-cell placeholder outline; left as a documented residual, not a
//        hand-mirror. §3 stays green because NONE of this introduces the class. ────
check("(c) grid items mirror the reader cell's min-width:0 (reconciled this slice)", () => {
  assert.ok(
    /el\.style\.minWidth\s*=\s*grid\s*\?\s*"0"\s*:\s*""/.test(SRC),
    "grid items no longer mirror the reader cell's min-width:0 — a wide child can blow out its 1fr track (reader can't)",
  );
});

check("(c) placement keyed by data-bp-id — reorder-safe, same key as reader/run-convert", () => {
  assert.ok(/gridColumn/.test(SRC), "per-child grid-column paint was removed");
  assert.ok(/\.order\b/.test(SRC), "per-child order paint was removed");
  assert.ok(
    /getAttribute\("data-bp-id"\)/.test(SRC),
    "child placement no longer keyed by data-bp-id — reorder-safety lost",
  );
});

// ── 8. §3 COROLLARY (no second producer): grid mode swaps the body to the SHARED
//        reader class `bp-section__grid` (asserted in check 4) rather than
//        hand-rolling `display:grid`. The canvas legitimately CANNOT reproduce the
//        reader's per-cell wrapper (a PM child is the block), so it mirrors geometry
//        onto the item — assert the paint does NOT hand-roll a grid via inline
//        `display:grid` (which would fork the shared class). ─────────────────────
check("grid layout rides the shared class, not a hand-rolled inline display:grid", () => {
  assert.ok(
    !/style\.display\s*=\s*"grid"/.test(SRC) && !/"display:\s*grid"/.test(SRC),
    "section-node.js hand-rolls an inline grid — it must ride the shared bp-section__grid class so the reader CSS applies (no second producer)",
  );
});

console.log(failures === 0 ? "\nALL PASS" : `\n${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
