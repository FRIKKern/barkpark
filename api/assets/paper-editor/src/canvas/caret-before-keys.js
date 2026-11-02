import { Extension } from "@tiptap/core";
import { Plugin } from "@tiptap/pm/state";

// Every key acts on the caret the author sees (task-ae6d3d056711b076).
//
// ProseMirror takes a click's caret on the browser's selectionchange, 2-60 ms after
// mouseup and later under load. Its keydown flushes only a pending DOM change, and a
// click leaves none, so a key in that gap ran on the caret from before the click:
// Enter split the old line and the text typed after it went there too; the
// resting-scaffold decorations still showed the empty line the old caret was on, so
// ArrowDown sometimes landed in it and sometimes skipped it. Reading the DOM
// selection before any key handler closes the gap, and it leaves the focus resync
// (ProseMirror's 20 ms write-back after focus) nothing to restore. A hidden empty
// line is then always skipped by the arrows; Enter or its gutter control opens it.
//
// view.domObserver is prosemirror-view's own; __caret_before_keys_mounted.test.mjs
// fails loudly if an upgrade drops its flush. Never mid-composition: an IME's
// keydown (keyCode 229) belongs to the composition. ProseMirror runs every
// handleDOMEvents keydown before its own keydown, its keymaps and handleKeyDown.
export const CaretBeforeKeys = Extension.create({
  name: "caretBeforeKeys",
  addProseMirrorPlugins() {
    return [new Plugin({
      props: {
        handleDOMEvents: {
          keydown(view, event) {
            if (event.isComposing || event.keyCode === 229 || view.composing) return false;
            try {
              if (view.domObserver && typeof view.domObserver.flush === "function") view.domObserver.flush();
            } catch (_e) {
              // A view mid-teardown: the key acts on the state it has.
            }
            return false;
          },
        },
      },
    })];
  },
});
