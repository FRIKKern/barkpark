// __enter_tail.test.mjs — spd-bl-enter-at-tail-block-drop: what Enter at the TAIL of a
// canvas run REALLY emits when the run's LAST block is an opaque / atom node-view.
//
// THE FILING (observed ONCE, on a 5-day-stale + degraded local dev box, never on main):
//   [{"op":"remove-block","id":"pp-013"},
//    {"op":"insert-after","afterId":"pp-001","block":{…"type":"paragraph"…}},
//    {"op":"move-block", …} x11]
// …read as "the last block was DELETED and the new paragraph landed after block 1".
//
// THIS FILE IS THE VERDICT. Part A mounts the REAL <bp-paper-canvas> in jsdom over a
// 13-block run whose tail is each opaque/atom node-view kind in turn, dispatches a REAL
// Enter keydown at the tail, and pins the batch that actually comes out:
//
//   insert-after(afterId = FIRST block, a NEW empty paragraph) + move-block x12
//
// ZERO remove-block. The tail block SURVIVES — it is MOVED, not removed. The batch is
// cosmetically alarming (an insert anchored at block 1 plus a move for every block after
// it) but it is a NORMALISATION, not data loss: runToOps has no prepend/insert-before op,
// so it anchors every insert at the FIRST SURVIVOR and then permutes the running list into
// next order with move-blocks (run-convert.js, the "2) INSERTS" / "3) MOVES" passes). A
// 13-block run therefore ALWAYS yields ~N move-blocks for one Enter. That is the shape a
// journey harness will see; it is correct.
//
// Part B is the DISCRIMINANT, so the next person can tell the two apart in one glance:
// the filed batch — the one carrying remove-block — is emitted ONLY when the tail node is
// ABSENT FROM THE LIVE DOC before the diff runs (a node type the mounted schema does not
// register is dropped by ProseMirror on setContent; a stale committed bundle is the way
// that happens in the wild — see .github/workflows/paper-editor.yml's freshness gate).
// Part B feeds runToOps exactly that doc and reproduces the filed batch byte-for-byte,
// remove-block and 11 moves included. So: remove-block PRESENT = the tail never mounted
// (a bundle/schema problem, and real loss); remove-block ABSENT = the normalisation above.
//
// Run: node src/canvas/__enter_tail.test.mjs   (or: npm test)

import assert from "node:assert/strict";
import { JSDOM } from "jsdom";

const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", {
  pretendToBeVisual: true,
  url: "http://localhost/",
});
const { window } = dom;
for (const name of [
  "customElements", "CustomEvent", "document", "DOMParser", "Element", "Event",
  "EventTarget", "HTMLElement", "KeyboardEvent", "MutationObserver", "Node",
  "NodeFilter", "Selection", "Text",
]) {
  globalThis[name] = window[name];
}
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", {
  configurable: true,
  value: window.navigator,
});
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: (value) => String(value) };
window.BP_PAPER_EDITOR_NO_INJECT = true;

await import("./index.js");
const { runToTiptap, runToOps } = await import("./run-convert.js");
const { NodeSelection } = await import("@tiptap/pm/state");

let failures = 0;
function check(name, fn) {
  try {
    const r = fn();
    if (r && typeof r.then === "function") throw new Error("check() is sync-only");
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures++;
    console.log(`FAIL  ${name}`);
    console.log(`      ${e.message}`);
  }
}
async function checkAsync(name, fn) {
  try {
    await fn();
    console.log(`PASS  ${name}`);
  } catch (e) {
    failures++;
    console.log(`FAIL  ${name}`);
    console.log(`      ${e.message}`);
  }
}

// ── the fixture run: 12 paragraphs + ONE tail node-view, ids pp-001…pp-013 ──────
const pad = (n) => `pp-${String(n).padStart(3, "0")}`;
const para = (n) => ({
  id: pad(n),
  type: "paragraph",
  content: [{ type: "text", value: `Body ${n}.` }],
});
const TAIL_ID = pad(13);

// One representative per NODE-VIEW FAMILY the canvas can end a run with. Every one of
// these mounts as a PM atom (no editable interior) — the "opaque node-view block" of the
// filing. bpOpaque is the literal verbatim carry (opaque-node.js).
const TAILS = {
  "divider (bpDivider leaf atom)": { id: TAIL_ID, type: "divider" },
  "code (bpCode attr-atom)": { id: TAIL_ID, type: "code", value: "IO.puts(1)", lang: "elixir" },
  "embed (bpEmbed read-only atom)": { id: TAIL_ID, type: "embed", url: "https://example.com/x" },
  "field-image (bpField picker atom)": {
    id: TAIL_ID, type: "field-image", label: "Cover", value: { assetId: "a1" },
  },
  "notes (bpFleet server-painted atom)": {
    id: TAIL_ID, type: "notes", items: [{ title: "n" }],
  },
  "composite (bpOpaque verbatim carry)": {
    id: TAIL_ID, type: "composite", fields: { a: 1 },
  },
};

function fixtureRun(tail) {
  const blocks = [];
  for (let i = 1; i <= 12; i++) blocks.push(para(i));
  blocks.push(JSON.parse(JSON.stringify(tail)));
  return blocks;
}

// THE BATCH Enter-at-tail emits on a 13-block run, with the minted id normalised (it
// carries a random nonce). One insert anchored at the FIRST block + a move for blocks
// 2…13 — the run-convert INSERTS/MOVES normalisation, and NOTHING else.
const EXPECTED_BATCH = [
  {
    op: "insert-after",
    afterId: "pp-001",
    block: { id: "<minted>", type: "paragraph", content: [] },
  },
  ...Array.from({ length: 12 }, (_, i) => ({
    op: "move-block",
    id: pad(i + 2),
    after: pad(i + 1),
  })),
];

const normaliseMint = (ops) =>
  JSON.parse(JSON.stringify(ops)).map((op) =>
    op.op === "insert-after" && op.block && /^c-/.test(op.block.id)
      ? { ...op, block: { ...op.block, id: "<minted>" } }
      : op,
  );

// Mount the real canvas, put the caret at the run's TAIL, press Enter, return the batch.
async function enterAtTail(blocks, mode) {
  const canvas = document.createElement("bp-paper-canvas");
  canvas.blocks = JSON.parse(JSON.stringify(blocks));
  const batches = [];
  canvas.addEventListener("bp-canvas-ops", (e) => batches.push(e.detail.ops));
  document.body.appendChild(canvas);
  // Let TipTap's initial content normalisation settle past the 300 ms emit debounce so
  // the assertions observe ONLY the Enter.
  await new Promise((r) => setTimeout(r, 400));
  batches.length = 0;

  const editor = canvas._editor;
  const pm = canvas.querySelector(".ProseMirror");
  const doc = editor.state.doc;
  if (mode === "focus-end") {
    // What a user does: click past the end of the run, then press Enter.
    editor.commands.focus("end");
  } else {
    // The explicit caret-on-the-atom case (click the node-view itself, then Enter).
    const pos = doc.content.size - doc.lastChild.nodeSize;
    editor.view.dispatch(editor.state.tr.setSelection(NodeSelection.create(doc, pos)));
  }
  pm.dispatchEvent(
    new window.KeyboardEvent("keydown", {
      key: "Enter", code: "Enter", keyCode: 13, bubbles: true, cancelable: true,
    }),
  );
  await new Promise((r) => setTimeout(r, 400));

  const live = editor.getJSON();
  canvas.remove();
  return { ops: batches.flat(), live };
}

// ── A) MOUNTED: Enter at the tail NEVER removes the tail block ────────────────────
console.log("── A) mounted: Enter at the tail of a run ending in a node-view ──");

for (const [label, tail] of Object.entries(TAILS)) {
  for (const mode of ["focus-end", "node-selection"]) {
    await checkAsync(
      `Enter at tail (${label}, ${mode}): NO remove-block, tail id survives, batch is insert-after+12 moves`,
      async () => {
        const { ops, live } = await enterAtTail(fixtureRun(tail), mode);
        // THE VERDICT: not one remove-block. The filed batch's defining op is absent.
        assert.deepEqual(
          ops.filter((o) => o.op === "remove-block"),
          [],
          "a remove-block was emitted — the filed data-loss shape",
        );
        // The tail id is still in the doc the diff ran against…
        const liveIds = (live.content || []).map((n) => n.attrs && n.attrs.bpId);
        assert.ok(liveIds.includes(TAIL_ID), "tail id missing from the live doc");
        // …and the batch touches it ONLY as a move.
        const tailOps = ops.filter((o) => o.id === TAIL_ID);
        assert.deepEqual(
          tailOps.map((o) => o.op),
          ["move-block"],
          "the tail block was touched by something other than a move",
        );
        // And the WHOLE batch is the normalisation, byte for byte.
        assert.deepEqual(normaliseMint(ops), EXPECTED_BATCH);
      },
    );
  }
}

// ── B) the DISCRIMINANT: what the FILED batch actually means ──────────────────────
console.log("\n── B) discriminant: the filed remove-block batch = a tail that never mounted ──");

// The filed batch, verbatim from spd-bl-enter-at-tail-block-drop (minted id normalised).
const FILED_BATCH = [
  { op: "remove-block", id: TAIL_ID },
  {
    op: "insert-after",
    afterId: "pp-001",
    block: { id: "<minted>", type: "paragraph", content: [] },
  },
  ...Array.from({ length: 11 }, (_, i) => ({
    op: "move-block",
    id: pad(i + 2),
    after: pad(i + 1),
  })),
];

check(
  "runToOps: a live doc MISSING the tail node reproduces the FILED batch exactly (remove-block + insert-after + 11 moves)",
  () => {
    const blocks = fixtureRun(TAILS["divider (bpDivider leaf atom)"]);
    // The doc ProseMirror would hold if the tail node type were NOT registered in the
    // mounted schema: the 12 paragraphs, the tail DROPPED, plus Enter's new paragraph.
    const doc = runToTiptap(blocks);
    doc.content.pop();
    doc.content.push({ type: "paragraph", attrs: { bpId: null, bpType: null }, content: [] });
    assert.deepEqual(normaliseMint(runToOps(blocks, doc)), FILED_BATCH);
  },
);

check(
  "the two batches differ ONLY by the remove-block (and the move it costs) — remove-block IS the discriminant",
  () => {
    assert.equal(EXPECTED_BATCH.filter((o) => o.op === "remove-block").length, 0);
    assert.equal(FILED_BATCH.filter((o) => o.op === "remove-block").length, 1);
    assert.equal(EXPECTED_BATCH.filter((o) => o.op === "move-block").length, 12);
    assert.equal(FILED_BATCH.filter((o) => o.op === "move-block").length, 11);
    // Both anchor the insert at block 1 — so "the paragraph landed after block 1" is
    // NOT itself a symptom of loss. It is how runToOps expresses every insert.
    assert.equal(EXPECTED_BATCH[0].afterId, "pp-001");
    assert.equal(FILED_BATCH[1].afterId, "pp-001");
  },
);

console.log(failures === 0 ? "\nOK" : `\n${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
