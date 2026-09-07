import { Extension } from "@tiptap/core";
import { Plugin } from "@tiptap/pm/state";

// PortableDoc list items hold one inline array, not nested blocks. Its inline
// serializer also has no hard-break carrier. Reject these edits before they can
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
          } else if (node.type.name === "listItem" &&
            (node.childCount !== 1 || node.firstChild?.type.name !== "paragraph")) {
            message = "Nested lists and multiple paragraphs per item are not supported yet. Keep items at one level. This edit was not applied.";
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
