// clipboard-slice.js — the canvas's own clipboard round-trips EXACTLY
// (task-57414d08eec4d151, found by the move matrix __move_matrix_mounted.test.mjs).
//
// A cut or copy writes the selection as HTML; a paste parses that HTML back. Every
// node whose rendered HTML does not parse back to itself loses content on the way:
// a diagram came back as an empty code block, the declared callout carry as the
// built-in callout with its text gone, an expandable's summary flattened into its
// body, a steps block emptied, a terminal's header flattened into paragraphs.
//
// So the copy also stamps the fragment's exact JSON on the clipboard HTML's first
// element (`data-bp-fragment`, beside ProseMirror's own `data-pm-slice`), and a
// paste that finds it rebuilds the very nodes that were copied. HTML from anywhere
// else (another app, an older bundle) has no stamp and takes the normal paste paths.
//
// THE STAMP IS UNTRUSTED. Any web page can put a crafted `data-bp-fragment` on
// the clipboard, so a paste rebuilds from it only when ALL of these hold, and
// otherwise falls back to the normal paste path:
//   1. the clipboard HTML is at most MAX_HTML bytes, checked before parsing;
//   2. every node and mark type it names exists in this canvas's schema;
//   3. no attribute string carries a script, an inline event handler or a
//      javascript:/data:text/html URL;
//   4. schema.nodeFromJSON builds every node and node.check() accepts it. That
//      also refuses any attribute the schema does not declare.
// Ids: a pasted block keeps its bpId only when the id is well-formed and NOT
// already in this document (the cut case: comments, backlinks and history
// anchored to the block follow it). An id already present (the copy case), a
// repeat within the paste, or a malformed one is cleared, and the canvas mints a
// fresh one. The server validates every op as well; this is defence in depth.

import { DOMSerializer, Fragment, Slice } from "@tiptap/pm/model";

const ATTR = "data-bp-fragment";
const MAX_HTML = 1024 * 1024;
const WELL_FORMED_ID = /^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$/;
// A script tag, an event handler INSIDE a tag (so code like `el.onclick = f` in a
// code block is not refused), or a javascript:/data:text/html URL.
const UNSAFE = /<\s*\/?\s*script|<[^>]*\son[a-z]+\s*=|javascript\s*:|data\s*:\s*text\/html/i;

// A clipboardSerializer: the schema's own serializer, plus the stamp. `getSchema`
// is read at copy time (the editor props are built before the editor exists).
export function exactClipboardSerializer(getSchema) {
  let base = null;
  return {
    serializeFragment(fragment, options, target) {
      base ||= DOMSerializer.fromSchema(getSchema());
      const out = base.serializeFragment(fragment, options, target);
      const first = out.firstChild;
      if (first && first.nodeType === 1) {
        try {
          first.setAttribute(ATTR, JSON.stringify(fragment.toJSON() || []));
        } catch (_e) {
          // Unserialisable content: the plain HTML still goes on the clipboard.
        }
      }
      return out;
    },
  };
}

// The exact slice a canvas copy put on this paste's clipboard, or null when there
// is none or it fails any of the four checks above. `doc` is the document being
// pasted into (its ids decide which pasted ids survive).
export function exactSliceFromClipboard(schema, event, doc = null) {
  const data = event && event.clipboardData;
  const html = data && typeof data.getData === "function" ? data.getData("text/html") : "";
  if (!html || html.length > MAX_HTML || !html.includes(ATTR)) return null;
  try {
    const parsed = new window.DOMParser().parseFromString(html, "text/html");
    const el = parsed.querySelector(`[${ATTR}]`);
    if (!el) return null;
    const raw = el.getAttribute(ATTR) || "";
    if (raw.length > MAX_HTML) return null;
    const json = JSON.parse(raw);
    if (!Array.isArray(json) || !json.every((n) => admissible(schema, n))) return null;
    const taken = doc ? idsIn(doc) : new Set();
    const nodes = json.map((n) => {
      const node = schema.nodeFromJSON(withIdsChecked(n, taken));
      node.check();
      return node;
    });
    // data-pm-slice = "<openStart> <openEnd> …context": the slice's open sides.
    // ProseMirror may wrap the first element (an <li> in a <ul>) and stamp the
    // wrapper, so read it from whichever element carries it.
    const sliced = parsed.querySelector("[data-pm-slice]");
    const [openStart, openEnd] = ((sliced && sliced.getAttribute("data-pm-slice")) || "0 0").split(" ").map((n) => parseInt(n, 10) || 0);
    return new Slice(Fragment.from(nodes), Math.max(0, openStart), Math.max(0, openEnd));
  } catch (_e) {
    // Malformed, or refused by nodeFromJSON / check().
    return null;
  }
}

// Any pasted or dropped slice, under the same id rule: a copy of a block this
// document holds reads as new, while a cut (the id is gone from the document) keeps
// its id. A drag that moves blocks within this canvas keeps them (the caller skips it).
export function sliceWithFreshIds(schema, slice, doc) {
  const json = slice.toJSON();
  if (!json) return slice;
  const taken = idsIn(doc);
  return Slice.fromJSON(schema, { ...json, content: json.content.map((n) => withIdsChecked(n, taken)) });
}

function idsIn(doc) {
  const taken = new Set();
  doc.descendants((n) => { if (n.attrs && typeof n.attrs.bpId === "string") taken.add(n.attrs.bpId); });
  return taken;
}

// Check 2 and 3: known node and mark types only, and no unsafe attribute string.
function admissible(schema, node) {
  if (!node || typeof node !== "object" || typeof node.type !== "string") return false;
  if (!Object.hasOwn(schema.nodes, node.type)) return false;
  if (!safeAttrs(node.attrs)) return false;
  for (const mark of node.marks || []) {
    if (!mark || typeof mark.type !== "string" || !Object.hasOwn(schema.marks, mark.type)) return false;
    if (!safeAttrs(mark.attrs)) return false;
  }
  if (node.content != null && !Array.isArray(node.content)) return false;
  // A text node has no children: one that claims some is a crafted shape.
  if (node.type === "text" && node.content != null) return false;
  return (node.content || []).every((child) => admissible(schema, child));
}

function safeAttrs(value) {
  if (typeof value === "string") return !UNSAFE.test(value);
  if (Array.isArray(value)) return value.every(safeAttrs);
  if (value && typeof value === "object") return Object.values(value).every(safeAttrs);
  return true;
}

// Keep a bpId only when it is well-formed, absent from the document and not a
// repeat within this paste; otherwise drop it (the attribute's default, null,
// applies, and the canvas mints a fresh id).
function withIdsChecked(node, taken) {
  const out = { ...node };
  if (node.attrs && typeof node.attrs === "object" && "bpId" in node.attrs) {
    const { bpId, ...attrs } = node.attrs;
    if (typeof bpId === "string" && WELL_FORMED_ID.test(bpId) && !taken.has(bpId)) {
      taken.add(bpId);
      attrs.bpId = bpId;
    }
    out.attrs = attrs;
  }
  if (Array.isArray(node.content)) out.content = node.content.map((child) => withIdsChecked(child, taken));
  return out;
}
