// smoke.mjs — proves the freshly-built pdrender wasm blob actually renders.
//
// Mirrors exactly how the reader (api/lib/barkpark_web/layouts/bulldocs.html.heex)
// loads it: gunzip bp-pdrender.wasm.gz → instantiate with the COMMITTED
// bp-wasm-exec.js loader → call window.bpRenderTUI(blocksJSON, width, theme) →
// assert the returned fragment starts with <pre class="bp-tui-pre"> and contains
// text from the sample document.
//
// Usage: node cmd/pdrender-wasm/smoke.mjs
// Exits non-zero on any failure so CI (and `make wasm`) can gate on it.
//
// It does NOT rebuild the wasm — it renders whatever bp-pdrender.wasm.gz the
// build target just produced, so a broken build or an ABI drift vs. the
// committed loader fails here.

import { readFileSync } from "node:fs";
import { gunzipSync } from "node:zlib";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { createRequire } from "node:module";
import vm from "node:vm";

const require = createRequire(import.meta.url);

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, "..", "..");

const wasmGzPath = join(repoRoot, "api/priv/static/assets/bp-pdrender.wasm.gz");
const loaderPath = join(repoRoot, "api/priv/static/assets/bp-wasm-exec.js");
const samplePath = join(repoRoot, "internal/pdrender/testdata/sample.json");

function fail(msg) {
  console.error("SMOKE FAIL: " + msg);
  process.exit(1);
}

// 1. Evaluate the committed Go loader (bp-wasm-exec.js) to get `globalThis.Go`.
//    It targets a browser/Node global object; run it in a context that provides
//    the globals it reaches for, then instantiate the wasm exactly like the Go
//    toolchain's own runner does.
const loaderSrc = readFileSync(loaderPath, "utf8");
const sandbox = {
  globalThis: null,
  require,
  process,
  Buffer,
  TextEncoder,
  TextDecoder,
  crypto: globalThis.crypto,
  performance: globalThis.performance,
  console,
  WebAssembly,
  setTimeout,
  clearTimeout,
  setInterval,
  clearInterval,
};
sandbox.globalThis = sandbox;
vm.createContext(sandbox);
vm.runInContext(loaderSrc, sandbox, { filename: "bp-wasm-exec.js" });

if (typeof sandbox.Go !== "function") fail("bp-wasm-exec.js did not define Go");

// 2. Gunzip + instantiate.
const wasmBytes = gunzipSync(readFileSync(wasmGzPath));
const go = new sandbox.Go();
const { instance } = await WebAssembly.instantiate(wasmBytes, go.importObject);
// go.run resolves when main() returns; our main blocks on select{} after setting
// the export, so we do NOT await it — fire it and poll for the export.
go.run(instance);

let render = null;
for (let i = 0; i < 200; i++) {
  if (typeof sandbox.bpRenderTUI === "function") {
    render = sandbox.bpRenderTUI;
    break;
  }
  await new Promise((r) => setTimeout(r, 10));
}
if (!render) fail("wasm did not export bpRenderTUI");

// 3. Render the sample doc and assert on the output.
const blocksJSON = readFileSync(samplePath, "utf8");
const html = render(blocksJSON, 80, "dark");

if (typeof html !== "string") fail("bpRenderTUI did not return a string");
if (!html.startsWith('<pre class="bp-tui-pre">')) {
  fail('output did not start with <pre class="bp-tui-pre">; got: ' + html.slice(0, 80));
}
// The heading renderer upper-cases level-1 text; assert on that plus a stable
// plain run from the paragraph, so a renderer that returned an empty/garbled
// <pre> still fails here.
if (!html.includes("BULLDOCS TERMINAL RENDER")) {
  fail("output missing expected (upper-cased) heading text from sample.json");
}
if (!html.includes("This paragraph mixes")) {
  fail("output missing expected paragraph text from sample.json");
}
if (!html.includes("</pre>")) fail("output not closed with </pre>");

console.log("SMOKE OK: bpRenderTUI rendered " + html.length + " bytes of HTML from sample.json");
process.exit(0);
