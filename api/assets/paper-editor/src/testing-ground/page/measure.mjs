export function visibility(canvas) {
  const { view } = canvas._editor;
  const out = [];
  view.state.doc.forEach((node, pos) => {
    const el = view.nodeDOM(pos);
    out.push(Boolean(el && el.getBoundingClientRect().height > 0));
  });
  return out;
}

export function lines(canvas) {
  const out = [];
  canvas._editor?.state.doc.forEach((node) => out.push(node.textContent));
  return out;
}

export async function settle(canvas, host) {
  canvas.flushPendingChanges();
  await host.idle();
}
