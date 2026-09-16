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

// 4. Slate-2 enumeration — prove EVERY creative-slate block family renders through
//    the REAL wasm reader path, not just sample.json. The wasm CI gate otherwise
//    only exercises sample.json: a slate block can compile into the blob and never
//    be rendered. This loop closes that gap for the whole m17→m26 slate (charter
//    D11 + D25). Each fixture is a full {blocks:[...]} document that
//    render(json, 80, "dark") accepts verbatim (m21 omits `version` — Decode
//    tolerates it), so we feed the on-disk testdata through the same blob.
//
// Per fixture, three D25 refutations — each pinned to a specific silent-failure mode:
//   (a) WRAPPER: html must start with '<pre class="bp-tui-pre">'. The classless
//       decode-error <pre> (main.go:53) is emitted when Decode fails, so this
//       excludes a doc that never reached the block renderers at all.
//   (b) NON-FALLBACK: html must NOT contain 'unknown block:'. That string is the
//       block-level fallbackRenderer (blocks.go:308) — the tripwire for both an
//       unregistered block type AND a STALE blob rendering post-merge fixtures
//       against pre-merge code. Rebuild the blob (make wasm) before trusting this.
//   (c) DIM-AS-COLOR: html must contain 'color:#51515b' — the HTML form of the
//       ChromeDim escape. This is the end-to-end dim-never-Faint proof: applySGR
//       (main.go:132-192) has NO SGR-2 (Faint) case, so a dim rendered via Faint
//       instead of a foreground color silently vanishes and this assertion reds.
//
//   Derivation of the pinned #51515b (comment it so a future lipgloss bump is
//   caught, not silently absorbed):
//     ChromeDim (dark) token = #52525b  (tokens_gen.go GenChromeDim.Dark)
//       R=0x52=82, G=0x52=82, B=0x5b=91
//     lipgloss renders TrueColor via a float round-trip (colorful → 0..1 → *255
//       → round) that drops 82→81 on the R and G channels (91 is unchanged):
//       → SGR "38;2;81;81;91" → applySGR emits color:#51515b (81=0x51, 91=0x5b).
//     So the byte we assert is #51515b, and #52525b must be ABSENT (a raw token
//       leak would betray a code path that bypassed the lipgloss round-trip).
//   Probe provenance: re-probed fresh at origin/main@46fc7849 with go1.25.8 —
//     all ten fixtures m17..m26 render color:#51515b present, color:#52525b absent.
const slateFixtures = [
  ["m17 heat calendar + matrix", "sample_m17.json"],
  ["m18 gauge-list", "sample_m18.json"],
  ["m19 stat-grid + denom", "sample_m19.json"],
  ["m20 chart compact units", "sample_m20.json"],
  ["m21 typed table", "sample_m21.json"],
  ["m22 roadmap v2", "sample_m22.json"],
  ["m23 tasks tree", "sample_m23.json"],
  ["m24 pipeline flow", "sample_m24.json"],
  ["m25 dashboard container", "sample_m25.json"],
  ["m26 53-week calendar", "sample_m26.json"],
];

const testdataDir = join(repoRoot, "internal/pdrender/testdata");
const CHROME_DIM_COLOR = "color:#51515b"; // see derivation above
const RAW_DIM_TOKEN = "color:#52525b"; // must be ABSENT — a leak means the lipgloss round-trip was bypassed

for (const [label, file] of slateFixtures) {
  const json = readFileSync(join(testdataDir, file), "utf8");
  const out = render(json, 80, "dark");

  if (typeof out !== "string") fail(label + ": bpRenderTUI did not return a string");
  // (a) wrapper — excludes the classless decode-error <pre> (main.go:53)
  if (!out.startsWith('<pre class="bp-tui-pre">')) {
    fail(label + ': output did not start with <pre class="bp-tui-pre">; got: ' + out.slice(0, 80));
  }
  // (b) non-fallback / stale-blob tripwire (fallbackRenderer, blocks.go:308)
  if (out.includes("unknown block:")) {
    fail(label + ': output contains "unknown block:" — unregistered block type or STALE blob (run make wasm)');
  }
  // (c) dim-as-color — end-to-end dim-never-Faint proof (applySGR has no SGR-2 case)
  if (!out.includes(CHROME_DIM_COLOR)) {
    fail(label + ": output missing the ChromeDim escape " + CHROME_DIM_COLOR + " — dim rendered as Faint (SGR-2) would silently vanish here");
  }
  if (out.includes(RAW_DIM_TOKEN)) {
    fail(label + ": output leaked the raw ChromeDim token " + RAW_DIM_TOKEN + " — a code path bypassed the lipgloss TrueColor round-trip");
  }
  if (!out.endsWith("</pre>")) fail(label + ": output not closed with </pre>");

  console.log("SMOKE OK: " + label + " → " + out.length + " bytes, wrapper + non-fallback + dim-as-color (" + CHROME_DIM_COLOR + ") green");
}

const nestedJSON = readFileSync(join(repoRoot, "api/test/support/fixtures/nested-list-carriers.json"), "utf8");
for (const width of [20, 80]) {
  for (const theme of ["dark", "light"]) {
    const out = render(nestedJSON, width, theme);
    if (!out.startsWith('<pre class="bp-tui-pre">') || !out.endsWith("</pre>")) fail("nested lists: invalid wrapper");
    const text = out.replace(/<[^>]*>/g, "");
    for (const line of ["• Plan", "  1. Build", "     • Verify", "  2. Ship", "• Flat sibling", "• Fallback parent", "  1. Alias child"]) {
      if (!text.includes(line)) fail(`nested lists ${width}/${theme}: missing ${line}`);
    }
    if (text.includes("Inactive parent fallback")) fail("nested lists revived inactive fallback");
  }
}
console.log("SMOKE OK: shared nested-list fixture, mixed markers, 20/80 columns and light/dark");


// ── image mosaic through the REAL blob (wasm-tui-image-mosaic) ───────────────
//
// bpRenderTUI takes an optional 5th argument: the reader's {src: base64} image
// map. These arms prove, through the actually-built wasm and the committed
// loader, that:
//   (1) with no map, an image block keeps the honest "(view in Studio)" box
//       — the pre-fix behaviour, and still the behaviour when JS pre-fetch fails;
//   (2) with a valid same-origin PNG, the SAME block paints a half-block mosaic
//       (no box). Revert the ImageResolver wiring in main.go and this arm reds;
//   (3) a third-party / cross-origin src, and malformed or oversized entries,
//       keep the box — the Go-side bounds, not the page's good manners;
//   (4) none of the above throws: a hostile map costs you the picture, never
//       the render.
const MOSAIC_SRC = "/media/smoke-mosaic.png";
// A 24×12 truecolor PNG (536 bytes), generated deterministically; small enough
// to inline, large enough that the no-upscale mosaic emits many half-block cells.
const MOSAIC_PNG_B64 =
  "iVBORw0KGgoAAAANSUhEUgAAABgAAAAMCAIAAAD3UuoiAAAB30lEQVR4nA3MkbrGMAyA4fI4PC6Pw+PyODwOfs/P5XF4HB6Xx+VdxznvBbylFJaCFNZCLWwFLeyFVjgKVjgLXvgVeuEqROEuZOEpjMJbmIWvUIqwCCKsQhU2QYVdaMIhmHAKLvyELlxCCLeQwiMM4RWm8Ml/VFkqUlkrtbJVtLJXWuWoWOWseOVX6ZWrEpW7kpWnMipvZVa++h8piyLKqlRlU1TZlaYciimn4spP6cqlhHIrqTzKUF5lKp/+R42lIY21URtbQxt7ozWOhjXOhjd+jd64GtG4G9l4GqPxNmbja/+RsRhirEY1NkON3WjGYZhxGm78jG5cRhi3kcZjDOM1pvHZf+QsjjirU53NUWd3mnM45pyOOz+nO5cTzu2k8zjDeZ3pfP4fdZaOdNZO7Wwd7eyd1jk61jk73vl1eufqROfuZOfpjM7bmZ2v/0fBEkiwBjXYAg32oAVHYMEZePALenAFEdxBBk8wgjeYwRf/UbIkkqxJTbZEkz1pyZFYciae/JKeXEkkd5LJk4zkTWby5X80WAYyWAd1sA10sA/a4BjY4Bz44Dfog2sQg3uQg2cwBu9gDr7xH02WiUzWSZ1sE53skzY5JjY5Jz75TfrkmsTknuTkmYzJO5mTb/IHxiiNMCHYseMAAAAASUVORK5CYII=";

const imageDoc = JSON.stringify({
  blocks: [{ id: "img-1", type: "image", src: MOSAIC_SRC, alt: "Smoke mosaic" }],
});
const STUDIO_BOX = "view in Studio";
const HALF_BLOCK = "▀"; // the mosaic's one and only cell glyph

function renderImages(map) {
  return render(imageDoc, 80, "dark", "", map);
}

// (1) no usable map → honest box (also covers a reader that never pre-fetched)
for (const [label, arg] of [["omitted", undefined], ["null", null], ["empty", {}], ["not-an-object", "nope"]]) {
  const out = arg === undefined ? render(imageDoc, 80, "dark", "") : renderImages(arg);
  if (!out.includes(STUDIO_BOX)) fail("image map " + label + ": expected the honest box, got:\n" + out);
  if (out.includes(HALF_BLOCK)) fail("image map " + label + ": painted a mosaic with no usable map");
}
console.log('SMOKE OK: no/empty/invalid image map -> honest "(view in Studio)" box');

// (2) valid same-origin PNG → mosaic (the arm that reds if the wiring is reverted)
const mosaicOut = renderImages({ [MOSAIC_SRC]: MOSAIC_PNG_B64 });
if (mosaicOut.includes(STUDIO_BOX)) {
  fail("valid image map still rendered the box — ImageResolver not wired:\n" + mosaicOut);
}
if (!mosaicOut.includes(HALF_BLOCK)) fail("valid image map produced no half-block cells");
if (!/background:#[0-9a-f]{6}/.test(mosaicOut)) fail("mosaic emitted no 24-bit background colour");
if (!mosaicOut.startsWith('<pre class="bp-tui-pre">') || !mosaicOut.endsWith("</pre>")) {
  fail("mosaic output broke the <pre> wrapper");
}
console.log("SMOKE OK: same-origin image map -> half-block mosaic (" + mosaicOut.length + " bytes)");

// (3) bounds — each of these must keep the box, and must not throw
const refusals = [
  ["cross-origin absolute", { "https://evil.example/x.png": MOSAIC_PNG_B64 }],
  ["protocol-relative", { "//evil.example/x.png": MOSAIC_PNG_B64 }],
  ["data: url", { "data:image/png;base64,AAAA": MOSAIC_PNG_B64 }],
  ["relative path", { "media/x.png": MOSAIC_PNG_B64 }],
  ["malformed base64", { [MOSAIC_SRC]: "!!!! not base64 !!!!" }],
  ["unsupported mime (webp)", { [MOSAIC_SRC]: Buffer.from("RIFF    WEBPVP8 junkjunk").toString("base64") }],
  ["oversized entry", { [MOSAIC_SRC]: "A".repeat(8 * 1024 * 1024) }],
  ["non-string value", { [MOSAIC_SRC]: 12345 }],
];
for (const [label, map] of refusals) {
  let out;
  try {
    out = renderImages(map);
  } catch (e) {
    fail("refused image map (" + label + ") THREW instead of degrading: " + e);
  }
  if (!out.includes(STUDIO_BOX)) fail(label + ": expected the honest box, got:\n" + out.slice(0, 400));
  if (out.includes(HALF_BLOCK)) fail(label + ": painted a mosaic from a refused entry");
}
console.log("SMOKE OK: " + refusals.length + " refused image-map shapes degraded to the honest box without throwing");

// (4) a refused entry alongside a good one leaves the good one working
const mixedDoc = JSON.stringify({
  blocks: [
    { id: "img-1", type: "image", src: MOSAIC_SRC, alt: "Smoke mosaic" },
    { id: "img-2", type: "image", src: "https://evil.example/x.png", alt: "Third party" },
  ],
});
const mixed = render(mixedDoc, 80, "dark", "", {
  [MOSAIC_SRC]: MOSAIC_PNG_B64,
  "https://evil.example/x.png": MOSAIC_PNG_B64,
});
if (!mixed.includes(HALF_BLOCK)) fail("mixed doc: the same-origin image lost its mosaic");
if (!mixed.includes(STUDIO_BOX)) fail("mixed doc: the third-party image lost its honest box");
console.log("SMOKE OK: mixed doc — same-origin mosaic AND third-party box in one render");

console.log("SMOKE OK: all " + slateFixtures.length + " slate fixtures (m17→m26) rendered through the wasm reader with three refutations each");
process.exit(0);
