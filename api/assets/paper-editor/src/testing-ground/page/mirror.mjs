const KEYS = new Set(["Enter", "Backspace", "Delete", "Tab"]);

function block(doc, index) {
  const { bpId } = doc.child(index).attrs;
  let nth = 0;
  for (let i = 0; i < index; i++) if (doc.child(i).attrs.bpId === bpId) nth++;
  return { id: bpId, nth };
}

function spot(view, pos) {
  const { doc } = view.state;
  const $pos = doc.resolve(pos);
  if ($pos.depth) return { ...block(doc, $pos.index(0)), offset: pos - $pos.before(1) };
  return $pos.nodeAfter ? { ...block(doc, $pos.index(0)), edge: "before" } : { ...block(doc, $pos.index(0) - 1), edge: "after" };
}

function place(view, where) {
  let pos = null;
  let nth = 0;
  view.state.doc.forEach((node, start) => {
    if (node.attrs.bpId !== where.id || nth++ !== where.nth) return;
    if (where.edge) pos = where.edge === "before" ? start : start + node.nodeSize;
    else pos = Math.min(start + where.offset, start + node.nodeSize - 1);
  });
  return pos;
}

const hand = new WeakMap();
let keyed = false;

function watch(editor) {
  if (hand.has(editor)) return;
  hand.set(editor, true);
  editor.on("transaction", ({ transaction }) => { if (transaction.selectionSet && !transaction.docChanged && !keyed) hand.set(editor, true); });
}

function follow(from, to) {
  watch(from._editor);
  if (!hand.get(from._editor)) return;
  hand.set(from._editor, false);
  const source = from._editor.view;
  const { from: a, to: b } = source.state.selection;
  const [x, y] = [a, b].map((pos) => place(to._editor.view, spot(source, pos)));
  if (x === null || y === null) return;
  if (source.state.selection.node) to._editor.commands.setNodeSelection(x);
  else to._editor.commands.setTextSelection({ from: x, to: y });
}

function type(view, chars) {
  for (const char of chars) {
    const { from, to } = view.state.selection;
    if (!view.someProp("handleTextInput", (f) => f(view, from, to, char))) view.dispatch(view.state.tr.insertText(char, from, to));
  }
}

function deleteChar(view, key) {
  const { from } = view.state.selection;
  if (key === "Backspace") view.dispatch(view.state.tr.delete(from - 1, from));
  if (key === "Delete") view.dispatch(view.state.tr.delete(from, from + 1));
}

function paste(view, data) {
  const event = new view.dom.ownerDocument.defaultView.Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "clipboardData", { value: { getData: (kind) => data[kind] } });
  view.dom.dispatchEvent(event);
}

export function mirror(root, source, target) {
  const on = (type, act) => {
    root.addEventListener(type, (event) => {
      const from = source();
      if (!from._editor.view.dom.contains(event.target)) return;
      keyed = true;
      act(event, from, target());
    }, true);
    root.addEventListener(type, () => { keyed = false; });
  };
  on("keydown", (event, from, to) => {
    if (!KEYS.has(event.key) && !event.metaKey && !event.ctrlKey) return;
    follow(from, to);
    const { key, code, shiftKey, altKey, metaKey, ctrlKey } = event;
    const { dom } = to._editor.view;
    const sent = new dom.ownerDocument.defaultView.KeyboardEvent("keydown", { key, code, shiftKey, altKey, metaKey, ctrlKey, bubbles: true, cancelable: true });
    dom.dispatchEvent(sent);
    if (!sent.defaultPrevented) deleteChar(to._editor.view, key);
  });
  on("beforeinput", (event, from, to) => {
    if (event.inputType !== "insertText") return;
    follow(from, to);
    type(to._editor.view, event.data);
  });
  on("paste", (event, from, to) => {
    const data = Object.fromEntries([...event.clipboardData.types].map((kind) => [kind, event.clipboardData.getData(kind)]));
    follow(from, to);
    paste(to._editor.view, data);
  });
}
