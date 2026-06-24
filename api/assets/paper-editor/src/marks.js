// marks.js — internal-link TipTap marks (wikilink / blockref / tag).
//
// DOM-free on purpose: this module imports only `@tiptap/core` (which loads in
// plain Node), so the pure-Node smoke harness can import these marks and assert
// their schema (name + attrs) matches what convert.js reads — WITHOUT pulling in
// index.js, which extends HTMLElement and crashes outside a browser.
//
// SCHEMA-ONLY: these marks exist so the editor can HOLD wikilink/blockref/tag
// through a setContent -> getJSON round-trip (without them, ProseMirror drops
// unknown marks when loading a paper that already contains internal links).
// convert.js does the portable-doc translation; the attrs here mirror exactly
// what it reads. NO trigger/autocomplete UI here (that is the Phase-3 task).
// `inclusive:false` keeps a leaf mark from bleeding onto adjacent typed text.

import { Mark } from "@tiptap/core";

export function internalLinkMark(name, attrs) {
  return Mark.create({
    name,
    inclusive: false,
    addAttributes() {
      return attrs;
    },
    parseHTML() {
      return [{ tag: `span[data-${name}]` }];
    },
    renderHTML({ HTMLAttributes }) {
      return ["span", { ...HTMLAttributes, [`data-${name}`]: "" }, 0];
    },
  });
}

export const Wikilink = internalLinkMark("wikilink", {
  target: { default: "" },
  alias: { default: null },
  docId: { default: null },
});
export const Blockref = internalLinkMark("blockref", {
  target: { default: "" },
  anchor: { default: "" },
});
export const Tag = internalLinkMark("tag", { name: { default: "" } });
