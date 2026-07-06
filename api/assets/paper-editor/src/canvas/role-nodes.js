// role-nodes.js — Phase-4: the ARTICLE-CHROME role-prose canvas nodes.
//
// eyebrow / byline / ingress / pullquote — the four typographic ROLE blocks the
// per-block editor renders as FORMS (paper_editor.ex paper_block_fields) — now
// mount INSIDE the continuous canvas as styled ProseMirror PROSE nodes that MATCH
// THE READER, not a form. The reader (walk.ex apply_text_role, compose.ex) emits
// each as ONE styled element carrying a `bp-role-*` CLASS with ZERO chrome (no
// icon, no fold, no frame — UNLIKE the callout, which needs a NodeView to paint
// its tone frame around a contentDOM). So each of these is a PLAIN TipTap
// `Node.create` whose `renderHTML` returns `["p", {…class…}, 0]` — PM derives the
// contentDOM from the `0` content hole. NO `addNodeView`.
//
// That keeps this module DOM-free (no `document`, no NodeView factory), so
// run-convert.js — which references only the node TYPES, never a view — stays
// importable in the pure-Node smoke harness, matching the divider-node / marks
// precedent (callout-node.js needs addNodeView ONLY because it paints chrome).
//
// ── CONTENT MODEL (verified against blocks.ex + compose.ex) ──────────────────
//
//   eyebrow  build_block_patch → %{"text" => …}      (a PLAIN string; compose.ex
//            reads Map.get(b,"text")). marks:"" — a bare string persist has no
//            place for marks, so we forbid them (inline* would silently DROP any
//            typed mark on save = data loss).
//   byline   build_block_patch → %{"items" => [...]} (split on "·", trimmed).
//            compose.ex re-joins items with " · ". Also a PLAIN string surface,
//            marks:"".
//   ingress  build_block_patch → %{"content" => [inline…]} — an inline array, the
//            SAME shared inline serializer paragraph/callout use → content:"inline*"
//            (marks work).
//   pullquote build_block_patch → %{"content" => [inline…]} — inline array,
//            content:"inline*". The reader (compose.ex) additionally stamps
//            `"italic" => true`, so walk.ex adds `font-style:italic` INLINE on the
//            element (NOT in the class). So this node's renderHTML emits
//            `style="font-style:italic"` to match the reader byte-for-byte; the
//            class stays italic-free on BOTH surfaces (parity clean).
//
// bpId / bpType ride each node as attrs on data-bp-id / data-bp-type — the SAME id
// contract as BpAttrs + callout-node.js. We self-declare them here (BpAttrs targets
// only paragraph/heading/list, not these role nodes), so getJSON() preserves the id
// run-convert.js keys the diff by. The `p[data-bp-type='<role>']` parse rule is
// SPECIFIC so paragraph keeps owning a bare `<p>` on paste/setContent.

import { Node, mergeAttributes } from "@tiptap/core";

// Shared attr skeleton: bpId + bpType on data-* (verbatim the callout-node.js
// pattern). bpType default is the node name so a freshly-minted node still carries
// its type; renderHTML omits an absent id so an id-less node round-trips clean.
function roleAttributes(name) {
  return {
    bpId: {
      default: null,
      parseHTML: (el) => el.getAttribute("data-bp-id"),
      renderHTML: (attrs) => (attrs.bpId ? { "data-bp-id": attrs.bpId } : {}),
    },
    bpType: {
      default: name,
      parseHTML: (el) => el.getAttribute("data-bp-type"),
      renderHTML: (attrs) =>
        attrs.bpType ? { "data-bp-type": attrs.bpType } : {},
    },
  };
}

// The eyebrow: an uppercase, letter-spaced, accent kicker. Reader class
// bp-role-eyebrow. content:"text*" + marks:"" — a plain string surface (its persist
// is a bare `text` string with no place for marks).
export const Eyebrow = Node.create({
  name: "eyebrow",
  group: "block",
  content: "text*",
  marks: "",
  defining: true,
  selectable: true,
  addAttributes() {
    return roleAttributes("eyebrow");
  },
  parseHTML() {
    return [{ tag: "p[data-bp-type='eyebrow']" }];
  },
  renderHTML({ HTMLAttributes }) {
    return [
      "p",
      mergeAttributes(HTMLAttributes, {
        "data-bp-type": "eyebrow",
        class: "bp-role-eyebrow",
      }),
      0,
    ];
  },
});

// The byline: a muted line with a bottom rule. Its persist is an `items` LIST
// joined/split on " · " — a plain string surface in the canvas (run-convert.js maps
// the joined display text ⇄ items). content:"text*" + marks:"".
export const Byline = Node.create({
  name: "byline",
  group: "block",
  content: "text*",
  marks: "",
  defining: true,
  selectable: true,
  addAttributes() {
    return roleAttributes("byline");
  },
  parseHTML() {
    return [{ tag: "p[data-bp-type='byline']" }];
  },
  renderHTML({ HTMLAttributes }) {
    return [
      "p",
      mergeAttributes(HTMLAttributes, {
        "data-bp-type": "byline",
        class: "bp-role-byline",
      }),
      0,
    ];
  },
});

// The ingress: the lead paragraph (heavier weight, larger size). Its persist is an
// inline `content` array (the shared serializer), so content:"inline*" — marks work
// exactly like a paragraph.
export const Ingress = Node.create({
  name: "ingress",
  group: "block",
  content: "inline*",
  defining: true,
  selectable: true,
  addAttributes() {
    return roleAttributes("ingress");
  },
  parseHTML() {
    return [{ tag: "p[data-bp-type='ingress']" }];
  },
  renderHTML({ HTMLAttributes }) {
    return [
      "p",
      mergeAttributes(HTMLAttributes, {
        "data-bp-type": "ingress",
        class: "bp-role-ingress",
      }),
      0,
    ];
  },
});

// The pullquote: italic serif, larger, muted, with a left rule. Its persist is an
// inline `content` array → content:"inline*". The reader stamps `italic:true`, which
// walk.ex renders as `font-style:italic` INLINE on the element (NOT in the class), so
// this renderHTML emits that inline style to match — the class stays italic-free on
// both surfaces so class-parity is clean.
export const Pullquote = Node.create({
  name: "pullquote",
  group: "block",
  content: "inline*",
  defining: true,
  selectable: true,
  addAttributes() {
    return roleAttributes("pullquote");
  },
  parseHTML() {
    return [{ tag: "p[data-bp-type='pullquote']" }];
  },
  renderHTML({ HTMLAttributes }) {
    return [
      "p",
      mergeAttributes(HTMLAttributes, {
        "data-bp-type": "pullquote",
        class: "bp-role-pullquote",
        style: "font-style:italic",
      }),
      0,
    ];
  },
});
