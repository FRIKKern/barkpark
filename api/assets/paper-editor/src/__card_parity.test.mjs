// __card_parity.test.mjs — S10 (card) edit ⇄ reader parity gate.
//
// The card WIDGET node-view (card-node.js bpCard) must mount the reader's MODEL-B
// DOM — the shape `Components.card_html/2` (components.ex) emits by recursing each
// slot through the ONE shared compose→walk bridge. This gate locks the MOUNTED
// node-view SHAPE against that reader producer (the __section_parity.test.mjs twin),
// and is the fast local tripwire for the model-A regression the Elixir parity gate
// §3 forbids repo-wide (canvas_reader_parity_gate_test.exs: `bp-card__` is back in
// the forbidden-literal list — S10, parity2-bug-card-slot-chrome).
//
// WHY SPEC/SOURCE, NOT jsdom: a TipTap NodeView cannot mount without a browser
// (addNodeView's factory calls `document.createElement`), so — like
// __section_parity.test.mjs and __divider_parity.test.mjs — this test asserts
// (1) the IMPORTABLE spec (schema-fallback renderHTML, present-only attrs) and
// (2) the node-view SOURCE that builds the DOM. Both run in pure Node.
//
// ── READER GROUND TRUTH (verified in this slice, 2026-07-11) ──────────────────
//   card_html/2 (components.ex:349-381) renders ONE card, slots recursed in the
//   ORDER media, title, body, action, inside the tone-accented container:
//     <div class="bp-card[ bp-card--<tone>]">                ← tone allowlist
//                                                              info|ok|warn|danger
//       <img src alt style="max-width:100%;height:auto"[ width height]>
//                                                            ← media (walk.ex image/1
//                                                              :887 — a BARE img,
//                                                              NO wrapper div)
//       <h2>TITLE</h2>                                       ← title (PdHeading,
//                                                              default level 2,
//                                                              walk.ex heading :338)
//       <p>…inline…</p>                                      ← body (PdParagraph,
//                                                              classless, walk.ex
//                                                              paragraph :298)
//       <a href class="bp-button[ bp-button--primary]">LABEL</a>
//                                                            ← action (walk.ex
//                                                              button/2 :851 — the
//                                                              BINARY priority
//                                                              collapse)
//     </div>
//   Absent slots are OMITTED by the reader; the node-view keeps hidden
//   (display:none) placeholder elements — present-only paint, the established
//   canvas pattern. NO `bp-card__t/__d/__media/__action` chrome exists in model B
//   (card_widget_test.exs:96-102 REFUTES it); those literals remain legal ONLY in
//   the reader's legacy `cards` fleet grid (components.ex cards_html/1).
//
// Run: node src/__card_parity.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import {
  Card,
  BP_CARD_NODE_NAME,
  BP_CARD_BP_TYPE,
} from "./canvas/card-node.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const readSrc = (rel) => readFileSync(join(__dirname, rel), "utf8");
const SRC = readSrc("./canvas/card-node.js");

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

// ── 1. FORBIDDEN: the model-A slot chrome is gone from the WHOLE file ─────────
// The local fast twin of the Elixir §3 forbidden-literal gate: card-node.js may
// not contain the legacy card slot-chrome class prefix ANYWHERE (code or comment)
// — the reader dropped it in model B, so emitting it can only be a hand-written
// second producer (the exact WYSIWYG break S10 fixed).
check("card-node.js carries NO bp-card__ literal (model-A chrome is dead)", () => {
  assert.ok(
    !SRC.includes("bp-card_" + "_"),
    "card-node.js contains the forbidden model-A slot-chrome literal — the reader has no such chrome (card_widget_test.exs refutes it); emit the model-B bare-semantic shape instead",
  );
});

// ── 2. SPEC: the schema-fallback renderHTML is chrome-free with a single content
//        hole — slot chrome lives ONLY in the node-view, so a non-editable export
//        / setContent round-trip never mis-parses it ──────────────────────────
check("schema-fallback renderHTML is a chrome-free div + one content hole", () => {
  const spec = Card.config.renderHTML({
    HTMLAttributes: { "data-bp-id": "c1", "data-bp-type": "card" },
  });
  assert.equal(spec[0], "div", "outer element must be a <div>");
  assert.equal(spec[1]["data-bp-type"], "card", "outer carries the bp-attrs type stamp");
  const body = spec[2];
  assert.equal(body[0], "div");
  assert.ok("data-card-body" in body[1], "the fallback body div is the content hole");
  assert.equal(body[body.length - 1], 0, "the content hole is PM's `0` inline region");
  assert.equal(BP_CARD_NODE_NAME, "bpCard");
  assert.equal(BP_CARD_BP_TYPE, "card");
});

// ── 3. SPEC: chrome attrs are PRESENT-ONLY (absent round-trips ABSENT — the
//        reader omits absent slots; a spurious default would emit a phantom op) ─
check("tone/title/media/action attrs are present-only (null renders NO data-attr)", () => {
  const attrs = Card.config.addAttributes();
  assert.deepEqual(attrs.tone.renderHTML({ tone: null }), {}, "null tone ⇒ NO data-tone");
  assert.deepEqual(attrs.title.renderHTML({ title: null }), {}, "null title ⇒ NO data-title");
  assert.deepEqual(attrs.media.renderHTML({ media: null }), {}, "null media ⇒ NO data-media");
  assert.deepEqual(attrs.action.renderHTML({ action: null }), {}, "null action ⇒ NO data-action");
  assert.deepEqual(
    attrs.title.renderHTML({ title: "Hi" }),
    { "data-title": "Hi" },
    "a set title rides data-title",
  );
});

// ── 4. SOURCE: the four slots mount the reader's model-B elements ─────────────
check("title slot is a semantic <h2> island (reader: PdHeading default level 2)", () => {
  assert.ok(
    /const titleEl = document\.createElement\("h2"\);/.test(SRC),
    "title island is no longer an <h2> — the reader renders the title slot as <h2>",
  );
});

check("body slot: the contentDOM IS a <p> (reader: classless PdParagraph)", () => {
  assert.ok(
    /const body = document\.createElement\("p"\);/.test(SRC),
    "body contentDOM is no longer a <p> — the reader renders the body slot as <p>…</p>",
  );
  assert.ok(/contentDOM:\s*body/.test(SRC), "contentDOM is no longer the body element");
});

check("media slot is a BARE <img> with the reader's inline geometry (no wrapper)", () => {
  assert.ok(
    /const mediaImg = document\.createElement\("img"\);/.test(SRC),
    "media slot lost its bare <img>",
  );
  assert.ok(
    /mediaImg\.style\.maxWidth\s*=\s*"100%"/.test(SRC) &&
      /mediaImg\.style\.height\s*=\s*"auto"/.test(SRC),
    "media <img> lost the reader's inline max-width:100%;height:auto (walk.ex image/1)",
  );
  assert.ok(
    !/createElement\("div"\)[\s\S]{0,120}appendChild\(mediaImg\)/.test(SRC),
    "media <img> gained a wrapper div — the reader emits a BARE img (model B)",
  );
});

check("action slot is the reader's PdButton anchor with the binary priority collapse", () => {
  assert.ok(
    /const actionLink = document\.createElement\("a"\);/.test(SRC),
    "action slot lost its anchor",
  );
  assert.ok(
    /\?\s*"bp-button bp-button--primary"/.test(SRC) && /:\s*"bp-button";/.test(SRC),
    "action anchor no longer mirrors walk.ex button/2's class collapse (bp-button / bp-button--primary)",
  );
});

// ── 5. SOURCE: reader slot ORDER media, title, body, action (controls ride at
//        the top, OUTSIDE the reader-shape subtree) ────────────────────────────
check("mounted order is controls, media, title, body, action (reader slot order)", () => {
  assert.ok(
    /dom\.append\(controls, mediaImg, titleEl, body, actionLink\);/.test(SRC),
    "the mounted slot order no longer matches the reader's media, title, body, action",
  );
});

// ── 6. SOURCE: the container carries the reader's bp-card + tone modifier, plus
//        the edit-only mount hook + round-trip stamp (the section-node precedent) ─
check("root carries bp-card + tone modifier via the reader's exact allowlist", () => {
  assert.ok(
    /dom\.className = `bp-canvas-card bp-card\$\{cardToneClass\(a\.tone\)\}`/.test(SRC),
    "root lost its bp-canvas-card mount hook + bp-card reader class + tone modifier paint",
  );
  assert.ok(
    /const CARD_TONES = \["info", "ok", "warn", "danger"\];/.test(SRC),
    "tone allowlist no longer byte-matches the reader's info|ok|warn|danger (card_html/2)",
  );
  assert.ok(
    /dom\.setAttribute\("data-bp-type", "card"\)/.test(SRC),
    "root lost its data-bp-type round-trip stamp",
  );
});

// ── 7. DIVERGENCE (justified) — EDIT-ONLY CONTROLS: the reader has no controls
//        bar. VERDICT: JUSTIFY — it is display:none whenever the editor is NOT
//        editable (view mode = the reader-parity target) and sits at opacity:0
//        until hover/focus in edit mode. Lock the load-bearing invariant. ───────
check("controls are edit-only — display:none when not editable (view = reader)", () => {
  assert.ok(
    /controls\.style\.display = editor\.isEditable \? "" : "none";/.test(SRC),
    "controls are no longer hidden (display:none) in view mode — edit chrome would leak into the reader-parity view",
  );
});

// ── 8. DIVERGENCE (justified) — PRESENT-ONLY placeholders: the reader OMITS an
//        absent slot; the node-view keeps a hidden element (display:none) so the
//        paint can toggle without rebuilding. Lock both hide paths. ─────────────
check("absent media/action slots hide their elements (reader omits them)", () => {
  assert.ok(
    /mediaImg\.style\.display = "none";/.test(SRC),
    "an absent media slot no longer hides its <img>",
  );
  assert.ok(
    /actionLink\.style\.display = "none";/.test(SRC),
    "an absent action slot no longer hides its anchor",
  );
});

console.log(failures === 0 ? "\nALL PASS" : `\n${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
