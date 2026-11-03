// __divider_parity.test.mjs — S1 divider-glyph parity gate.
//
// The edit-canvas Divider ATOM must render the SAME §-on-a-hairline DOM the
// /papers article reader emits, not a bare `<hr>`. This pure-Node test (no DOM,
// no browser — mirrors __atom_chrome.test.mjs's source/spec-level pattern)
// asserts the renderHTML DOMOutputSpec matches the reader's structure so a
// future reader-side drift is caught in review.
//
// Reader target — Barkpark.PortableDoc.Render.Figures.section_divider_html/0,
// which emits exactly:
//   <div class="bp-section-divider"
//        style="position:relative;text-align:center;margin:2.4rem 0;border-top:1px solid">
//     <span class="bp-section-divider__mark"
//           style="position:relative;top:-0.7rem;display:inline-block;
//                  padding:0 0.8rem;font-size:1.1rem">§</span>
//   </div>
// The shared reader stylesheet binds the colour tokens through those classes;
// layout remains inline in both sinks. This test locks the element structure,
// exact layout, semantic-root selector, glyph, bp-attrs stamp and atom-ness.
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
  assert.equal(spec[1]["data-bp-conformance-root"], "");
  assert.equal(
    spec[1].style,
    "position:relative;text-align:center;margin:2.4rem 0;border-top:1px solid",
  );
});

check("inner mark is a <span> holding the literal § glyph (figures.ex:36)", () => {
  const mark = spec[2];
  assert.equal(mark[0], "span"); // reader inner <span>
  assert.ok(String(mark[1].class).includes("bp-section-divider__mark"));
  assert.equal(
    mark[1].style,
    "position:relative;top:-0.7rem;display:inline-block;padding:0 0.8rem;font-size:1.1rem",
  );
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
