import { diffWords, goldenWords, htmlText, loadLimits } from "../../api/priv/portable_doc/conformance/conformance.mjs";
import { loadRenderTUI } from "./load.mjs";

const DOC_MS = 1000;
const EDGE_WIDTH = { "flat line at the largest value": 200 };

class Raw {
  constructor(text) {
    this.text = text;
  }
}

function stringify(root) {
  const out = [];
  const stack = [root];
  while (stack.length > 0) {
    const v = stack.pop();
    if (v instanceof Raw) {
      out.push(v.text);
    } else if (Array.isArray(v)) {
      stack.push(new Raw("]"));
      for (let i = v.length - 1; i >= 0; i--) {
        stack.push(v[i]);
        if (i > 0) stack.push(new Raw(","));
      }
      stack.push(new Raw("["));
    } else if (v && typeof v === "object") {
      const entries = Object.entries(v);
      stack.push(new Raw("}"));
      for (let i = entries.length - 1; i >= 0; i--) {
        stack.push(entries[i][1]);
        stack.push(new Raw(`${i > 0 ? "," : ""}${JSON.stringify(entries[i][0])}:`));
      }
      stack.push(new Raw("{"));
    } else {
      out.push(JSON.stringify(v) ?? "null");
    }
  }
  return out.join("");
}

const render = await loadRenderTUI();
const { edges, docs } = loadLimits();
let failed = 0;

for (const edge of edges) {
  const expected = goldenWords(edge.shape);
  if (expected.length === 0) continue;
  const text = htmlText(render(JSON.stringify({ blocks: [edge.input] }), EDGE_WIDTH[edge.name] ?? 100, "light"));
  const diff = diffWords(text, expected);
  if (diff.length > 0) {
    failed++;
    console.error(`FAIL edge ${edge.name}:\n  ${diff.slice(0, 12).join("\n  ")}`);
  }
}

for (const { name, doc } of docs) {
  const json = stringify({ blocks: [doc] });
  const start = performance.now();
  render(json, 100, "light");
  const ms = performance.now() - start;
  console.log(`${name.padEnd(16)} ${ms.toFixed(0).padStart(6)} ms`);
  if (ms > DOC_MS) {
    failed++;
    console.error(`FAIL doc ${name}: ${ms.toFixed(0)} ms, over ${DOC_MS} ms`);
  }
}

console.log(`pdrender-wasm limits: ${edges.length} edges, ${docs.length} docs, ${failed} failing`);
process.exit(failed === 0 ? 0 : 1);
