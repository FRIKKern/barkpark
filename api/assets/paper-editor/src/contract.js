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
