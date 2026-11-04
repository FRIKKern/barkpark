// Barkpark's live shell must preserve the canvas code-overlay cascade independently
// from the package source. This host companion checks the CSS shipped on /papers and
// in Studio without making the package test depend on a Barkpark-only asset.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const sinks = {
  shell: readFileSync(new URL("../../priv/static/assets/bp-paper-editor-shell.css", import.meta.url), "utf8"),
};

// [ids, classes/attributes/pseudo-classes, types] for one selector (no :is/:where here).
const specificity = (selector) => {
  const s = selector.replace(/::[\w-]+/g, " ").replace(/\[[^\]]*\]/g, ".a");
  return [
    (s.match(/#[\w-]+/g) || []).length,
    (s.match(/\.[\w-]+|:(?!:)[\w-]+/g) || []).length,
    (s.match(/(^|[\s>+~])[a-z][\w-]*/gi) || []).length,
  ];
};
const beats = (a, b) => a[0] !== b[0] ? a[0] > b[0] : a[1] !== b[1] ? a[1] > b[1] : a[2] >= b[2];

const rules = (css) => [...css.replace(/\/\*[\s\S]*?\*\//g, "").matchAll(/([^{}@;]+)\{([^{}]*)\}/g)]
  .flatMap(([, selectors, body]) => selectors.split(",").map((selector) => ({ selector: selector.trim().replace(/\s+/g, " "), body })));
const sets = (body, prop) => new RegExp(`(^|;)\\s*${prop}\\s*:`).test(body);

for (const [name, css] of Object.entries(sinks)) {
  const all = rules(css);
  const layer = all.filter((r) => /\.bp-canvas-code-hl$/.test(r.selector));
  assert.equal(layer.length, 1, `${name}: one highlight-layer rule`);
  const [hl] = layer;
  for (const prop of ["font-size", "line-height", "padding", "font-family"]) {
    assert.ok(sets(hl.body, prop), `${name}: the highlight layer sets its own ${prop}`);
  }
  // Every rule that can also reach the <code> layer and sets metrics must lose to it.
  const rivals = all.filter((r) => /(^|[\s>])code$/.test(r.selector) &&
    ["font-size", "padding", "line-height", "font-family"].some((p) => sets(r.body, p)));
  assert.ok(rivals.length > 0, `${name}: the inline-code rival exists (the check is live)`);
  for (const rival of rivals) {
    assert.ok(beats(specificity(hl.selector), specificity(rival.selector)),
      `${name}: \`${hl.selector}\` must outrank \`${rival.selector}\` or the layer paints at inline-code metrics`);
  }
  const lang = all.find((r) => r.selector === ".bp-canvas-code-lang");
  assert.ok(lang, `${name}: language input rule`);
  assert.match(lang.body, /position: absolute; bottom: 100%;/, `${name}: the language input sits above the frame`);
  assert.doesNotMatch(lang.body, /\btop:\s*0/, `${name}: the language input never covers the first line`);
}

console.log("code overlay cascade: ok");
