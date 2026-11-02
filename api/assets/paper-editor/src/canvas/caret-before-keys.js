import { Extension } from "@tiptap/core";
import { Plugin } from "@tiptap/pm/state";

// A key acts on the caret a click just put down, not on the one ProseMirror had
// before it reads selectionchange (task-ae6d3d056711b076). view.domObserver is
// prosemirror-view's internal; __caret_before_keys_mounted.test.mjs fails loudly if
// an upgrade drops its flush. Never mid-composition: an IME's keydown belongs to it.
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
              // A throw here would cancel ProseMirror's own keydown. flush() scrolls to
              // the caret it read, and a DOM without layout (jsdom) has no
              // getClientRects; __keyboard_reach.test.mjs reaches this.
            }
            return false;
          },
        },
      },
    })];
  },
});
