// block-boundary.js — no keystroke at a block boundary deletes a block the author
// did not Backspace/Delete.
//
// The canvas holds most non-text blocks as one selectable unit (an image, a
// divider, a code block, a field, a fleet widget, a carried object block …). Two
// paths turned an ordinary keystroke into a deletion of such a block
// (task-0075081d540d1390 for the declared carry, generalised by
// task-d71004a463ea7c06 and task-b511f57b966bc324, found by the data-loss key
// matrix __data_loss_key_matrix_mounted.test.mjs):
//
//   1. A line jump (End/Home, Mod/Alt+Arrow) at the edge of a textblock
//      NodeSelected the block atom beside it. It now stays in the textblock.
//   2. Typing, a paste or an IME composition while a non-text block is
//      NodeSelected (a plain Arrow reaches it on purpose) REPLACED the block.
//      The input now lands in a new paragraph after the block.
//
// Backspace and Delete on a selected block stay a deliberate delete.

import { Extension } from "@tiptap/core";
import { NodeSelection, Plugin, PluginKey, TextSelection } from "@tiptap/pm/state";

// The non-text block the selection holds as a NodeSelection, or null.
export function selectedBlock(state) {
  const sel = state.selection;
  if (!(sel instanceof NodeSelection)) return null;
  const node = sel.node;
  return node.isBlock && !node.isTextblock ? node : null;
}

// A transaction that opens an empty paragraph after the NodeSelected block and
// puts the caret in it, so typing, a paste or a composition lands there instead
// of replacing the block. Null when no paragraph fits there.
export function paragraphAfterSelectedBlock(state) {
  const paragraph = state.schema.nodes.paragraph;
  if (!selectedBlock(state) || !paragraph) return null;
  const at = state.selection.to;
  try {
    const tr = state.tr.insert(at, paragraph.create());
    return tr.setSelection(TextSelection.create(tr.doc, at + 1));
  } catch (_e) {
    return null;
  }
}

// True (the key is consumed, the caret stays) when the caret is collapsed at the
// `dir` edge of its textblock and the next block that way is a block atom — the
// node a line jump would otherwise NodeSelect.
function keepCaretBesideBlockAtom(editor, dir) {
  const sel = editor.state.selection;
  if (!(sel instanceof TextSelection) || !sel.empty) return false;
  const $pos = sel.$head;
  if (!$pos.parent.isTextblock) return false;
  if (dir > 0 ? $pos.parentOffset < $pos.parent.content.size : $pos.parentOffset > 0) return false;
  for (let depth = $pos.depth; depth > 0; depth--) {
    const index = $pos.index(depth - 1);
    const parent = $pos.node(depth - 1);
    const beside = dir > 0 ? (index + 1 < parent.childCount ? parent.child(index + 1) : null) : (index > 0 ? parent.child(index - 1) : null);
    if (beside) return beside.isBlock && beside.isAtom && NodeSelection.isSelectable(beside);
    // Nothing beside it at this depth: the next block is a level up.
  }
  return false;
}

const blockBoundaryKey = new PluginKey("bpBlockBoundary");

export const BlockBoundary = Extension.create({
  name: "bpBlockBoundary",
  addKeyboardShortcuts() {
    return {
      End: ({ editor }) => keepCaretBesideBlockAtom(editor, 1),
      "Mod-ArrowRight": ({ editor }) => keepCaretBesideBlockAtom(editor, 1),
      "Alt-ArrowRight": ({ editor }) => keepCaretBesideBlockAtom(editor, 1),
      Home: ({ editor }) => keepCaretBesideBlockAtom(editor, -1),
      "Mod-ArrowLeft": ({ editor }) => keepCaretBesideBlockAtom(editor, -1),
      "Alt-ArrowLeft": ({ editor }) => keepCaretBesideBlockAtom(editor, -1),
    };
  },
  addProseMirrorPlugins() {
    return [
      new Plugin({
        key: blockBoundaryKey,
        props: {
          handleTextInput(view, _from, _to, text) {
            if (!selectedBlock(view.state) || !text) return false;
            const tr = paragraphAfterSelectedBlock(view.state);
            if (tr) view.dispatch(tr.insertText(text).scrollIntoView());
            // No paragraph fits there: drop the keystroke, keep the block.
            return true;
          },
          handleDOMEvents: {
            // A composition starts in the new paragraph; ProseMirror then
            // composes into it as usual.
            compositionstart(view) {
              const tr = selectedBlock(view.state) && paragraphAfterSelectedBlock(view.state);
              if (tr) view.dispatch(tr.scrollIntoView());
              return false;
            },
          },
        },
      }),
    ];
  },
});
