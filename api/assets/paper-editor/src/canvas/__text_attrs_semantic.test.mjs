import assert from "node:assert/strict";
import { JSDOM } from "jsdom";
import { texToMathMlRow } from "./equation-mathml.js";
import { Divider } from "./divider-node.js";
import { Blockquote } from "./role-nodes.js";

assert.equal(texToMathMlRow("E = mc^2"),
  "<mi>E</mi><mo>=</mo><mi>m</mi><msup><mrow><mi>c</mi></mrow><mrow><mn>2</mn></mrow></msup>");
assert.equal(texToMathMlRow("\\frac{\\alpha}{x_2}"),
  "<mfrac><mrow><mrow><mi>α</mi></mrow></mrow><mrow><mrow><msub><mrow><mi>x</mi></mrow><mrow><mn>2</mn></mrow></msub></mrow></mrow></mfrac>");
assert.equal(texToMathMlRow("\\unknown<"),
  "<mtext>\\unknown</mtext><mo>&lt;</mo>", "unknown TeX remains visible and escaped");

const divider = Divider.config.renderHTML({ HTMLAttributes: {}, node: { attrs: {} } });
assert.equal(divider[1].style,
  "position:relative;text-align:center;margin:2.4rem 0;border-top:1px solid");
assert.equal(divider[2][1].style,
  "position:relative;top:-0.7rem;display:inline-block;padding:0 0.8rem;font-size:1.1rem");

const quote = Blockquote.config.renderHTML({
  HTMLAttributes: { "data-bp-type": "blockquote" },
  node: { attrs: { cite: "Alan Kay" } },
});
assert.equal(quote[1]["data-bp-cite"], undefined, "cite is reader content, not an editor-only root attr");
assert.deepEqual(quote.at(-1), ["cite", { class: "bp-blockquote__cite" }, "Alan Kay"]);

const { window } = new JSDOM("<!doctype html><body></body>");
globalThis.document = window.document;
const { ISLAND_SPECS } = await import("./island-node.js");
const equation = document.createElement("div");
ISLAND_SPECS.equation.preview({ tex: "E = mc^2", display: true }, equation);
assert.equal(equation.getAttribute("data-bp-conformance-root"), "");
assert.equal(equation.innerHTML,
  '<math display="block"><mi>E</mi><mo>=</mo><mi>m</mi><msup><mrow><mi>c</mi></mrow><mrow><mn>2</mn></mrow></msup></math>');
window.close();

console.log("canvas text-attribute semantic projections: ok");
