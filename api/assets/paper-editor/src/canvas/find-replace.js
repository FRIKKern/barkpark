// find-replace.js — find in the paper, step through the matches, replace one or all.
//
// A ProseMirror plugin holds the query and the match list (positions over text nodes,
// recomputed on every doc change) and paints them as inline decorations
// (`bp-find-match`, the active one `bp-find-match--active`). The host drives it through
// the canvas element's methods (findSet / findNext / findPrev / findClear / replaceCurrent
// / replaceAll / findState) and draws its own bar; the canvas owns no chrome for it.
// A replace is ONE transaction (all matches, in reverse, so positions stay valid), so
// undo restores it in one step and run-convert emits one patch per touched block.

import { Extension } from "@tiptap/core";
import { Plugin, PluginKey, TextSelection } from "@tiptap/pm/state";
import { Decoration, DecorationSet } from "@tiptap/pm/view";

export const findReplaceKey = new PluginKey("bpFindReplace");

const EMPTY = { query: "", caseSensitive: false, matches: [], active: -1 };

// Every [from, to) of `query` in the doc's text nodes (a match never crosses a node).
export function findMatches(doc, query, caseSensitive) {
  if (!query) return [];
  const needle = caseSensitive ? query : query.toLowerCase();
  const matches = [];
  doc.descendants((node, pos) => {
    if (!node.isText) return true;
    const hay = caseSensitive ? node.text : node.text.toLowerCase();
    let i = hay.indexOf(needle);
    while (i !== -1) {
      matches.push({ from: pos + i, to: pos + i + query.length });
      i = hay.indexOf(needle, i + Math.max(1, query.length));
    }
    return true;
  });
  return matches;
}

function decorate(doc, st) {
  if (!st.matches.length) return DecorationSet.empty;
  return DecorationSet.create(doc, st.matches.map((m, i) =>
    Decoration.inline(m.from, m.to, { class: i === st.active ? "bp-find-match bp-find-match--active" : "bp-find-match" }),
  ));
}

// The active match nearest AFTER the selection (or the first), so "next" starts where the caret is.
function nearestActive(matches, selection) {
  if (!matches.length) return -1;
  const at = selection ? selection.from : 0;
  const i = matches.findIndex((m) => m.from >= at);
  return i === -1 ? 0 : i;
}

export function findReplace() {
  return Extension.create({
    name: "bpFindReplace",
    addProseMirrorPlugins() {
      return [new Plugin({
        key: findReplaceKey,
        state: {
          init: () => ({ ...EMPTY, decorations: DecorationSet.empty }),
          apply(tr, prev, _old, newState) {
            const meta = tr.getMeta(findReplaceKey);
            let st = prev;
            if (meta && meta.type === "set") {
              const matches = findMatches(newState.doc, meta.query, meta.caseSensitive);
              st = { query: meta.query, caseSensitive: meta.caseSensitive, matches, active: nearestActive(matches, newState.selection) };
            } else if (meta && meta.type === "active") {
              st = { ...prev, active: prev.matches.length ? ((meta.index % prev.matches.length) + prev.matches.length) % prev.matches.length : -1 };
            } else if (meta && meta.type === "clear") {
              st = { ...EMPTY };
            } else if (tr.docChanged && prev.query) {
              const matches = findMatches(newState.doc, prev.query, prev.caseSensitive);
              const active = matches.length ? Math.min(Math.max(prev.active, 0), matches.length - 1) : -1;
              st = { ...prev, matches, active };
            } else {
              return prev;
            }
            return { ...st, decorations: decorate(newState.doc, st) };
          },
        },
        props: {
          decorations(state) {
            return findReplaceKey.getState(state).decorations;
          },
        },
      })];
    },
  });
}

// ── host-facing helpers (called from the canvas element's methods) ─────────────

export function findState(editor) {
  const st = findReplaceKey.getState(editor.state) || EMPTY;
  return { query: st.query, count: st.matches.length, index: st.active, caseSensitive: st.caseSensitive };
}

export function findSet(editor, query, { caseSensitive = false } = {}) {
  const { state, view } = editor;
  view.dispatch(state.tr.setMeta(findReplaceKey, { type: "set", query: String(query || ""), caseSensitive }));
  scrollToActive(editor);
  return findState(editor);
}

export function findClear(editor) {
  editor.view.dispatch(editor.state.tr.setMeta(findReplaceKey, { type: "clear" }));
}

export function findStep(editor, delta) {
  const st = findReplaceKey.getState(editor.state);
  if (!st || !st.matches.length) return findState(editor);
  editor.view.dispatch(editor.state.tr.setMeta(findReplaceKey, { type: "active", index: st.active + delta }));
  scrollToActive(editor);
  return findState(editor);
}

function scrollToActive(editor) {
  const st = findReplaceKey.getState(editor.state);
  if (!st || st.active < 0) return;
  const m = st.matches[st.active];
  if (!m) return;
  try {
    const tr = editor.state.tr.setSelection(TextSelection.create(editor.state.doc, m.from, m.to)).scrollIntoView();
    editor.view.dispatch(tr);
  } catch (_) {}
}

// Replace the active match, then move to the next one. Returns the new state.
export function replaceCurrent(editor, replacement) {
  const st = findReplaceKey.getState(editor.state);
  if (!st || st.active < 0 || !st.matches[st.active]) return findState(editor);
  const m = st.matches[st.active];
  const tr = editor.state.tr.insertText(String(replacement ?? ""), m.from, m.to);
  editor.view.dispatch(tr);
  return findStep(editor, 0);
}

// Replace every match in ONE transaction (reverse order keeps earlier positions valid).
export function replaceAll(editor, replacement) {
  const st = findReplaceKey.getState(editor.state);
  if (!st || !st.matches.length) return { replaced: 0, ...findState(editor) };
  const text = String(replacement ?? "");
  let tr = editor.state.tr;
  for (let i = st.matches.length - 1; i >= 0; i--) tr = tr.insertText(text, st.matches[i].from, st.matches[i].to);
  editor.view.dispatch(tr);
  return { replaced: st.matches.length, ...findState(editor) };
}
