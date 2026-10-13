// remote-selections.js — shared carets (task-d47c05259837093f).
//
// Two halves over one address, the Point:
//
//   Point = { blockId, path?, offset }
//
// `blockId` is the innermost node carrying a server block id (bpId), the id ops
// key by. `path` is present only when the caret sits in a node below that one:
// one `name[i]` segment per level, joined by ".", named by the child's role —
// `items[i]` (list / task item), `rows[i]`, `cells[i]` (table), `steps[i]` /
// `tabs[i]` (rows containers), `children[i]` otherwise. A list item's own text
// (its first paragraph) adds no segment, so the third bullet is `items[2]` and a
// table cell is `rows[1].cells[0]`. `offset` counts UTF-16 units of the node's
// plain text, an inline leaf (hard break, inline atom) counting as one.
//
// OUT: pointsFromSelection(state) → { anchor, head } for the canvas's
// `bp-canvas-selection` event.
// IN: a ProseMirror plugin holding the host's remote selections and painting
// each as a caret bar + name label (a widget) and, when anchor ≠ head, a
// translucent range (an inline decoration). Decorations only: setting them is a
// meta-only transaction (no doc change, no history entry, selection untouched).
// On a doc change each end is MAPPED (local typing, a block patched in place);
// when the block that held it was itself replaced (a whole-run re-seed, a
// reorder) the end is re-resolved from its Point; an end whose block or path is
// gone is dropped, and the remote with it.

import { Extension } from "@tiptap/core";
import { Plugin, PluginKey } from "@tiptap/pm/state";
import { Decoration, DecorationSet } from "@tiptap/pm/view";

export const remoteSelectionsKey = new PluginKey("bpRemoteSelections");

const ITEM_NODES = new Set(["listItem", "taskItem"]);
const ROLE_SEGMENT = {
  listItem: "items",
  taskItem: "items",
  bpTableRow: "rows",
  tableRow: "rows",
  bpTableCell: "cells",
  bpTableHeaderCell: "cells",
  tableCell: "cells",
  tableHeader: "cells",
  bpStep: "steps",
  bpTab: "tabs",
};

const idOf = (node) => {
  const id = node && node.attrs ? node.attrs.bpId : null;
  return typeof id === "string" && id !== "" ? id : null;
};

// The segment for descending from `parent` into its child `child` at `index`, or
// null when the step adds none (an item's own first paragraph).
function segment(parent, child, index) {
  if (child.isTextblock && index === 0 && ITEM_NODES.has(parent.type.name)) return null;
  return `${ROLE_SEGMENT[child.type.name] || "children"}[${index}]`;
}

// ── out: position → Point ─────────────────────────────────────────────────────

export function pointAt(doc, pos) {
  let $pos;
  try {
    $pos = doc.resolve(pos);
  } catch (_) {
    return null;
  }
  // Between blocks (a node selection on an atom): the node after, else before.
  if (!$pos.parent.isTextblock) {
    const beside = $pos.nodeAfter || $pos.nodeBefore;
    if (beside && idOf(beside)) return { blockId: idOf(beside), offset: 0 };
  }
  let depth = $pos.depth;
  while (depth > 0 && !idOf($pos.node(depth))) depth--;
  if (depth === 0) return null;
  const blockId = idOf($pos.node(depth));
  const segments = [];
  for (let d = depth + 1; d <= $pos.depth; d++) {
    const seg = segment($pos.node(d - 1), $pos.node(d), $pos.index(d - 1));
    if (seg) segments.push(seg);
  }
  const point = { blockId };
  if (segments.length) point.path = segments.join(".");
  point.offset = $pos.parent.isTextblock && $pos.depth >= depth ? $pos.parentOffset : 0;
  return point;
}

export function pointsFromSelection(state) {
  const { anchor, head } = state.selection;
  const a = pointAt(state.doc, anchor);
  const h = pointAt(state.doc, head);
  return a && h ? { anchor: a, head: h } : null;
}

// ── in: Point → position ──────────────────────────────────────────────────────

function findById(doc, id) {
  let hit = null;
  doc.descendants((node, pos) => {
    if (hit) return false;
    if (idOf(node) === id) {
      hit = { node, pos };
      return false;
    }
    return true;
  });
  return hit;
}

const SEGMENT_RE = /^([A-Za-z]+)\[(\d+)\]$/;

// The position a Point names in `doc`, plus the start of its id-bearing block
// (`blockPos`, what a later mapping checks for replacement). null when the block
// or the path is gone.
export function resolvePoint(doc, point) {
  if (!point || typeof point.blockId !== "string") return null;
  const hit = findById(doc, point.blockId);
  if (!hit) return null;
  let { node, pos } = hit;
  const blockPos = pos;
  if (point.path != null && point.path !== "") {
    for (const seg of String(point.path).split(".")) {
      const m = SEGMENT_RE.exec(seg);
      if (!m) return null;
      const index = Number(m[2]);
      if (index >= node.childCount) return null;
      const child = node.child(index);
      if ((ROLE_SEGMENT[child.type.name] || "children") !== m[1]) return null;
      let childPos = pos + 1;
      for (let i = 0; i < index; i++) childPos += node.child(i).nodeSize;
      node = child;
      pos = childPos;
    }
  }
  // A list item's text is its first paragraph.
  if (ITEM_NODES.has(node.type.name) && node.firstChild && node.firstChild.isTextblock) {
    node = node.firstChild;
    pos += 1;
  }
  if (!node.isTextblock) return { pos, blockPos };
  const offset = Number.isInteger(point.offset) && point.offset > 0 ? point.offset : 0;
  return { pos: pos + 1 + Math.min(offset, node.content.size), blockPos };
}

// ── the plugin ────────────────────────────────────────────────────────────────

// A color goes into a CSS custom property, so only plain color syntax passes.
const COLOR_RE = /^(#[0-9a-fA-F]{3,8}|(rgb|rgba|hsl|hsla)\([0-9.,%\s/+-]+\)|[a-zA-Z]{1,30})$/;
const safeColor = (c) => (typeof c === "string" && COLOR_RE.test(c.trim()) ? c.trim() : "#888");

function resolveEnd(doc, point) {
  const r = resolvePoint(doc, point);
  return r ? { point, pos: r.pos, blockPos: r.blockPos } : null;
}

function mapEnd(tr, end) {
  if (tr.mapping.mapResult(end.blockPos, 1).deleted) return resolveEnd(tr.doc, end.point);
  const pos = tr.mapping.map(end.pos, 1);
  const point = pointAt(tr.doc, pos);
  if (!point) return resolveEnd(tr.doc, end.point);
  const r = resolvePoint(tr.doc, point);
  return r ? { point, pos, blockPos: r.blockPos } : null;
}

// Keep only well-formed entries; resolve each against `doc`, dropping the ones
// whose block or path is gone.
function resolveList(doc, list) {
  const out = [];
  for (const item of Array.isArray(list) ? list : []) {
    if (!item || typeof item !== "object") continue;
    const anchor = resolveEnd(doc, item.anchor);
    const head = resolveEnd(doc, item.head);
    if (!anchor || !head) continue;
    out.push({
      id: String(item.id ?? ""),
      name: String(item.name ?? ""),
      color: safeColor(item.color),
      anchor,
      head,
    });
  }
  return out;
}

function caretWidget(remote) {
  return () => {
    const caret = document.createElement("span");
    caret.className = "bp-remote-caret";
    caret.setAttribute("data-remote-id", remote.id);
    caret.setAttribute("aria-hidden", "true");
    caret.contentEditable = "false";
    caret.style.setProperty("--bp-remote-color", remote.color);
    const label = document.createElement("span");
    label.className = "bp-remote-caret__label";
    label.textContent = remote.name;
    caret.appendChild(label);
    return caret;
  };
}

function decorate(doc, remotes) {
  if (!remotes.length) return DecorationSet.empty;
  const decos = [];
  for (const r of remotes) {
    const from = Math.min(r.anchor.pos, r.head.pos);
    const to = Math.max(r.anchor.pos, r.head.pos);
    if (from !== to) {
      decos.push(Decoration.inline(from, to, {
        class: "bp-remote-selection",
        style: `--bp-remote-color: ${r.color}`,
        "data-remote-id": r.id,
      }));
    }
    decos.push(Decoration.widget(r.head.pos, caretWidget(r), {
      key: `bp-remote-${r.id}-${r.color}-${r.name}`,
      side: -1,
      ignoreSelection: true,
    }));
  }
  return DecorationSet.create(doc, decos);
}

export function remoteSelections() {
  return Extension.create({
    name: "bpRemoteSelections",
    addProseMirrorPlugins() {
      return [new Plugin({
        key: remoteSelectionsKey,
        state: {
          init: () => ({ remotes: [], decorations: DecorationSet.empty }),
          apply(tr, prev, _old, newState) {
            const meta = tr.getMeta(remoteSelectionsKey);
            let remotes;
            if (meta) {
              remotes = resolveList(newState.doc, meta.list);
            } else if (tr.docChanged && prev.remotes.length) {
              remotes = [];
              for (const r of prev.remotes) {
                const anchor = mapEnd(tr, r.anchor);
                const head = mapEnd(tr, r.head);
                if (anchor && head) remotes.push({ ...r, anchor, head });
              }
            } else {
              return prev;
            }
            return { remotes, decorations: decorate(newState.doc, remotes) };
          },
        },
        props: {
          decorations(state) {
            return remoteSelectionsKey.getState(state).decorations;
          },
        },
      })];
    },
  });
}

// Replace the whole set. A meta-only transaction: no doc change, no history
// entry, the local selection untouched.
export function setRemoteSelections(editor, list) {
  const { state, view } = editor;
  view.dispatch(state.tr.setMeta(remoteSelectionsKey, { list }).setMeta("addToHistory", false));
}

// The live set as Points, for tests and hosts that want to read it back.
export function remoteSelectionsState(editor) {
  const st = remoteSelectionsKey.getState(editor.state);
  return (st ? st.remotes : []).map((r) => ({
    id: r.id,
    name: r.name,
    color: r.color,
    anchor: r.anchor.point,
    head: r.head.point,
  }));
}
