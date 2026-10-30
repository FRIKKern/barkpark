// wikilink-input.js — a typed or pasted `[[Title]]` becomes a document link (contract 1.17.0, paste 1.18.0,
// alias 1.19.0).
//
// Typing the closing `]]`, or pasting text that holds `[[Title]]`, asks the host's
// `wikilinkSource(Title)`. Only a row whose title equals Title, ignoring case, turns the
// brackets into a link to that row, written as a picker pick writes it (its title as the words
// and the target, its id as the docId). Anything else leaves the text as typed. Text that
// arrives any other way (a seed, a server edit, undo) is never converted. `[[Title|words]]` asks for
// Title alone and, on a match, links the row with `words` as its alias.
//
// A paste asks once per distinct title (ignoring case), at most MAX_ASKS of them; the rest stay
// text. Its links land together, as one undo step after the paste's own. A Markdown paste writes
// its `[[Title]]` and `[[Title|words]]` back as brackets first, so the same rule decides.

import { Extension } from "@tiptap/core";
import { Plugin, PluginKey } from "@tiptap/pm/state";
import { closeHistory } from "@tiptap/pm/history";

export const wikilinkInputKey = new PluginKey("bpWikilinkInput");

const CLOSED = /\[\[([^[\]\n\ufffc]+)\]\]/g;
const CLOSED_AT_END = /\[\[([^[\]\n\ufffc]+)\]\]$/;

const blockText = (block) => block.textBetween(0, block.content.size, undefined, () => "\ufffc");

export function matchingRow(list, query) {
  if (!Array.isArray(list)) return null;
  const want = query.toLowerCase();
  return list.find((row) => row && typeof row.title === "string" && row.title.toLowerCase() === want &&
    typeof row.id === "string" && row.id) || null;
}

function bracketed(from, to, inner) {
  const pipe = inner.indexOf("|");
  const query = pipe === -1 ? inner : inner.slice(0, pipe);
  const alias = pipe === -1 ? null : inner.slice(pipe + 1);
  return query && alias !== "" ? { from, to, inner, query, alias } : null;
}

function closedIn(doc, from, to) {
  const found = [];
  doc.nodesBetween(from, to, (node, pos) => {
    if (!node.isTextblock) return true;
    const text = blockText(node);
    for (const m of text.matchAll(CLOSED)) {
      const start = pos + 1 + m.index;
      const end = start + m[0].length;
      const at = end > from && start < to && bracketed(start, end, m[1]);
      if (at) found.push(at);
    }
    return false;
  });
  return found;
}

function changedRanges(tr) {
  const ranges = [];
  tr.mapping.maps.forEach((map, i) => map.forEach((_a, _b, start, end) => {
    const rest = tr.mapping.slice(i + 1);
    ranges.push([rest.map(start, -1), rest.map(end, 1)]);
  }));
  return ranges;
}

export function markdownWikilinksAsBrackets(value) {
  if (Array.isArray(value)) return value.map(markdownWikilinksAsBrackets);
  if (!value || typeof value !== "object") return value;
  if (value.type === "wikilink") return { type: "text", value: `[[${value.alias == null ? value.target : `${value.target}|${value.alias}`}]]` };
  return Object.fromEntries(Object.entries(value).map(([key, v]) => [key, markdownWikilinksAsBrackets(v)]));
}

const LINKS_AND_CODE = ["wikilink", "link", "code"];

const unmarked = (doc, at) => LINKS_AND_CODE.every((name) => {
  const type = doc.type.schema.marks[name];
  return !type || !doc.rangeHasMark(at.from, at.to, type);
});

const plain = (doc, at) => unmarked(doc, at) &&
  doc.textBetween(at.from, at.to, undefined, () => "\ufffc") === `[[${at.inner}]]`;

export const MAX_ASKS = 20;

const keyOf = (query) => query.toLowerCase();

function capped(found) {
  const titles = new Set();
  return found.filter((at) => {
    const key = keyOf(at.query);
    if (!titles.has(key) && titles.size >= MAX_ASKS) return false;
    titles.add(key);
    return true;
  });
}

let nextBatch = 0;

// `host` is the canvas: `_wikilinkSource` is its picker search, `_editable` its mode.
export function wikilinkInput(host) {
  const live = () => !!(host && host._editable && typeof host._wikilinkSource === "function");
  let pasting = false;
  return Extension.create({
    name: "bpWikilinkInput",
    addProseMirrorPlugins() {
      return [new Plugin({
        key: wikilinkInputKey,
        state: {
          init: () => [],
          apply(tr, pending, _old, state) {
            const meta = tr.getMeta(wikilinkInputKey);
            let next = pending;
            if (tr.docChanged && pending.length) {
              next = pending.map((at) => ({ ...at, from: tr.mapping.map(at.from, 1), to: tr.mapping.map(at.to, -1) }));
            }
            if (meta && meta.done != null) next = next.filter((at) => at.batch !== meta.done);
            if (!live()) return next;
            const added = (meta && meta.add) || (pasting && tr.docChanged
              ? capped(changedRanges(tr).flatMap(([from, to]) => closedIn(state.doc, from, to))) : []);
            const fresh = added.filter((at) => plain(state.doc, at) && !next.some((p) => p.from === at.from));
            if (!fresh.length) return next;
            const batch = nextBatch++;
            return next.concat(fresh.map((at) => ({ ...at, batch })));
          },
        },
        view: (view) => {
          const asked = new Set();
          const answerFor = (query) => new Promise((resolve) => resolve(host._wikilinkSource(query)))
            .then((list) => matchingRow(list, query), () => null);
          const settle = (batch, rows) => {
            const { state } = view;
            const links = wikilinkInputKey.getState(state)
              .filter((at) => at.batch === batch && rows.get(keyOf(at.query)) && live() && plain(state.doc, at))
              .sort((a, b) => b.from - a.from);
            const tr = state.tr.setMeta(wikilinkInputKey, { done: batch });
            if (links.length) closeHistory(tr);
            else tr.setMeta("addToHistory", false);
            for (const at of links) {
              const row = rows.get(keyOf(at.query));
              const attrs = at.alias == null ? { target: row.title, docId: row.id } : { target: row.title, docId: row.id, alias: at.alias };
              const marks = state.doc.nodeAt(at.from).marks.concat(state.schema.marks.wikilink.create(attrs));
              tr.replaceWith(at.from, at.to, state.schema.text(at.alias ?? row.title, marks));
            }
            view.dispatch(tr);
          };
          const ask = () => {
            const batches = new Map();
            for (const at of wikilinkInputKey.getState(view.state)) {
              if (asked.has(at.batch)) continue;
              if (!batches.has(at.batch)) batches.set(at.batch, new Map());
              batches.get(at.batch).set(keyOf(at.query), at.query);
            }
            for (const [batch, titles] of batches) {
              asked.add(batch);
              const keys = [...titles.keys()];
              Promise.all([...titles.values()].map(answerFor))
                .then((rows) => settle(batch, new Map(rows.map((row, i) => [keys[i], row]))));
            }
          };
          const pasted = () => { pasting = false; };
          view.dom.addEventListener("paste", pasted);
          return { update: ask, destroy: () => view.dom.removeEventListener("paste", pasted) };
        },
        props: {
          handleTextInput(view, from, to, text) {
            if (!live() || from !== to || !text.endsWith("]")) return false;
            const $from = view.state.doc.resolve(from);
            const before = blockText($from.parent).slice(0, $from.parentOffset);
            const m = CLOSED_AT_END.exec(before + text);
            const end = from + text.length;
            const at = m && bracketed(end - m[0].length, end, m[1]);
            if (!at) return false;
            view.dispatch(view.state.tr.insertText(text, from, to).setMeta(wikilinkInputKey, { add: [at] }));
            return true;
          },
          handleDOMEvents: {
            // True only while the paste event is handled: the plugin view's own paste listener,
            // added after ProseMirror's, lowers it again.
            paste: () => {
              pasting = true;
              return false;
            },
          },
        },
      })];
    },
  });
}
