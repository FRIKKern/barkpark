export function createFakeHost({ fold, blocks, onChange }) {
  const canvases = new Set();
  const pending = new Set();
  let requests = 0;
  const host = {
    fold,
    saved: structuredClone(blocks),
    batches: [],
    refusals: [],
    get busy() {
      return pending.size > 0;
    },
    async idle() {
      while (pending.size) await Promise.all(pending);
    },
    attach(canvas) {
      canvases.add(canvas);
      canvas.acknowledgedSaves = true;
      canvas.blocks = structuredClone(host.saved);
      canvas.addEventListener("bp-canvas-ops", (event) => {
        const answering = answer(canvas, event.detail);
        pending.add(answering);
        answering.then(() => pending.delete(answering));
      });
    },
    detach(canvas) {
      canvases.delete(canvas);
    },
  };

  async function answer(canvas, { ops, seq }) {
    const requestId = `tg-${++requests}`;
    const batch = { seq, ops: structuredClone(ops), at: Date.now() };
    host.batches.push(batch);
    canvas.identifyOpsRequest(seq, requestId);
    try {
      host.saved = structuredClone(await host.fold.apply(structuredClone(host.saved), ops));
      batch.answer = { ok: true };
      canvas.applyServerBlocks(structuredClone(host.saved), { mode: "own", requestId });
      canvas.acknowledgeOps(seq, true);
      for (const other of canvases) if (other !== canvas) other.applyServerBlocks(structuredClone(host.saved));
    } catch (error) {
      batch.answer = { ok: false, error: error.message };
      host.refusals.push(error.message);
      canvas.discardInflightOps(seq);
    }
    onChange();
  }

  return host;
}
