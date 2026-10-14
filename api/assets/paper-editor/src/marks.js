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

import { Mark, Node } from "@tiptap/core";

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

// bpInlineOpaque — an inline node the editor has no UI for (a `chip`, or any
// type a newer writer stored), carried VERBATIM (task-a110126ce9111388). Before
// it, convert.js dropped a childless unknown inline node on load, so the first
// save of its paragraph deleted it from the stored document. It is an inert
// ATOM: the whole stored node rides the `node` attr and is written back
// byte-exact; the author can select or delete it as one unit but cannot type
// into it, so no edit can silently vanish on save. The attr is JSON-encoded
// through its DOM attribute so a DOM serialize -> parse (copy/paste) keeps it.
//
// The label follows the readers' inline object rule (task-85fee859cf3bfef6:
// inline.ex inline_object_text/1, inline-object-text.json): the first
// non-empty string of text, title, label, name, value; then children's text;
// then `[type]`, so View and Edit show the same words.
export function inlineOpaqueLabel(node) {
  if (!node || typeof node !== "object") return "";
  for (const key of ["text", "title", "label", "name", "value"]) {
    if (typeof node[key] === "string" && node[key] !== "") return node[key];
  }
  const plain = (n) => {
    if (!n || typeof n !== "object") return "";
    if (typeof n.value === "string") return n.value;
    if (typeof n.text === "string") return n.text;
    return Array.isArray(n.children) ? n.children.map(plain).join("") : "";
  };
  const text = Array.isArray(node.children) ? node.children.map(plain).join("") : "";
  return text !== "" ? text : `[${typeof node.type === "string" ? node.type : "inline"}]`;
}

export const InlineOpaque = Node.create({
  name: "bpInlineOpaque",
  inline: true,
  group: "inline",
  atom: true,
  selectable: true,
  draggable: false,
  addAttributes() {
    return {
      node: {
        default: null,
        parseHTML: (el) => {
          const raw = el.getAttribute("data-bp-inline-opaque");
          if (!raw) return null;
          try {
            return JSON.parse(raw);
          } catch {
            return null;
          }
        },
        renderHTML: (attrs) =>
          attrs.node == null ? {} : { "data-bp-inline-opaque": JSON.stringify(attrs.node) },
      },
    };
  },
  parseHTML() {
    return [{ tag: "span[data-bp-inline-opaque]" }];
  },
  renderHTML({ node, HTMLAttributes }) {
    const stored = node.attrs.node;
    return [
      "span",
      {
        ...HTMLAttributes,
        class: "bp-inline-opaque",
        contenteditable: "false",
        "data-bp-inline-type": stored && typeof stored.type === "string" ? stored.type : "",
      },
      inlineOpaqueLabel(stored),
    ];
  },
});
