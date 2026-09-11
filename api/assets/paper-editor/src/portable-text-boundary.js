import { Extension } from "@tiptap/core";
import { Plugin } from "@tiptap/pm/state";

// PortableDoc list items hold one inline body followed by nested lists. Its inline
// serializer has no hard-break carrier. Reject other shapes before they can
// look saved locally while disappearing in the persisted projection.
export function portableTextBoundary(host, singleBlockType = () => null) {
  return Extension.create({
    name: "bpPortableTextBoundary",
    addProseMirrorPlugins: () => [new Plugin({
      filterTransaction(tr) {
        if (!tr.docChanged) return true;
        let message;
        const type = singleBlockType();
        if (type) {
          const allowed = type === "list" ? ["bulletList", "orderedList"]
            : type === "heading" ? ["heading"] : ["paragraph"];
          if (tr.doc.childCount !== 1 || !allowed.includes(tr.doc.firstChild?.type.name)) {
            message = "This field edits one block. Add separate blocks in the Paper canvas instead. This edit was not applied.";
          }
        }
        tr.doc.descendants(node => {
          if (node.type.name === "hardBreak") {
            message = "Inline line breaks are not supported yet. Use separate paragraphs or list items instead. This edit was not applied.";
          } else if (node.type.name === "orderedList" && node.attrs.start !== 1) {
            message = "Custom list starting numbers are not supported yet. Start numbering at 1. This edit was not applied.";
          } else if (node.type.name === "listItem") {
            let valid = node.firstChild?.type.name === "paragraph";
            node.forEach((child, _offset, index) => {
              if (index > 0 && !["bulletList", "orderedList"].includes(child.type.name)) valid = false;
            });
            if (!valid) message = "Multiple paragraphs per list item are not supported yet. Use one paragraph followed by nested lists. This edit was not applied.";
          }
        });
        let notice = host.querySelector("[data-bp-text-boundary]");
        if (!message) {
          notice?.remove();
          return true;
        }
        if (!notice) {
          notice = document.createElement("div");
          notice.dataset.bpTextBoundary = "";
          notice.className = "bp-canvas-constraint-notice";
          notice.setAttribute("role", "status");
          host.appendChild(notice);
        }
        notice.textContent = message;
        return false;
      },
    })],
  });
}
