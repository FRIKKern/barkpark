// canvas/host-commands.js — the toolbar commands a host runs on <bp-paper-canvas>
// (EMBED-CONTRACT "Toolbar commands"): marks, block style, lists, and the active
// state a toolbar shows as pressed.
//
// Each command reuses the transaction the canvas's own surfaces already run, so a
// toolbar press is one undo step and the same ops on the wire as the bubble, the
// block menu or the palette:
//   * marks and links — the format bubble's own applyMark / applyLink;
//   * block style — the palette's Turn-into chains (setParagraph / setHeading), and
//     the block menu's turnTopLevelInto for a quote (a same-id swap that keeps the
//     text), in the quote kind the field admits (quoteTypeFor, as `> ` does);
//   * lists — the palette's list toggles, and turnTopLevelInto when a list changes
//     kind (it keeps the list's id).
// can() also asks the field's vocabulary, because the canvas's veto drops an
// out-of-vocabulary edit silently: a command the field forbids answers false
// rather than "applying" a no-op.

import { allowedBlockTypes, allowedHeadingLevels, markAllowed, quoteTypeFor, pdTypeOf } from "./vocabulary.js";
import { topLevelIndexAtSelection, turnTopLevelInto } from "./block-handle.js";
import { applyLink, applyMark, linkHref, markToggle } from "../format-bubble.js";

// Portable-doc mark names (the contract's) → the canvas's TipTap marks.
export const TOOLBAR_MARKS = {
  strong: "bold",
  em: "italic",
  code: "code",
  underline: "underline",
  strike: "strike",
  highlight: "highlight",
  link: "link",
  wikilink: "wikilink",
};
// A document id as Barkpark mints them (FieldVocabulary's wikilink check): never
// markup, a path or a URL.
const DOC_ID = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,199}$/;
const MARK_TO_TOOLBAR = Object.fromEntries(Object.entries(TOOLBAR_MARKS).map(([pd, tiptap]) => [tiptap, pd]));

export const BLOCK_STYLES = ["normal", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote"];
const LIST_TOGGLE = { bullet: "toggleBulletList", number: "toggleOrderedList" };
const LIST_NODE = { bulletList: "bullet", orderedList: "number" };
const LIST_TURN_INTO = { bullet: "bullet", number: "ordered" };
const QUOTES = new Set(["blockquote", "pullquote"]);

const canRun = (editor, name, ...args) => {
  try {
    const fn = editor.can()[name];
    return typeof fn === "function" && fn(...args) === true;
  } catch (_e) {
    return false;
  }
};

function topTextblock(state) {
  const { $from } = state.selection;
  return $from.depth >= 1 && $from.node(1).isTextblock ? $from.node(1) : null;
}

function listKindAt(state) {
  const { $from } = state.selection;
  for (let d = $from.depth; d > 0; d--) {
    const kind = LIST_NODE[$from.node(d).type.name];
    if (kind) return kind;
    if ($from.node(d).type.name === "taskList") return null;
  }
  return null;
}

// The word an empty caret touches in a text block, as Sanity links it: Link with only a
// caret applies to the word at the caret (task-fbc0d0f2f0ab1329). `null` when the caret
// touches no word (a space, an empty line). Inline atoms count as one non-word char.
const WORD_CHAR = /[\p{L}\p{N}_'’-]/u;
export function wordAtCaret(state) {
  const { selection } = state;
  if (!selection.empty) return null;
  const $c = selection.$from;
  if (!$c.parent.isTextblock) return null;
  const text = $c.parent.textBetween(0, $c.parent.content.size, "\0", "\0");
  let a = $c.parentOffset;
  let b = a;
  while (a > 0 && WORD_CHAR.test(text[a - 1])) a--;
  while (b < text.length && WORD_CHAR.test(text[b])) b++;
  if (a === b) return null;
  return { from: $c.start() + a, to: $c.start() + b };
}

// ── can ────────────────────────────────────────────────────────────────────

export function canToggleMark(editor, mark, href, vocab, docId) {
  const name = TOOLBAR_MARKS[mark];
  if (!name || !markAllowed(name, vocab)) return false;
  // A document link needs the document to set (its id), or one in place to clear.
  if (name === "wikilink") {
    if (typeof docId === "string" && docId.trim()) return DOC_ID.test(docId.trim()) && !editor.state.selection.empty && canRun(editor, "setMark", "wikilink", { target: docId, docId });
    return editor.isActive("wikilink");
  }
  if (name !== "link") return canRun(editor, markToggle(name));
  // A link needs an href to set, or one in place to clear.
  if (typeof href === "string" && href.trim()) {
    const safe = linkHref(href);
    // A caret in a word links that word (Sanity's); a caret touching none has nothing to link.
    const over = !editor.state.selection.empty || !!wordAtCaret(editor.state);
    return !!safe && over && canRun(editor, "setLink", { href: safe });
  }
  return editor.isActive("link");
}

export function canSetBlockStyle(editor, style, vocab) {
  if (!BLOCK_STYLES.includes(style)) return false;
  if (style === "blockquote") {
    if (vocab && !allowedBlockTypes(vocab).has(quoteTypeFor(vocab))) return false;
    return !!topTextblock(editor.state);
  }
  if (style === "normal") {
    if (vocab && !allowedBlockTypes(vocab).has("paragraph")) return false;
    const top = topTextblock(editor.state);
    return (top && QUOTES.has(top.type.name)) || canRun(editor, "setParagraph");
  }
  const level = Number(style.slice(1));
  if (vocab && !allowedHeadingLevels(vocab).has(level)) return false;
  return canRun(editor, "setHeading", { level });
}

export function canToggleList(editor, kind, vocab) {
  if (!LIST_TOGGLE[kind]) return false;
  if (vocab && !vocab.lists.includes(kind)) return false;
  return canRun(editor, LIST_TOGGLE[kind]);
}

// ── apply ──────────────────────────────────────────────────────────────────

export function toggleMark(editor, mark, href, docId, target) {
  const name = TOOLBAR_MARKS[mark];
  if (name === "link") {
    // A new link with only a caret goes on the word at the caret, and the caret stays put:
    // one transaction, one undo step (Sanity's).
    const word = href && !editor.isActive("link") ? wordAtCaret(editor.state) : null;
    if (word) {
      const safe = linkHref(href);
      if (!safe) return false;
      const caret = editor.state.selection.from;
      return editor.chain().focus().setTextSelection(word).setLink({ href: safe }).setTextSelection(caret).run();
    }
    return applyLink(editor, editor.isActive("link") && !href ? "" : href);
  }
  if (name === "wikilink") {
    if (typeof docId === "string" && docId.trim()) {
      const id = docId.trim();
      const label = typeof target === "string" && target.trim() ? target.trim() : id;
      // Over the selection; a link already there is replaced, not nested.
      return editor.chain().focus().unsetMark("wikilink").setMark("wikilink", { target: label, docId: id }).run();
    }
    return editor.chain().focus().extendMarkRange("wikilink").unsetMark("wikilink").run();
  }
  return applyMark(editor, name);
}

export function setBlockStyle(editor, style, vocab) {
  const { state } = editor;
  const top = topTextblock(state);
  const index = topLevelIndexAtSelection(editor);
  if (style === "blockquote") return turnTopLevelInto(editor, index, "quote", { quoteType: quoteTypeFor(vocab) });
  if (style === "normal") {
    if (top && QUOTES.has(top.type.name)) return turnTopLevelInto(editor, index, "paragraph");
    return state.selection.$from.parent.type.name === "paragraph" || editor.chain().focus().setParagraph().run();
  }
  const level = Number(style.slice(1));
  const parent = state.selection.$from.parent;
  if (parent.type.name === "heading" && parent.attrs.level === level) return true;
  return editor.chain().focus().setHeading({ level }).run();
}

export function toggleList(editor, kind) {
  const current = listKindAt(editor.state);
  const { $from } = editor.state.selection;
  // A whole top-level list changing kind stays the same block (its id is kept).
  if (current && current !== kind && $from.depth >= 1 && LIST_NODE[$from.node(1).type.name]) {
    return turnTopLevelInto(editor, topLevelIndexAtSelection(editor), LIST_TURN_INTO[kind]);
  }
  return editor.chain().focus()[LIST_TOGGLE[kind]]().run();
}

// ── state ──────────────────────────────────────────────────────────────────

export const emptyToolbarState = () => ({ marks: [], blockStyle: null, list: null, link: null, wikilink: null, selection: { empty: true, inBlockType: null } });

export function toolbarState(editor) {
  const { state } = editor;
  const { selection } = state;
  const { $from } = selection;
  const marks = Object.keys(MARK_TO_TOOLBAR).filter((name) => editor.isActive(name)).map((name) => MARK_TO_TOOLBAR[name]);
  const parent = $from.parent;
  const blockStyle = parent.type.name === "paragraph" ? "normal"
    : parent.type.name === "heading" ? `h${parent.attrs.level}`
    : QUOTES.has(parent.type.name) ? "blockquote"
    : null;
  const top = $from.depth >= 1 ? $from.node(1) : selection.node || null;
  const href = editor.isActive("link") ? editor.getAttributes("link").href : null;
  const doc = editor.isActive("wikilink") ? editor.getAttributes("wikilink") : null;
  return {
    marks,
    blockStyle,
    list: listKindAt(state),
    link: typeof href === "string" ? { href } : null,
    wikilink: doc ? { target: doc.target || "", docId: doc.docId || null } : null,
    selection: { empty: selection.empty, inBlockType: top ? pdTypeOf({ type: top.type.name, attrs: top.attrs }) : null },
  };
}
