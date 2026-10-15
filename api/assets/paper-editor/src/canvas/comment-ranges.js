// comment-ranges.js — comments on a span of text (Sanity's inline comments).
//
// The host owns the comments; the canvas paints and tracks their spans. Each
// range is { id, anchor: Point, head: Point, active? } over the same Point as
// shared carets (./remote-selections.js). Decorations only: setting them is a
// meta-only transaction (no doc change, no history entry, selection untouched).
//
// On a doc change each range is MAPPED inward — text typed at either edge stays
// outside it, text typed inside grows it — and a block that was itself replaced
// re-resolves its end from the Point. A range whose text is all deleted (or whose
// block is gone) is dropped; the host reads that as a comment whose text is gone.
// When a mapping moves any range the canvas emits `bp-canvas-comment-ranges` with
// the live set, so the host can save the new Points.

import { Extension } from "@tiptap/core";
import { Plugin, PluginKey } from "@tiptap/pm/state";
import { Decoration, DecorationSet } from "@tiptap/pm/view";
import { pointAt, resolvePoint } from "./remote-selections.js";

export const commentRangesKey = new PluginKey("bpCommentRanges");

function resolveEnd(doc, point) {
  const r = resolvePoint(doc, point);
  return r ? { point, pos: r.pos, blockPos: r.blockPos } : null;
}

// `assoc` keeps the edge where it was: 1 for a start (text inserted at it goes
// before the range), -1 for an end (text inserted at it goes after).
function mapEnd(tr, end, assoc) {
  if (tr.mapping.mapResult(end.blockPos, 1).deleted) return resolveEnd(tr.doc, end.point);
  const pos = tr.mapping.map(end.pos, assoc);
  const point = pointAt(tr.doc, pos);
  if (!point) return resolveEnd(tr.doc, end.point);
  const r = resolvePoint(tr.doc, point);
  return r ? { point, pos, blockPos: r.blockPos } : null;
}

// Ends ordered by position; null when the span is empty.
function ordered(a, b) {
  if (!a || !b) return null;
  const [from, to] = a.pos <= b.pos ? [a, b] : [b, a];
  return from.pos < to.pos ? { from, to } : null;
}

function resolveList(doc, list) {
  const out = [];
  for (const item of Array.isArray(list) ? list : []) {
    if (!item || typeof item !== "object" || item.id == null) continue;
    const span = ordered(resolveEnd(doc, item.anchor), resolveEnd(doc, item.head));
    if (span) out.push({ id: String(item.id), active: item.active === true, ...span });
  }
  return out;
}

function decorate(doc, ranges) {
  if (!ranges.length) return DecorationSet.empty;
  return DecorationSet.create(doc, ranges.map((r) => Decoration.inline(r.from.pos, r.to.pos, {
    class: r.active ? "bp-comment-range bp-comment-range--active" : "bp-comment-range",
    "data-comment-id": r.id,
  }, { commentId: r.id })));
}

// The ids of the ranges covering `pos`, innermost (shortest) first.
function idsAt(ranges, pos) {
  return ranges
    .filter((r) => r.from.pos <= pos && pos <= r.to.pos)
    .sort((a, b) => (a.to.pos - a.from.pos) - (b.to.pos - b.from.pos))
    .map((r) => r.id);
}

// `host` is the canvas element: the plugin dispatches its events on it.
export function commentRanges(host) {
  return Extension.create({
    name: "bpCommentRanges",
    addProseMirrorPlugins() {
      return [new Plugin({
        key: commentRangesKey,
        state: {
          init: () => ({ ranges: [], decorations: DecorationSet.empty, moved: false }),
          apply(tr, prev, _old, newState) {
            const meta = tr.getMeta(commentRangesKey);
            if (meta) {
              const ranges = resolveList(newState.doc, meta.list);
              return { ranges, decorations: decorate(newState.doc, ranges), moved: false };
            }
            if (!tr.docChanged || !prev.ranges.length) return prev.moved ? { ...prev, moved: false } : prev;
            const ranges = [];
            for (const r of prev.ranges) {
              const span = ordered(mapEnd(tr, r.from, 1), mapEnd(tr, r.to, -1));
              if (span) ranges.push({ ...r, ...span });
            }
            const key = (list) => JSON.stringify(list.map((r) => [r.id, r.from.point, r.to.point]));
            return { ranges, decorations: decorate(newState.doc, ranges), moved: key(ranges) !== key(prev.ranges) };
          },
        },
        view: () => ({
          update(view) {
            const st = commentRangesKey.getState(view.state);
            if (st && st.moved && host && typeof host._scheduleCommentRangesEmit === "function") host._scheduleCommentRangesEmit();
          },
        }),
        props: {
          decorations(state) {
            return commentRangesKey.getState(state).decorations;
          },
          handleClick(view, pos) {
            const ids = idsAt(commentRangesKey.getState(view.state).ranges, pos);
            if (ids.length && host) {
              host.dispatchEvent(new CustomEvent("bp-canvas-comment-click", { bubbles: true, composed: true, detail: { id: ids[0] } }));
            }
            return false;
          },
        },
      })];
    },
  });
}

// Replace the whole set. A meta-only transaction: no doc change, no history
// entry, the local selection untouched.
export function setCommentRanges(editor, list) {
  const { state, view } = editor;
  view.dispatch(state.tr.setMeta(commentRangesKey, { list }).setMeta("addToHistory", false));
}

// The live set as Points, in document order, each with the text it spans.
export function commentRangesState(editor) {
  const st = commentRangesKey.getState(editor.state);
  return (st ? st.ranges : [])
    .slice()
    .sort((a, b) => a.from.pos - b.from.pos)
    .map((r) => ({
      id: r.id,
      anchor: r.from.point,
      head: r.to.point,
      text: editor.state.doc.textBetween(r.from.pos, r.to.pos, "\n", "￼"),
    }));
}

// The ids of the ranges the selection overlaps (a caret inside one counts).
export function commentsInSelection(editor) {
  const st = commentRangesKey.getState(editor.state);
  const { from, to } = editor.state.selection;
  return (st ? st.ranges : [])
    .filter((r) => (from === to ? r.from.pos < from && from < r.to.pos : r.from.pos < to && from < r.to.pos))
    .map((r) => r.id);
}
