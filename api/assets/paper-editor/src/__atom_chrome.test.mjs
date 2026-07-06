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
// NO canvas node-view builds a `<button>` anymore. The callout fold — once the
// single documented `<button>` exception — moved to a native `<details>`/
// `<summary>` disclosure (loop-epic/parity-callout), the truer parity with the
// reader's own article disclosure (collapsible_callout_article/3). So the
// leaf-atom `<button>` guard below is satisfied by ALL canvas node-views; to keep
// it from passing vacuously we re-anchor the non-emptiness check on the callout's
// `<summary>` existence instead of a callout `<button>`.
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
// so their source must build none. (callout-node.js is deliberately absent — but
// no longer because it builds a button: its collapsible fold is now a native
// <details>/<summary> disclosure mirroring the reader, so it builds NO <button>
// either. It stays off this list only because it is a CONTENT node, not a leaf
// atom; its own shape is guarded by __callout_parity.test.mjs.)
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

check("callout fold is a native <summary> disclosure, not a <button> (guard is not vacuous)", () => {
  // The leaf-<button> guard above would be meaningless if the callout — the one
  // node-view that used to build a button — could silently drop ALL disclosure
  // chrome. The fold is now a native <details>/<summary> (loop-epic/parity-callout),
  // the truer reader parity. Anchor non-vacuousness on the <summary> existence:
  // if it disappears, the collapsible callout lost its disclosure and this fails.
  const callout = readSrc("canvas/callout-node.js");
  assert.ok(
    /createElement\(\s*["']summary["']\s*\)/.test(callout),
    "callout-node.js no longer builds a <summary> disclosure — the collapsible " +
      "callout must mirror the reader's native <details>/<summary> fold.",
  );
  assert.ok(
    !/createElement\(\s*["']button["']\s*\)/.test(callout),
    "callout-node.js builds a <button> again — the fold moved to a native " +
      "<details>/<summary>; an edit-only button is forbidden chrome (rule 6).",
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
