import { Extension } from "@tiptap/core";

export const HeadingSource = Extension.create({
  name: "bpHeadingSource",
  addGlobalAttributes() {
    return [{ types: ["heading"], attributes: {
      bpHeadingSource: { default: null, rendered: false, keepOnSplit: false, parseHTML: () => null },
    } }];
  },
});
