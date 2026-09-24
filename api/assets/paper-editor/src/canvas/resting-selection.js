import { Extension } from "@tiptap/core";
import { AllSelection, Plugin, Selection } from "@tiptap/pm/state";

// A hydrated run must rest on a caret, never on the whole run (task-a4a6773110a20b23).
//
// Studio mounts <bp-paper-canvas> empty and assigns `blocks` afterwards. The empty
// mount starts with an AllSelection, and the hydrating setContent (one replace over
// the whole document) maps an AllSelection to itself. Left alone, the canvas rests
// with every block of the run selected, and the next focus that brings no fresh DOM
// caret types over all of it: Tab into the canvas (ProseMirror's focus handler
// paints the stored selection into the DOM), or a key that beats a click's
// selectionchange (ProseMirror's keypress handler replaces a non-text selection).
// The batch is then remove-block for every block in the run plus one append-block.
//
// Rule: when a document change leaves an AllSelection that no transaction set on
// purpose, collapse it to the first text position. An explicit select-all (Mod-a)
// sets the selection itself and is kept.
export const RestingSelection = Extension.create({
  name: "restingSelection",
  addProseMirrorPlugins() {
    return [new Plugin({
      appendTransaction(transactions, _oldState, newState) {
        if (!(newState.selection instanceof AllSelection)) return null;
        if (!transactions.some((tr) => tr.docChanged)) return null;
        if (transactions.some((tr) => tr.selectionSet)) return null;
        const caret = Selection.findFrom(newState.doc.resolve(0), 1, true);
        if (!caret) return null;
        return newState.tr.setSelection(caret).setMeta("addToHistory", false);
      },
    })];
  },
});
