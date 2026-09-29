// The live Papers editor loads bp-paper-editor-shell.css, not the bundle's
// styles.css mirror. Table edit chrome that exists only in the mirror is
// unstyled on /papers: the column-resize grip layer fell into static flow,
// stacked above the table and covered the first header cell, so clicking that
// cell's text hit a grip instead of placing the caret.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const shell = readFileSync(new URL("../../../priv/static/assets/bp-paper-editor-shell.css", import.meta.url), "utf8");
const mirror = readFileSync(new URL("./styles.css", import.meta.url), "utf8");

const rules = (css) => {
  const out = new Map();
  for (const [, selectors, body] of css.replace(/\/\*[\s\S]*?\*\//g, "").matchAll(/([^{}@;]+)\{([^{}]*)\}/g)) {
    for (const selector of selectors.split(",")) out.set(selector.trim().replace(/\s+/g, " "), body.trim().replace(/\s+/g, " "));
  }
  return out;
};
const live = rules(shell);
const kept = rules(mirror);

assert.match(live.get(".bp-canvas-table__resizers") || "", /position: absolute; inset: 0;.*pointer-events: none/,
  "the grip layer overlays the table instead of stacking above it");
assert.match(live.get(".bp-canvas-table__resize") || "", /position: absolute; width: 7px;/,
  "each grip is a thin strip on its column edge, not a full-width block over the cells");
assert.match(live.get(".bp-canvas-table:hover .bp-canvas-table__resize") || "", /opacity: 1/,
  "grips stay hover-revealed");

// Every table edit-chrome selector the mirror styles must reach the live page with the same body.
for (const [selector, body] of kept) {
  if (!selector.includes("bp-canvas-table")) continue;
  assert.ok(live.has(selector), `${selector} is styled in styles.css but missing from the live shell`);
  assert.equal(live.get(selector), body, `${selector} differs between styles.css and the live shell`);
}

console.log("table shell chrome: ok");
