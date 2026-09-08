import { Extension } from "@tiptap/core";

// Source carriers follow the item through native moves and history, but never
// enter HTML or get copied to a newly split item (which must not duplicate IDs).
export const ListItemSource = Extension.create({
  name: "bpListItemSource",
  addGlobalAttributes() {
    return [{ types: ["listItem"], attributes: {
      bpListSource: { default: null, rendered: false, keepOnSplit: false, parseHTML: () => null },
    } }];
  },
});
