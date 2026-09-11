import { Extension } from "@tiptap/core";

// Source carriers follow the item through native moves and history, but never
// enter HTML or get copied to a newly split item (which must not duplicate IDs).
export const ListItemSource = Extension.create({
  name: "bpListItemSource",
  priority: 1100,
  addKeyboardShortcuts() {
    return { Backspace: () => {
      const { empty, $from } = this.editor.state.selection;
      if (!empty || $from.parentOffset !== 0 || $from.depth < 2 ||
          $from.node(-1).type.name !== "listItem") return false;
      const previous = this.editor.state.doc.resolve($from.before($from.depth - 1)).nodeBefore;
      // Native joinBackward first produces two paragraphs in one item, which
      // our lossless boundary correctly rejects. Join their inline bodies in
      // one transaction; keep the current item's child lists after that body.
      if (previous?.type.name !== "listItem" || previous.childCount !== 1) return false;
      return this.editor.commands.joinTextblockBackward();
    } };
  },
  addGlobalAttributes() {
    return [{ types: ["listItem"], attributes: {
      bpListSource: { default: null, rendered: false, keepOnSplit: false, parseHTML: () => null },
    } }, { types: ["bulletList", "orderedList"], attributes: {
      bpListFrameSource: { default: null, rendered: false, keepOnSplit: false, parseHTML: () => null },
    } }];
  },
});
