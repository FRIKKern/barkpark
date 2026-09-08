import { Extension } from "@tiptap/core";

export const ParagraphSource = Extension.create({
  name: "bpParagraphSource",
  addGlobalAttributes() {
    return [{ types: ["paragraph"], attributes: {
      bpParagraphSource: { default: null, rendered: false, keepOnSplit: false, parseHTML: () => null },
    } }];
  },
});
