// __atom_chrome.test.mjs — pdd-t18b: the atomic-contract sweep guard (doctrine
// rule 6 / D13). Two layers, both pure-Node (no DOM, no browser):
//
//   1. The resting-chrome PREDICATE (`configControlHidden`, contract.js) — the
//      real logic behind hiding an empty optional config control (code `lang`,
//      diagram `caption`) until the frame is hovered/focused. Unit-tested here so
//      the "no resting chrome on an idle atom" rule is machine-checked, not just
//      eyeballed in the browser.
//
//   2. A data-driven STATIC-SOURCE guard over the canvas atom node-views. We
//      cannot mount a node-view without a browser, so instead of asserting the
//      live DOM we assert the SOURCE that builds it: a listed atom must not
//      construct bare `<button>` chrome (the audit's forbidden edit-only control),
//      and the two config-bearing atoms must keep the resting-chrome gate wired.
//      This locks the sweep's result: an atom cannot silently regrow button
//      chrome, and a refactor cannot silently drop the hover/focus reveal.
//
// The ONE allowed `<button>` is the callout fold — it mirrors the reader's own
// `<details>`/`<summary>` disclosure (article mode), so it exists in the rendered
// end result and is NOT edit-only chrome. It is excluded by omission from the
// leaf-atom list below (documented, not silently ignored).
//
// Run: node src/__atom_chrome.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { configControlHidden } from "./contract.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const readSrc = (rel) => readFileSync(join(__dirname, rel), "utf8");

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

// ── 1. configControlHidden — the resting-chrome predicate ────────────────────

check("configControlHidden: an empty, idle control is HIDDEN (no resting chrome)", () => {
  assert.equal(configControlHidden({ value: "", hovered: false, focused: false }), true);
  assert.equal(configControlHidden({ value: null, hovered: false, focused: false }), true);
  assert.equal(configControlHidden({ value: undefined, hovered: false, focused: false }), true);
  assert.equal(configControlHidden({ value: "   ", hovered: false, focused: false }), true);
  assert.equal(configControlHidden({ value: "\t\n ", hovered: false, focused: false }), true);
  // A missing arg object still reads as empty+idle → hidden (defensive default).
  assert.equal(configControlHidden(), true);
  assert.equal(configControlHidden({}), true);
});

check("configControlHidden: an empty control REVEALS on hover or focus", () => {
  assert.equal(configControlHidden({ value: "", hovered: true, focused: false }), false);
  assert.equal(configControlHidden({ value: "", hovered: false, focused: true }), false);
  assert.equal(configControlHidden({ value: "  ", hovered: true, focused: true }), false);
});

check("configControlHidden: a NON-empty control is always shown (idle or not)", () => {
  assert.equal(configControlHidden({ value: "python", hovered: false, focused: false }), false);
  assert.equal(configControlHidden({ value: "Figure 1. Flow", hovered: false, focused: false }), false);
  // Leading/trailing space around real content still counts as content.
  assert.equal(configControlHidden({ value: " js ", hovered: false, focused: false }), false);
});

// ── 2. Static-source guard — atoms carry no forbidden resting chrome ─────────

// The LEAF atom node-views whose rendered end result carries NO button chrome —
// so their source must build none. (callout-node.js is deliberately absent: its
// fold <button> mirrors the reader's <details> disclosure, a real affordance in
// the render, not edit-only chrome.)
const LEAF_ATOM_FILES = [
  "canvas/divider-node.js",
  "canvas/code-node.js",
  "canvas/diagram-node.js",
  "canvas/embed-node.js",
];

check("leaf atom node-views construct no bare <button> chrome", () => {
  for (const rel of LEAF_ATOM_FILES) {
    const src = readSrc(rel);
    assert.ok(
      !/createElement\(\s*["']button["']\s*\)/.test(src),
      `${rel} builds a <button> — atoms must carry no edit-only button chrome ` +
        `(fold visible actions into hover tooltips + context menus, per rule 6). ` +
        `If this button mirrors something the /papers reader actually renders, ` +
        `document it and move the file off LEAF_ATOM_FILES with a rationale.`,
    );
  }
});

check("callout fold IS the single documented <button> exception (guard is not vacuous)", () => {
  // Sanity: the guard would be meaningless if NO atom ever built a button. The
  // callout fold is the one allowed button — assert it still exists so a future
  // removal of ALL buttons doesn't leave the leaf guard passing vacuously.
  const callout = readSrc("canvas/callout-node.js");
  assert.ok(
    /createElement\(\s*["']button["']\s*\)/.test(callout),
    "callout-node.js no longer builds its fold <button> — if the fold moved, " +
      "revisit this guard's premise (the reader-<details> parity exception).",
  );
});

// The two config-bearing atoms must keep the resting-chrome gate wired: an empty
// optional control (lang / caption) stays hidden until interaction. Asserting the
// source references the shared predicate locks the fix against a silent regression
// back to an always-visible placeholder.
const CONFIG_GATE_FILES = ["canvas/code-node.js", "canvas/diagram-node.js"];

check("config-bearing atoms wire the resting-chrome gate (configControlHidden)", () => {
  for (const rel of CONFIG_GATE_FILES) {
    const src = readSrc(rel);
    assert.ok(
      /configControlHidden/.test(src),
      `${rel} no longer references configControlHidden — the empty lang/caption ` +
        `control would show at rest again (rule-6 resting chrome the reader never paints).`,
    );
    assert.ok(
      /focusin/.test(src) && /mouseenter/.test(src),
      `${rel} dropped the hover/focus reveal wiring — the gated config control ` +
        `would be unreachable (hidden with no way to reveal it).`,
    );
    assert.ok(
      /relatedTarget/.test(src),
      `${rel} dropped the focus-within (relatedTarget) guard in focusout — ` +
        `focusout fires BEFORE the next element gains focus, so hiding while ` +
        `focus merely MOVES within the atom yanks display:none onto the input ` +
        `mid-Tab and keyboard users can never reach it.`,
    );
  }
});

console.log(failures === 0 ? "\nALL PASS" : `\n${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
