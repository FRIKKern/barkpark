import { Extension } from "@tiptap/core";
import { AllSelection, NodeSelection, Plugin, TextSelection } from "@tiptap/pm/state";
import { Decoration, DecorationSet } from "@tiptap/pm/view";

// Reader-suppressed scaffolds stay in the document and history. Only their
// resting presentation collapses; a keyboard-reachable gutter button selects
// the original native node, immediately restoring its normal editing surface.
export function restingScaffolds(host) {
  return Extension.create({
    name: "restingScaffolds",
    addProseMirrorPlugins() {
      return [new Plugin({
        props: {
          decorations(state) {
            const decorations = [];
            let group = [];
            const root = host.closest("[data-paper-container-kind]")?.dataset.paperContainerKind === "document";
            const flush = () => {
              if (!group.length) return;
              const { node, pos, divider } = group[0];
              const count = group.length;
              // Consecutive collapsed blocks occupy the same point. One control
              // opens the first; the remaining control follows its restored box.
              // This avoids overlapping, individually unreachable gutter buttons.
              decorations.push(Decoration.widget(pos, view => {
                const button = view.dom.ownerDocument.createElement("button");
                button.type = "button";
                button.className = "bp-scaffold-control";
                button.contentEditable = "false";
                const label = divider ? "Select hidden divider" : `Edit empty ${node.type.name}`;
                button.setAttribute("aria-label", count > 1 ? `${label} (first of ${count} hidden blocks)` : label);
                button.title = button.getAttribute("aria-label");
                button.textContent = divider ? "§" : "+";
                button.addEventListener("click", () => {
                  const selection = divider ? NodeSelection.create(view.state.doc, pos) : TextSelection.create(view.state.doc, pos + 1);
                  view.dispatch(view.state.tr.setSelection(selection));
                  view.focus();
                });
                return button;
              }, { side: -1, key: `scaffold:${pos}:${node.type.name}:${count}`, stopEvent: () => true }));
              group = [];
            };
            state.doc.forEach((node, pos, index) => {
              const empty = ["paragraph", "ingress"].includes(node.type.name) && node.content.size === 0;
              const next = state.doc.maybeChild(index + 1);
              const divider = root && node.type.name === "divider" && next?.type.name === "heading" && next.attrs.level === 2;
              // Late host hydration maps the initial empty document selection to
              // AllSelection. It is not an intent to edit every empty scaffold.
              const selected = !(state.selection instanceof AllSelection) &&
                state.selection.from < pos + node.nodeSize && state.selection.to > pos;
              if ((!empty && !divider) || selected) return flush();
              decorations.push(Decoration.node(pos, pos + node.nodeSize, { class: "bp-resting-scaffold" }));
              group.push({ node, pos, divider });
            });
            flush();
            return DecorationSet.create(state.doc, decorations);
          },
        },
      })];
    },
  });
}
