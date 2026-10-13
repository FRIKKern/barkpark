// Emit-cost benchmark (task-fb938eb8be3bce48). Mounts one canvas holding N
// paragraphs of ~180 characters, types one character at the end of the middle
// paragraph, and times what each keystroke's debounced emit costs: the clone of
// the baseline at the first key of a debounce window (_scheduleEmit) and the
// diff itself (_emitOps). Run: node src/canvas/__emit_bench.mjs [N ...]
import { JSDOM } from "jsdom";
import { performance } from "node:perf_hooks";

const { window } = new JSDOM("<!doctype html><body></body>", { pretendToBeVisual: true, url: "http://localhost/" });
for (const name of ["customElements", "CustomEvent", "document", "DOMParser", "Element", "Event", "EventTarget", "HTMLElement", "KeyboardEvent", "MouseEvent", "MutationObserver", "Node", "NodeFilter", "Selection", "Text"]) globalThis[name] = window[name];
globalThis.window = window;
Object.defineProperty(globalThis, "navigator", { configurable: true, value: window.navigator });
globalThis.getComputedStyle = window.getComputedStyle.bind(window);
globalThis.requestAnimationFrame = window.requestAnimationFrame.bind(window);
globalThis.cancelAnimationFrame = window.cancelAnimationFrame.bind(window);
globalThis.CSS ||= { escape: String };
window.BP_PAPER_EDITOR_NO_INJECT = true;
window.Range.prototype.getClientRects = () => [];
window.Range.prototype.getBoundingClientRect = () => ({ top: 0, left: 0, right: 0, bottom: 0 });
globalThis.fetch = window.fetch = async () => ({ ok: true, json: async () => ({ documents: [] }) });
await import("../index.js");

const SENTENCE =
  "Fjellet stod stille i morgenlyset, og vinden bar med seg lukten av lyng og stein. " +
  "Hun gikk sakte oppover stien mens tankene vandret til alt som var sagt kvelden før. ";

export function paragraphs(n) {
  return Array.from({ length: n }, (_, i) => ({
    id: `p-${String(i).padStart(4, "0")}`,
    type: "paragraph",
    content: [{ type: "text", value: `${i}. ${SENTENCE}`.slice(0, 180) }],
  }));
}

// Mount a canvas, place the caret at the end of paragraph `at`, and return a
// typist: each call inserts one character and runs the emit the debounce would.
export function mount(n) {
  const host = document.createElement("bp-paper-canvas");
  host.setAttribute("data-dataset", "production");
  host.acknowledgedSaves = true;
  const batches = [];
  host.addEventListener("bp-canvas-ops", (e) => {
    batches.push(e.detail);
    // The LiveView bridge acknowledges each batch; do the same so the baseline
    // advances and every keystroke is an incremental diff, as in Studio.
    if (e.detail.seq != null) queueMicrotask(() => host.acknowledgeOps(e.detail.seq, true));
  });
  document.body.appendChild(host);
  host.blocks = paragraphs(n);
  host._emitOps(); // settle the mount diff
  const editor = host._editor;
  let pos = 0;
  const at = Math.floor(n / 2);
  editor.state.doc.forEach((node, offset, index) => {
    if (index === at) pos = offset + node.nodeSize - 1;
  });
  editor.commands.setTextSelection(pos);
  return { host, editor, batches };
}

const flush = () => new Promise((r) => setTimeout(r, 0));

export async function bench(n, keys = 40) {
  const { host, editor, batches } = mount(n);
  const schedule = [];
  const emit = [];
  await flush();
  for (let k = 0; k < keys; k++) {
    editor.commands.insertContent("a");
    // _scheduleEmit ran inside the transaction; time a fresh window's baseline clone.
    clearTimeout(host._debounceTimer);
    host._debounceTimer = null;
    host._debounceBaselineBlocks = null;
    let t = performance.now();
    host._scheduleEmit();
    schedule.push(performance.now() - t);
    clearTimeout(host._debounceTimer);
    host._debounceTimer = null;
    t = performance.now();
    host._emitOps();
    emit.push(performance.now() - t);
    await flush(); // let the ack land
  }
  host.remove();
  const p = (xs, q) => [...xs].sort((a, b) => a - b)[Math.min(xs.length - 1, Math.floor(q * xs.length))];
  const warm = (xs) => xs.slice(5);
  return {
    n,
    batches: batches.length,
    schedule_p50: p(warm(schedule), 0.5),
    emit_p50: p(warm(emit), 0.5),
    emit_p95: p(warm(emit), 0.95),
  };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const sizes = process.argv.slice(2).map(Number).filter(Boolean);
  for (const n of sizes.length ? sizes : [25, 100, 400]) {
    const r = await bench(n);
    console.log(
      `n=${String(r.n).padStart(4)}  schedule p50 ${r.schedule_p50.toFixed(2)} ms  ` +
        `emit p50 ${r.emit_p50.toFixed(2)} ms  p95 ${r.emit_p95.toFixed(2)} ms  (${r.batches} batches)`,
    );
  }
}
