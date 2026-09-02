// __divider_parity.test.mjs — S1 divider-glyph parity gate.
//
// The edit-canvas Divider ATOM must render the SAME §-on-a-hairline DOM the
// /papers article reader emits, not a bare `<hr>`. This pure-Node test (no DOM,
// no browser — mirrors __atom_chrome.test.mjs's source/spec-level pattern)
// asserts the renderHTML DOMOutputSpec matches the reader's structure so a
// future reader-side drift is caught in review.
//
// Reader target — Barkpark.PortableDoc.Render.Figures.section_divider_html/0
// (figures.ex:33-37), which emits exactly:
//   <div style="position:relative;text-align:center;margin:2.4rem 0;
//               border-top:1px solid var(--paper-rule, #e6e2d8)">
//     <span style="position:relative;top:-0.7rem;display:inline-block;
//                  padding:0 0.8rem;background:var(--paper-bg, #f6faf9);
//                  color:var(--paper-ink-soft, #6a6a6a);font-size:1.1rem">§</span>
//   </div>
// The edit side binds the same tokens via a class (.bp-section-divider /
// .bp-section-divider__mark) instead of inline styles; this test locks the
// element structure + glyph + bp-attrs stamp + atom-ness.
//
// Run: node src/__divider_parity.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { Divider } from "./canvas/divider-node.js";

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

const spec = Divider.config.renderHTML({
  HTMLAttributes: { "data-bp-id": "d1", "data-bp-type": "divider" },
});

check("renderHTML outer element is the reader's <div>, NOT a bare <hr>", () => {
  assert.equal(spec[0], "div"); // reader outer <div> (figures.ex:34), the regression this fixes
  assert.notEqual(spec[0], "hr");
});

check("outer <div> carries the .bp-section-divider class + surviving bp-attrs stamp", () => {
  assert.ok(String(spec[1].class).includes("bp-section-divider"));
  assert.equal(spec[1]["data-bp-type"], "divider"); // bp-attrs stamp survives on the outer element
  assert.equal(spec[1]["data-bp-id"], "d1");
});

check("inner mark is a <span> holding the literal § glyph (figures.ex:36)", () => {
  const mark = spec[2];
  assert.equal(mark[0], "span"); // reader inner <span>
  assert.ok(String(mark[1].class).includes("bp-section-divider__mark"));
  assert.equal(mark[mark.length - 1], "§"); // the literal glyph
});

check("Divider stays an ATOM (no editable interior)", () => {
  assert.equal(Divider.config.atom, true);
});

check("parseHTML round-trips the § div AND legacy <hr> (paste + old content)", () => {
  assert.deepEqual(
    Divider.config.parseHTML().map((r) => r.tag),
    ["div.bp-section-divider", "div[data-bp-type='divider']", "hr"],
  );
});

console.log(failures === 0 ? "\nALL PASS" : `\n${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
