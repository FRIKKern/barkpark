// opaque-mark.js — bpOpaqueMark, a flat text-leaf mark the editor has no UI for
// ({type:"smallcaps"}, or any annotation a source system wrote), carried
// VERBATIM (task-6d27394284ce6cff). Before it, convert.js dropped such a mark on
// load, so the next save of its block wrote the leaf back without it.
//
// DOM-free like marks.js. `mark` is the stored mark, byte-exact; `leaf` is the
// leaf's whole stored `marks` array, so convert.js can put each mark back in its
// original place beside the known ones. `excludes: ""` lets several opaque marks
// stack on one range; `inclusive: false` keeps one from spreading onto typed
// text at its edge. No styling: the reader ignores unknown marks, so the canvas
// shows the text as the reader does. Both attrs are JSON-encoded through their
// DOM attribute so a DOM serialize -> parse (copy/paste) keeps them.

import { Mark } from "@tiptap/core";

export const OPAQUE_MARK = "bpOpaqueMark";

const jsonAttr = (key, name) => ({
  default: null,
  parseHTML: (el) => {
    const raw = el.getAttribute(name);
    if (!raw) return null;
    try {
      return JSON.parse(raw);
    } catch {
      return null;
    }
  },
  renderHTML: (attrs) => (attrs[key] == null ? {} : { [name]: JSON.stringify(attrs[key]) }),
});

export const OpaqueMark = Mark.create({
  name: OPAQUE_MARK,
  inclusive: false,
  excludes: "",
  addAttributes() {
    return {
      mark: jsonAttr("mark", "data-bp-opaque-mark"),
      leaf: jsonAttr("leaf", "data-bp-opaque-leaf"),
    };
  },
  parseHTML() {
    return [{ tag: "span[data-bp-opaque-mark]" }];
  },
  renderHTML({ HTMLAttributes }) {
    return ["span", HTMLAttributes, 0];
  },
});
