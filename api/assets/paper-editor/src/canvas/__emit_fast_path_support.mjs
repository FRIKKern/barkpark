import assert from "node:assert/strict";
import { mount } from "./__emit_bench.mjs";

const deepFreeze = (v) => {
  if (v && typeof v === "object" && !Object.isFrozen(v)) {
    Object.freeze(v);
    for (const k of Object.keys(v)) deepFreeze(v[k]);
  }
  return v;
};

// Minted ids carry a random nonce: name each by its first appearance per canvas.
const canonical = (batches) => {
  const names = new Map();
  const walk = (v) => {
    if (typeof v === "string" && /^c-[0-9a-z]+-/.test(v)) {
      if (!names.has(v)) names.set(v, `minted-${names.size}`);
      return names.get(v);
    }
    if (Array.isArray(v)) return v.map(walk);
    if (v && typeof v === "object") return Object.fromEntries(Object.keys(v).sort().map((k) => [k, walk(v[k])]));
    return v;
  };
  return batches.map((b) => walk(b.ops));
};

function pair(blocks) {
  const sides = [mount(0), mount(0)].map((side, i) => {
    side.batches.length = 0;
    side.host.blocks = structuredClone(blocks);
    side.host._emitOps();
    if (i === 1) side.host._emitReuse = () => null; // the full path, every emit
    let reused = 0;
    if (i === 0) {
      const real = side.host._emitReuse.bind(side.host);
      side.host._emitReuse = (b) => { const r = real(b); if (r) reused += r.size; return r; };
    }
    // The dispatched after-state shares its blocks with the fast path's memory:
    // freeze it too, so a later in-place edit of a reused block throws.
    side.host.addEventListener("bp-canvas-ops", () => deepFreeze(side.host._inflightOps?.afterBlocks));
    const ack = side.host.acknowledgeOps.bind(side.host);
    side.host.acknowledgeOps = (seq, saved) => {
      const ok = ack(seq, saved);
      deepFreeze(side.host._blocks);
      return ok;
    };
    side.reused = () => reused;
    return side;
  });
  return sides;
}

const settle = () => new Promise((r) => setTimeout(r, 0));

async function run(sides, step) {
  for (const side of sides) {
    step(side.editor, side.host);
    side.host._emitOps();
  }
  await settle();
}

const endOf = (editor, index) => {
  let pos = 0;
  editor.state.doc.forEach((node, offset, i) => { if (i === index) pos = offset + node.nodeSize - 1; });
  return pos;
};
const startOf = (editor, index) => {
  let pos = 0;
  editor.state.doc.forEach((node, offset, i) => { if (i === index) pos = offset + 1; });
  return pos;
};

export async function script(blocks, label) {
  const sides = pair(blocks);
  const n = blocks.length;
  const mid = Math.floor(n / 2);
  const steps = [
    (e) => { e.commands.setTextSelection(endOf(e, mid)); e.commands.insertContent("x"); },
    (e) => e.commands.insertContent("yz"),
    (e) => { e.commands.setTextSelection(startOf(e, 0)); e.commands.insertContent("A"); },
    (e) => { e.commands.setTextSelection(endOf(e, mid)); e.commands.splitBlock(); },
    (e) => e.commands.insertContent("new paragraph"),
    (e) => { e.commands.setTextSelection(endOf(e, n - 1)); e.commands.insertContent("."); },
    (e) => {
      let from = 0, to = 0;
      e.state.doc.forEach((node, offset, i) => { if (i === 1) { from = offset; to = offset + node.nodeSize; } });
      e.commands.deleteRange({ from, to });
    },
    (e) => e.commands.undo(),
    (e) => { e.commands.setTextSelection(endOf(e, mid + 1)); e.commands.insertContent("q"); },
  ];
  for (const step of steps) await run(sides, step);
  // A server echo of the confirmed run replaces `_blocks`: the next emit must not
  // trust the remembered nodes, and both canvases must still agree.
  for (const side of sides) side.host.applyServerBlocks(structuredClone(side.host._blocks));
  await settle();
  await run(sides, (e) => { e.commands.setTextSelection(endOf(e, mid)); e.commands.insertContent("after echo"); });
  await run(sides, (e) => e.commands.insertContent("!"));
  // Any writer that REPLACES the confirmed run (here: a run whose paragraph 2
  // reads differently, as a confirmation the editor did not re-render could) must
  // send the next emit down the full path, which patches paragraph 2 back to what
  // the author sees. Trusting the remembered nodes would send nothing for it.
  for (const side of sides) {
    side.host._blocks = side.host._blocks.map((b, i) =>
      i === 2 && b.type === "paragraph" ? { ...b, content: [{ type: "text", value: "replaced underneath" }] } : b);
  }
  await run(sides, (e) => { e.commands.setTextSelection(endOf(e, mid)); e.commands.insertContent("?"); });

  const [fast, full] = sides;
  assert.ok(fast.batches.length >= steps.length, `${label}: the edits emitted (${fast.batches.length} batches)`);
  assert.deepEqual(canonical(fast.batches), canonical(full.batches), `${label}: the fast path sends the same ops`);
  assert.deepEqual(canonical([{ ops: fast.host._blocks }]), canonical([{ ops: full.host._blocks }]), `${label}: the same run is kept`);
  if (label.startsWith("paragraphs")) assert.ok(fast.reused() > n, `${label}: the fast path reused unchanged nodes (${fast.reused()})`);
  for (const side of sides) side.host.remove();
}
