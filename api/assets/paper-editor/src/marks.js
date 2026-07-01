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

// valueref — the inline live-value leaf (wire contract: the
// portabledoc-inline-liveref-taskchip-wire paper, §3). Schema registration only,
// exactly like the marks above: WITHOUT it, ProseMirror strips the mark on
// setContent → getJSON and one keystroke in the paragraph deletes the valueref
// permanently (in BOTH the per-block editor and the canvas). convert.js does the
// translation; the attrs here mirror exactly what it reads. `as`/`label` are
// RESERVED passthrough (never interpreted); `children` carries the D6
// dual-written fallback subtree VERBATIM — an ARRAY, so it is JSON-encoded
// through its DOM attribute (a default-rendered array would stringify to
// "[object Object]" and be mangled by any DOM serialize→parse cycle, e.g.
// copy/paste). The JSON getJSON/setContent path carries it natively.
export const Valueref = internalLinkMark("valueref", {
  target: { default: "" },
  field: { default: "" },
  as: { default: null },
  fallback: { default: null },
  label: { default: null },
  children: {
    default: null,
    parseHTML: (el) => {
      const raw = el.getAttribute("data-valueref-children");
      if (!raw) return null;
      try {
        return JSON.parse(raw);
      } catch {
        return null;
      }
    },
    renderHTML: (attrs) =>
      attrs.children == null
        ? {}
        : { "data-valueref-children": JSON.stringify(attrs.children) },
  },
});
