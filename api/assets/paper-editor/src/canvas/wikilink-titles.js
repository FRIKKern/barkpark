// wikilink-titles.js — a document link's words, painted live from the host (contract 1.17.0).
//
// A wikilink stores its words in the body, so renaming the target leaves stale text. The host's
// `wikilinkResolve(docId)` answers `{ title }`, the target's current title; an un-aliased link (no alias, and
// its words are its stored target, as a picker pick writes them) paints that title instead of
// its words. Decorations only: the stored words stay in the document, hidden, so every save,
// diff and round-trip carries them byte-identical. A painted link reads as one unit (arrows
// step over it, Backspace and Delete at its edge remove it whole); a caret that lands inside it
// anyway shows the stored words, so what the author edits is what is stored.
//
// A target the host says is gone (`{ missing: true }`, from wikilinkResolve or linkPreviewSource)
// keeps its words and carries `data-missing`, for the host to style.

import { Extension } from "@tiptap/core";
import { Plugin, PluginKey, TextSelection } from "@tiptap/pm/state";
import { Decoration, DecorationSet } from "@tiptap/pm/view";

export const wikilinkTitlesKey = new PluginKey("bpWikilinkTitles");

export const linkKey = (attrs) => (attrs && attrs.docId ? `id:${attrs.docId}` : `t:${(attrs && attrs.target) || ""}`);

// A host answer as { title?, missing? }, or null for "paint the stored words".
export function readAnswer(answer) {
  if (!answer || typeof answer !== "object") return null;
  if (answer.missing === true) return { missing: true };
  return typeof answer.title === "string" && answer.title ? { title: answer.title } : null;
}

// Each run of text carrying one wikilink mark in a textblock that starts at `start`:
// { from, to, mark, words, marks }.
function blockRuns(block, start, out = []) {
  let run = null;
  block.forEach((child, offset) => {
    const at = start + offset;
    const mark = child.isText ? child.marks.find((m) => m.type.name === "wikilink") : null;
    if (run && mark && run.mark.eq(mark)) {
      run.to = at + child.nodeSize;
      run.words += child.text;
      run.marks = run.marks.filter((m) => m.isInSet(child.marks));
      return;
    }
    if (run) out.push(run);
    run = mark ? { from: at, to: at + child.nodeSize, mark, words: child.text, marks: child.marks } : null;
  });
  if (run) out.push(run);
  return out;
}

function linkRuns(doc) {
  const out = [];
  doc.descendants((node, pos) => {
    if (!node.isTextblock) return true;
    blockRuns(node, pos + 1, out);
    return false;
  });
  return out;
}

function liveTitle(run, info) {
  const { alias, target } = run.mark.attrs;
  if (!info || info.missing || !info.title || alias != null || run.words !== target) return null;
  return info.title === run.words ? null : info.title;
}

function label(title) {
  return () => {
    const el = document.createElement("span");
    el.className = "bp-wikilink-label";
    el.textContent = title;
    return el;
  };
}

function decorate(doc, known, inside) {
  if (!known.size) return DecorationSet.empty;
  const decorations = [];
  for (const run of linkRuns(doc)) {
    const info = known.get(linkKey(run.mark.attrs));
    if (info && info.missing) {
      decorations.push(Decoration.inline(run.from, run.to, { "data-missing": "" }));
      continue;
    }
    const title = liveTitle(run, info);
    if (!title || run.from === inside) continue;
    decorations.push(Decoration.widget(run.to, label(title), { side: -1, marks: run.marks, key: `bp-wl:${title}` }));
    decorations.push(Decoration.inline(run.from, run.to, { class: "bp-wikilink-stored", style: "display: none" }));
  }
  return DecorationSet.create(doc, decorations);
}

// The start of the live link the caret sits inside (edit mode), else null: its stored words
// show while the author edits them, and a caret move that changes nothing repaints nothing.
function caretInside(state, known, editable) {
  const { selection } = state;
  if (!editable() || !selection.empty || !known.size) return null;
  const $pos = selection.$head;
  if (!$pos.parent.isTextblock) return null;
  const run = blockRuns($pos.parent, $pos.start()).find((r) => r.from < $pos.pos && $pos.pos < r.to);
  return run && liveTitle(run, known.get(linkKey(run.mark.attrs))) ? run.from : null;
}

// A painted link reads as one unit: an arrow steps over it and Backspace or Delete at its edge
// removes it whole, so no key edits stored words the author cannot see.
function painted(state, pos, edge) {
  const st = wikilinkTitlesKey.getState(state);
  const $pos = state.doc.resolve(pos);
  if (!$pos.parent.isTextblock) return null;
  return blockRuns($pos.parent, $pos.start()).find((r) => r[edge] === pos && r.from !== st.inside && liveTitle(r, st.known.get(linkKey(r.mark.attrs)))) || null;
}

function handleKey(view, event, editable) {
  if (!editable() || event.metaKey || event.ctrlKey || event.altKey || event.isComposing) return false;
  const { state } = view;
  const { selection } = state;
  const step = { ArrowLeft: ["to", "from"], ArrowRight: ["from", "to"] }[event.key];
  if (step) {
    const run = painted(state, selection.head, step[0]);
    if (!run || (!event.shiftKey && !selection.empty)) return false;
    const anchor = event.shiftKey ? selection.anchor : run[step[1]];
    view.dispatch(state.tr.setSelection(TextSelection.create(state.doc, anchor, run[step[1]])).scrollIntoView());
    return true;
  }
  const edge = { Backspace: "to", Delete: "from" }[event.key];
  if (!edge || event.shiftKey || !selection.empty) return false;
  const run = painted(state, selection.head, edge);
  if (!run) return false;
  view.dispatch(state.tr.delete(run.from, run.to).scrollIntoView());
  return true;
}

// `host` is the canvas: `wikilinkResolve` is its callback, `_editable` its mode.
export function wikilinkTitles(host) {
  const editable = () => !!(host && host._editable);
  return Extension.create({
    name: "bpWikilinkTitles",
    addProseMirrorPlugins() {
      return [new Plugin({
        key: wikilinkTitlesKey,
        state: {
          init: () => ({ known: new Map(), generation: 0, inside: null, decorations: DecorationSet.empty }),
          apply(tr, prev, _old, state) {
            const meta = tr.getMeta(wikilinkTitlesKey);
            let { known, generation } = prev;
            if (meta && meta.refresh) generation += 1;
            if (meta && meta.clear) known = new Map();
            if (meta && meta.set) {
              known = new Map(known);
              for (const [key, info] of meta.set) {
                if (info) known.set(key, info);
                else known.delete(key);
              }
            }
            const inside = caretInside(state, known, editable);
            if (!meta && !tr.docChanged && inside === prev.inside) return prev;
            return { known, generation, inside, decorations: decorate(state.doc, known, inside) };
          },
        },
        view: (view) => {
          const asked = new Map();
          const ask = () => {
            const source = host && host._wikilinkResolve;
            if (typeof source !== "function") return;
            const { generation } = wikilinkTitlesKey.getState(view.state);
            for (const run of linkRuns(view.state.doc)) {
              const docId = run.mark.attrs.docId;
              if (!docId || asked.get(docId) === generation) continue;
              asked.set(docId, generation);
              const take = (answer) => {
                if (wikilinkTitlesKey.getState(view.state).generation !== generation) return;
                view.dispatch(view.state.tr.setMeta(wikilinkTitlesKey, { set: [[linkKey({ docId }), readAnswer(answer)]] }).setMeta("addToHistory", false));
              };
              new Promise((resolve) => resolve(source(docId))).then(take, () => take(null));
            }
          };
          ask();
          return {
            update(_view, prevState) {
              const now = wikilinkTitlesKey.getState(view.state);
              if (view.state.doc !== prevState.doc || now.generation !== wikilinkTitlesKey.getState(prevState).generation) ask();
            },
          };
        },
        props: {
          decorations(state) {
            return wikilinkTitlesKey.getState(state).decorations;
          },
          handleKeyDown: (view, event) => handleKey(view, event, editable),
        },
      })];
    },
  });
}

const dispatchMeta = (editor, meta) => {
  if (!editor || editor.isDestroyed) return;
  editor.view.dispatch(editor.state.tr.setMeta(wikilinkTitlesKey, meta).setMeta("addToHistory", false));
};

// Ask the host again for every link (a new callback, or a rename). What is painted now stays
// until each answer lands, so a refresh never flashes the stored words.
export function refreshWikilinkTitles(editor, clear) {
  dispatchMeta(editor, { refresh: true, clear });
}

// The hover card's answer for one link: missing marks it, anything else unmarks it.
export function setWikilinkMissing(editor, attrs, missing) {
  const st = editor && !editor.isDestroyed ? wikilinkTitlesKey.getState(editor.state) : null;
  if (!st) return;
  const key = linkKey(attrs);
  const was = st.known.get(key) || null;
  if (missing === !!(was && was.missing)) return;
  dispatchMeta(editor, { set: [[key, missing ? { missing: true } : null]] });
}

export function wikilinkInfo(editor, attrs) {
  const st = editor && !editor.isDestroyed ? wikilinkTitlesKey.getState(editor.state) : null;
  return (st && st.known.get(linkKey(attrs))) || null;
}
