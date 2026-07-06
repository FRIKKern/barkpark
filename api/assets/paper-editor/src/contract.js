// contract.js — DOM-free contract surface for bp-paper-editor (zero imports).
//
// Holds only plain constants — NO @tiptap, NO HTMLElement, NO DOM — so the
// pure-Node smoke harness can assert the embed contract without importing
// index.js (which extends HTMLElement and crashes outside a browser). index.js
// re-exports these; __smoke.mjs imports THIS module. See EMBED-CONTRACT.md.
export const CONTRACT_VERSION = "1.0.0";
export const DEBOUNCE_MS = 300;
export const PLACEHOLDER = {
  paragraph: "Start typing, or press / for blocks…",
  heading: (level) => `Heading ${level || 1}`,
};

// ── pdd-t18b: the atomic-contract resting-chrome rule (doctrine rule 6 / D13) ──
//
// A canvas atom's OPTIONAL config control (the code node's `lang`, the diagram
// node's `caption`) is edit-only chrome the /papers reader does NOT paint when
// empty: `Figures.code_block_html/1` ignores `lang` entirely, and a diagram's
// `figcaption` is emitted ONLY for a non-empty caption. So an EMPTY config input
// left showing at rest (its "lang" / "caption" placeholder) is chrome that won't
// exist in the rendered end result — a rule-6 violation.
//
// The doctrine fix is NOT to remove the editor (the control IS the value editor
// for a REAL config field) but to make it a HOVER/FOCUS affordance (rule 5:
// chrome appears on interaction, never at rest). This pure predicate decides
// visibility so the node-view stays a thin wire and the logic unit-tests in
// plain Node:
//   * a NON-empty value is always shown — a set caption RENDERS (figcaption
//     parity), and a set lang is meaningful config worth seeing at rest;
//   * an EMPTY control shows only while the frame is hovered or focus is inside
//     it (discoverable on interaction, incl. a keyboard user who focuses the
//     code/diagram textarea → focusin bubbles → the empty control reveals so it
//     is tabbable), and hides again when idle so the atom reads byte-identically
//     to the reader.
// Returns TRUE when the control should be hidden (display:none), FALSE to show.
export function configControlHidden({ value, hovered, focused } = {}) {
  const empty = value == null || String(value).trim() === "";
  if (!empty) return false;
  if (hovered || focused) return false;
  return true;
}
