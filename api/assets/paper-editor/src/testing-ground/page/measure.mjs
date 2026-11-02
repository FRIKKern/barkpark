export function visibility(canvas) {
  const view = canvas._editor?.view;
  if (!view) return [];
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

export async function settle(canvas, host, timeout = 3000) {
  canvas.flushPendingChanges();
  const until = Date.now() + timeout;
  while ((host.inflight > 0 || canvas.hasPendingChanges()) && Date.now() < until) await new Promise((r) => setTimeout(r, 50));
}
