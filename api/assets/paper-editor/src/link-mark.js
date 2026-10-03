// link-mark.js — the Link mark both editors register.
//
// tiptap 3 added a `title` attribute (default null) to @tiptap/extension-link.
// PortableDoc links carry no title, and the writability checks in convert.js
// (validTableMark, the inline equality guards) compare exact attribute sets, so
// a `title: null` on every link made every linked table cell read-only. The
// editors keep the tiptap 2 attribute set: href, target, rel, class.

import Link from "@tiptap/extension-link";

export const PortableLink = Link.extend({
  addAttributes() {
    const { title: _title, ...attrs } = this.parent?.() ?? {};
    return attrs;
  },
});
