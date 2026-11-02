import { Extension } from "@tiptap/core";
import { AllSelection, NodeSelection, Plugin, TextSelection } from "@tiptap/pm/state";
import { Decoration, DecorationSet } from "@tiptap/pm/view";
import { isHistoryTransaction } from "@tiptap/pm/history";
import { t } from "../i18n.js";

// Whole sentences, so a translation never has to agree with a node type name.
const EMPTY_LABELS = { paragraph: "Edit empty paragraph", ingress: "Edit empty ingress" };

const PROSE = ["paragraph", "ingress"];
const isEmptyProse = (node) => !!node && PROSE.includes(node.type.name) && node.content.size === 0;

// Two empty prose lines never touch at the top level (task-be261d669280dc9e). The
// reader shows no empty line and the canvas hides every one the caret leaves, so a
// second one was invisible state: six Enters showed one line and took six
// Backspaces to leave. Both halves key on the hiding's own predicate, in every
// canvas the hiding runs in.
//
// Enter keeps the caret and the line where a person expects them: on an empty
// line it does nothing; at the end of a line above an empty one it moves the caret
// there. Shift-Enter and the menus (handled before keymaps) keep theirs; anywhere
// else Enter splits, and a split that makes empty lines touch is collapsed below.
function enterBesideEmptyProse(editor) {
  const { selection, doc } = editor.state;
  if (!selection.empty) return false;
  const { $from } = selection;
  if ($from.depth !== 1) return false;
  if (isEmptyProse($from.parent)) return true;
  if ($from.parentOffset !== $from.parent.content.size || !isEmptyProse(doc.maybeChild($from.index(0) + 1))) return false;
  editor.view.dispatch(editor.state.tr.setSelection(TextSelection.create(doc, $from.after() + 1)).scrollIntoView());
  return true;
}

// Every other door (a split, Enter over a range, a list exit, a paste, Backspace or
// a move between empty lines) is collapsed after the fact: when a person's own edit
// makes empty lines touch (a line in the run is new or moved), or edits next to
// lines that already do, one line stays: the caret's, else the first. No line with
// text is removed; a collapse that would remove or move a locked block is dropped
// by the lock veto, and the edit that caused it still lands. Edits that are not a person's own (a remote or echoed update, an
// id stamp: addToHistory false), undo and redo, and IME composition are left alone.
const authored = (tr) => tr.getMeta("addToHistory") !== false && !isHistoryTransaction(tr);

function collapseTouchingEmptyLines(transactions, oldState, newState, composing) {
  if (composing || !transactions.some(authored)) return null;
  const before = new Map();
  oldState.doc.forEach((node, _pos, index) => before.set(node, index));
  const fresh = (node) => !!node && !before.has(node);
  const { doc, selection } = newState;
  const caret = selection.$head.index(0);
  const runs = [];
  let run = null;
  doc.forEach((node, pos, index) => {
    if (!isEmptyProse(node)) run = null;
    else if (run) run.push({ node, pos, index });
    else runs.push(run = [{ node, pos, index }]);
  });
  const tr = newState.tr;
  for (const lines of runs.reverse()) {
    const touched = fresh(doc.maybeChild(lines[0].index - 1)) || fresh(doc.maybeChild(lines.at(-1).index + 1)) ||
      lines.some((line, i) => i > 0 && before.get(line.node) !== before.get(lines[i - 1].node) + 1);
    if (!touched) continue;
    const keeper = lines.find((line) => line.index === caret) || lines[0];
    for (const line of lines.reverse()) {
      if (line !== keeper) tr.delete(line.pos, line.pos + line.node.nodeSize);
    }
  }
  return tr.docChanged ? tr : null;
}

// Reader-suppressed scaffolds stay in the document and history. Only their
// resting presentation collapses; a keyboard-reachable gutter button selects
// the original native node, immediately restoring its normal editing surface.
export function restingScaffolds(host) {
  return Extension.create({
    name: "restingScaffolds",
    addKeyboardShortcuts() {
      return { Enter: ({ editor }) => enterBesideEmptyProse(editor) };
    },
    addProseMirrorPlugins() {
      const editor = this.editor;
      return [new Plugin({
        appendTransaction: (transactions, oldState, newState) =>
          collapseTouchingEmptyLines(transactions, oldState, newState, editor.view.composing),
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
                const label = divider ? t("Select hidden divider") : t(EMPTY_LABELS[node.type.name] || `Edit empty ${node.type.name}`);
                button.setAttribute("aria-label", count > 1 ? t("%{label} (first of %{count} hidden blocks)", { label, count }) : label);
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
              const empty = isEmptyProse(node);
              const next = state.doc.maybeChild(index + 1);
              const divider = root && node.type.name === "divider" && next?.type.name === "heading" && next.attrs.level === 2;
              // Late host hydration maps the initial empty document selection to
              // AllSelection. It is not an intent to edit every empty scaffold.
              // Studio can mount a run with a default NodeSelection on its
              // leading divider. Only the focused editor represents intent.
              const selected = editor.isFocused && !(state.selection instanceof AllSelection) &&
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
