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

function follow(from, to) {
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

function paste(view, data) {
  const event = new view.dom.ownerDocument.defaultView.Event("paste", { bubbles: true, cancelable: true });
  Object.defineProperty(event, "clipboardData", { value: { getData: (kind) => data[kind] } });
  view.dom.dispatchEvent(event);
}

export function mirror(root, source, target) {
  const on = (type, act) => root.addEventListener(type, (event) => {
    const from = source();
    if (!from._editor.view.dom.contains(event.target)) return;
    act(event, from, target());
  }, true);
  on("keydown", (event, from, to) => {
    if (!KEYS.has(event.key) && !event.metaKey && !event.ctrlKey) return;
    follow(from, to);
    const { key, code, shiftKey, altKey, metaKey, ctrlKey } = event;
    const { dom } = to._editor.view;
    dom.dispatchEvent(new dom.ownerDocument.defaultView.KeyboardEvent("keydown", { key, code, shiftKey, altKey, metaKey, ctrlKey, bubbles: true, cancelable: true }));
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
