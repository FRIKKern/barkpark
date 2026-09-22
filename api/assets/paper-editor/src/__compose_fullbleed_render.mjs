// __compose_fullbleed_render.mjs — the ARBITER for compose-block width model.
//
// THE QUESTION. pdrender (internal/pdrender) lays `notes`, `cards` and
// `pipeline` out by LEFT-PACKING their widgets: a side-by-side row is
// N*cellW + (N-1)*gutter wide, so the right margin is ragged, and the stacked
// twin `sample_m5` is excluded from `boxFixtures` in align_test.go on the
// premise that compose blocks are "content-sized". That premise is a claim
// about the CANONICAL READER, and nobody had measured the reader.
//
// ONE SPEC, TWO INTERPRETERS: the arbiter is what the reader DOES, not what is
// convenient in a terminal. This file measures it, in a real browser, from the
// REAL emitter's frozen HTML (js/packages/react/tests/fixtures/pd-golden/*),
// against the reader's own container geometry.
//
// WHAT IT RECORDS, per family x context x width:
//   containerRight  content-box right edge of the box the block lives in
//   outerRight      right edge of the block's own outer box
//   childRight      right edge of the LAST visible child widget
// Full-bleed means both edges land ON containerRight. Content-sized means one
// of them stops short. The two are reported SEPARATELY, because a block can be
// a full-width box full of left-packed children — which is exactly the shape
// pdrender produces, and exactly what a single "is it full width" probe would
// miss.
//
// TWO CONTROLS, because a probe that returns the same number for every input
// is a broken instrument, not a result:
//   SABOTAGE      each family is re-measured with a declaration injected that
//                 MUST left-pack it (auto-fill FIXED tracks / justify-content:
//                 start / flex: none). The run fails if sabotage does not move
//                 the number: that would mean nothing was being measured.
//   DISCRIMINATION (a) `.bp-stat` standalone is genuinely shrink-to-fit
//                 (`display: inline-flex`, documented at length in
//                 paper-surface.css) and MUST report a short right edge in the
//                 same run; (b) the three viewport widths must yield three
//                 DIFFERENT containerRight values.
//
// THE ANSWER IT GAVE, 2026-09-17: the reader STRETCHES. Outer box full-bleed in
// 18/18 cases and the last child flush in 15/15 measured cases, identically in
// the stacked and the horizontal arrangement (the 3 excluded cases are the
// .bp-pipe scroll container overflowing on purpose; its own outer box is still
// flush). components.ex emits these three families with NO reference to the
// block's `layout` key, so the reader's HTML for the stacked twin `sample_m5`
// and the horizontal twin `sample_m10` is byte-identical and the orientation
// distinction exists only in pdrender. Carried into the pdrender lane as
// task-587aef9aaf6f8248 (uniform Path-A, both orientations).
//
// It also SUPERSEDES a stale verdict: pdle-r2-le-children-close stamped
// "cards stretch, notes container-stretch/content-left, pipeline LEFT-PACKS"
// off `web/components/portable-doc.tsx`, a file that no longer exists. The JS
// reader (js/packages/react/src/blocks/core.ts) now emits the same `bp-*`
// classes as the Elixir emitter, and web mounts them inside
// `.bp-paper-surface` (web/components/paper-editor-doc.tsx) — one stylesheet,
// one answer. Which is the whole reason this is a rendered measurement and not
// a reading: a source reading dates faster than the thing it describes.
//
//   Run:  node src/__compose_fullbleed_render.mjs
//   Env:  BP_CHROME=/path/to/chrome     pin the binary
//         BP_FULLBLEED_VERBOSE=1        print the full measurement table
//
// NO CHROMIUM, NO FAILURE: prints SKIP and exits 0, like __narrow_render.mjs.
// Opt-in, not in `npm test`, for the same reason.

import { readFileSync, readdirSync, writeFileSync, mkdtempSync, existsSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { tmpdir, homedir } from "node:os";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO = join(__dirname, "../../../..");
const VERBOSE = !!process.env.BP_FULLBLEED_VERBOSE;
// 1280 and 700 both hit the 660px surface cap but differ in gutter (the
// 767px breakpoint), 390 is a phone. Three DIFFERENT content widths, which is
// what the discrimination arm below asserts.
const WIDTHS = (process.env.BP_FULLBLEED_WIDTHS || "1280,700,390").split(",").map(Number);
const EPS = 0.55; // sub-pixel: a flush edge is exact to within half a device px

function findChrome() {
  if (process.env.BP_CHROME) return process.env.BP_CHROME;
  const appBin = "Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing";
  const cache = join(homedir(), ".cache/puppeteer");
  for (const kind of ["chrome-headless-shell", "chrome"]) {
    const root = join(cache, kind);
    if (!existsSync(root)) continue;
    for (const build of readdirSync(root)) {
      for (const [dir, bin] of [
        [`${kind}-mac-arm64`, kind === "chrome" ? appBin : kind],
        [`${kind}-mac-x64`, kind === "chrome" ? appBin : kind],
        [`${kind}-linux64`, kind],
      ]) {
        const p = join(root, build, dir, bin);
        if (existsSync(p)) return p;
      }
    }
  }
  for (const p of [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/usr/bin/google-chrome",
    "/usr/bin/chromium",
    "/usr/bin/chromium-browser",
  ]) if (existsSync(p)) return p;
  return null;
}

const CHROME = findChrome();
if (!CHROME) {
  console.log("SKIP  __compose_fullbleed_render.mjs — no Chromium found.");
  console.log("      Set BP_CHROME=/path/to/chrome, or `npx @puppeteer/browsers install chrome-headless-shell`.");
  process.exit(0);
}

const surfaceCss = readFileSync(join(REPO, "api/assets/paper-surface/paper-surface.css"), "utf8");

// The reader page's own container geometry, transcribed from the
// `.bp-paper-surface` block in api/lib/barkpark_web/layouts/root.html.heex
// (find it with `grep -n 'paper-gutter: 40px' …root.html.heex`) — the sheet
// deliberately ships without element rules, so a harness that omits these
// measures a surface with no gutter and no cap, and every number is wrong.
// Same transcription __narrow_render.mjs uses.
const CONTAINER_CSS = `
  html, body { margin: 0; padding: 0; }
  .bp-paper-surface {
    background: #fff; color: #111;
    --paper-gutter: 40px;
    max-width: 660px;
    margin: 0 auto;
    padding: 56px var(--paper-gutter);
    min-height: 100%;
    box-sizing: border-box;
  }
  @media (max-width: 767px) { .bp-paper-surface { --paper-gutter: 24px; padding: 48px var(--paper-gutter); } }
  @media (max-width: 479px) { .bp-paper-surface { --paper-gutter: 16px; padding: 32px var(--paper-gutter); } }
`;

const TMP = mkdtempSync(join(tmpdir(), "bp-fullbleed-"));

const goldenDir = join(REPO, "js/packages/react/tests/fixtures/pd-golden");
function golden(name) {
  const p = join(goldenDir, `${name}.golden.json`);
  if (!existsSync(p)) return null;
  return JSON.parse(readFileSync(p, "utf8")).expectedHtml || null;
}

// ── the three compose families, as the REAL emitter writes them ──────────────
//
// components.ex emits notes/cards/pipeline with NO reference to the block's
// `layout` key (grep `layout` in api/lib/barkpark/portable_doc/render/
// components.ex: the only two hits are a changelog line and a date format).
// So the reader's HTML for the STACKED twin (`sample_m5`) and the HORIZONTAL
// twin (`sample_m10`, `layout: {mode: "grid"}`) is BYTE-IDENTICAL, and the
// orientation difference exists only in pdrender. The two CONTEXTS below are
// therefore the two real reader arrangements of that identical markup: alone
// in the stream, and inside a section-grid cell beside a sibling.
const FAMILIES = {
  notes: { outer: ".bp-notes", child: ".bp-note" },
  cards: { outer: ".bp-cards", child: ".bp-card" },
  pipeline: { outer: ".bp-pipe-scroll", child: ".bp-pnode", flow: ".bp-pipe" },
};

const CONTEXTS = {
  // "stacked": the block alone in the vertical stream, pdrender's sample_m5 shape.
  stream: (html) => `<div id="ctx">${html}</div>`,
  // "horizontal": the block in one cell of a two-track section grid beside a
  // sibling — the reader's only side-by-side arrangement, pdrender's
  // sample_m10 shape.
  grid: (html) =>
    `<div class="bp-section__grid" style="--bp-tracks:2">` +
    `<div class="bp-section__cell" id="ctx">${html}</div>` +
    `<div class="bp-section__cell"><p>sibling</p></div></div>`,
};

// The DISCRIMINATION control: a block this sheet genuinely content-sizes.
// `.bp-stat` standalone is `display: inline-flex` with `min-width: 130px` — its
// own paper-surface.css comment spends 30 lines on the fact that it is sized
// from its content. If this probe ever reports it flush with the container,
// the probe is measuring something other than what it claims.
const CONTENT_SIZED_CONTROL =
  `<div class="bp-stat"><div class="bp-stat__v">42</div><div class="bp-stat__l">rows</div></div>`;

// Injected CSS that MUST left-pack each family. This is the SABOTAGE arm: the
// measurement is only trustworthy if these move the numbers.
const SABOTAGE = {
  notes: `.bp-paper-surface .bp-notes { align-items: flex-start; } .bp-paper-surface .bp-note { display: inline-grid; }`,
  cards: `.bp-paper-surface .bp-cards { grid-template-columns: repeat(auto-fill, 220px); justify-content: start; }`,
  pipeline: `.bp-paper-surface .bp-pnode { flex: none; } .bp-paper-surface .bp-pipe { justify-content: flex-start; }`,
};

// Measures ONE page: for every probe selector, the content-box right edge of
// #ctx, the outer block's right edge, and the LAST child widget's right edge.
function measure(bodyHtml, width, probes, extraCss = "") {
  const page = `<!doctype html><html><head><meta charset="utf-8"><style>
${CONTAINER_CSS}
${surfaceCss}
${extraCss}
</style></head><body>
<main class="bp-paper-surface"><div id="paper-body">${bodyHtml}</div></main>
<pre id="__out">pending</pre>
<script>
function contentRight(el) {
  var r = el.getBoundingClientRect(), cs = getComputedStyle(el);
  return r.right - parseFloat(cs.paddingRight || 0) - parseFloat(cs.borderRightWidth || 0);
}
var ctx = document.getElementById('ctx');
var out = { vw: window.innerWidth, containerRight: ctx ? contentRight(ctx) : null, probes: {} };
var P = ${JSON.stringify(probes)};
for (var k in P) {
  var spec = P[k];
  var o = document.querySelector(spec.outer);
  var kids = document.querySelectorAll(spec.child);
  var last = kids.length ? kids[kids.length - 1] : null;
  var flow = spec.flow ? document.querySelector(spec.flow) : null;
  out.probes[k] = {
    found: !!o,
    outerRight: o ? o.getBoundingClientRect().right : null,
    childCount: kids.length,
    childRight: last ? last.getBoundingClientRect().right : null,
    // A .bp-pipe wider than its scroll container overflows ON PURPOSE; the
    // child edge is then meaningless as a parity signal and this flag says so.
    flowOverflows: flow ? (flow.scrollWidth > flow.clientWidth + 0.5 || flow.getBoundingClientRect().width > o.clientWidth + 0.5) : false
  };
}
document.getElementById('__out').textContent = 'RESULT' + JSON.stringify(out);
</script></body></html>`;
  const file = join(TMP, "case.html");
  writeFileSync(file, page);
  const dom = execFileSync(CHROME, [
    "--headless", "--disable-gpu", "--no-sandbox", "--hide-scrollbars",
    `--window-size=${width},900`, "--virtual-time-budget=1500",
    "--dump-dom", `file://${file}`,
  ], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], maxBuffer: 64 * 1024 * 1024 });
  const m = dom.match(/RESULT(\{.*?\})<\/pre>/s);
  if (!m) throw new Error("harness produced no RESULT marker — the page did not run its script");
  return JSON.parse(m[1].replace(/&quot;/g, '"').replace(/&amp;/g, "&").replace(/&lt;/g, "<").replace(/&gt;/g, ">"));
}

let failures = 0;
const check = (name, fn) => {
  try { fn(); if (VERBOSE) console.log(`PASS  ${name}`); }
  catch (e) { failures++; console.log(`FAIL  ${name}\n      ${e.message}`); }
};
const r2 = (n) => (n === null ? "—" : Math.round(n * 100) / 100);

const missing = Object.keys(FAMILIES).filter((f) => !golden(f));
if (missing.length) {
  console.log(`SKIP  __compose_fullbleed_render.mjs — golden HTML absent for: ${missing.join(", ")}`);
  console.log(`      expected under ${goldenDir}`);
  process.exit(0);
}

// ── 1. the measurement table ─────────────────────────────────────────────────

const rows = [];
for (const width of WIDTHS) {
  for (const [ctxName, wrap] of Object.entries(CONTEXTS)) {
    for (const [fam, spec] of Object.entries(FAMILIES)) {
      const base = measure(wrap(golden(fam)), width, { [fam]: spec });
      const p = base.probes[fam];
      if (!p.found) throw new Error(`probe ${fam} matched no ${spec.outer} — the golden HTML changed shape`);
      rows.push({
        width, ctx: ctxName, fam,
        containerRight: base.containerRight,
        outerRight: p.outerRight,
        childRight: p.childRight,
        childCount: p.childCount,
        flowOverflows: p.flowOverflows,
        outerGap: base.containerRight - p.outerRight,
        childGap: base.containerRight - p.childRight,
      });
    }
  }
}

console.log("VERDICT TABLE — right edges, px from the viewport's left. gap = containerRight - edge.");
console.log("width  ctx     family    containerRight  outerRight(gap)      lastChildRight(gap)   n  flowOverflow");
for (const r of rows) {
  console.log(
    `${String(r.width).padEnd(6)} ${r.ctx.padEnd(7)} ${r.fam.padEnd(9)} ` +
    `${String(r2(r.containerRight)).padEnd(15)} ${String(`${r2(r.outerRight)} (${r2(r.outerGap)})`).padEnd(20)} ` +
    `${String(`${r2(r.childRight)} (${r2(r.childGap)})`).padEnd(21)} ${String(r.childCount).padEnd(2)} ${r.flowOverflows}`,
  );
}

// ── 2. DISCRIMINATION (a): a genuinely content-sized block reads SHORT ───────

const ctrlGaps = [];
for (const width of WIDTHS) {
  const m = measure(CONTEXTS.stream(CONTENT_SIZED_CONTROL), width, {
    stat: { outer: ".bp-stat", child: ".bp-stat__l" },
  });
  ctrlGaps.push({ width, gap: m.containerRight - m.probes.stat.outerRight });
}
console.log(`\nCONTROL (content-sized .bp-stat): ${ctrlGaps.map((c) => `${c.width}px -> gap ${r2(c.gap)}`).join(", ")}`);
check("DISCRIMINATION a — the content-sized control reads a NON-zero right gap", () => {
  const flush = ctrlGaps.filter((c) => Math.abs(c.gap) <= EPS);
  if (flush.length) {
    throw new Error(
      `a standalone .bp-stat measured FLUSH with the container at ${flush.map((c) => c.width + "px").join(", ")}.\n` +
      "      .bp-stat is display:inline-flex, shrink-to-fit by construction (see the 30-line\n" +
      "      comment above the rule in paper-surface.css). If it reads flush, this probe is\n" +
      "      reporting the container's edge for everything and measures nothing.",
    );
  }
});

// ── 3. DISCRIMINATION (b): different widths yield different numbers ─────────

check("DISCRIMINATION b — the three viewports yield three different container widths", () => {
  // ONE context only: `grid` collapses to a single track below 720px, so a
  // mixed set would compare two different boxes and could agree by accident.
  const byWidth = new Map();
  for (const r of rows.filter((r) => r.ctx === "stream")) byWidth.set(r.width, r2(r.containerRight));
  const seen = new Set([...byWidth].map(([w, v]) => `${w}:${v}`));
  const vals = new Set(byWidth.values());
  if (vals.size < byWidth.size) {
    throw new Error(
      `containerRight is not distinct per viewport: ${[...byWidth].map(([w, v]) => `${w}->${v}`).join(", ")}.\n` +
      "      A probe that answers the same number for every input is a broken instrument.",
    );
  }
  if (VERBOSE) console.log(`      ${seen.size} distinct (width, containerRight) pairs`);
});

// ── 4. SABOTAGE: left-packing each family MUST move the number ───────────────

for (const [fam, css] of Object.entries(SABOTAGE)) {
  check(`SABOTAGE ${fam} — injected left-packing is DETECTED (the probe is live)`, () => {
    const width = 1280;
    const clean = measure(CONTEXTS.stream(golden(fam)), width, { [fam]: FAMILIES[fam] });
    const broken = measure(CONTEXTS.stream(golden(fam)), width, { [fam]: FAMILIES[fam] }, css);
    const cleanGap = clean.containerRight - clean.probes[fam].childRight;
    const brokenGap = broken.containerRight - broken.probes[fam].childRight;
    if (VERBOSE) console.log(`      ${fam}: childGap clean ${r2(cleanGap)} -> sabotaged ${r2(brokenGap)}`);
    if (Math.abs(brokenGap - cleanGap) <= EPS) {
      throw new Error(
        `left-packing ${fam} did not move the last child's right edge ` +
        `(${r2(cleanGap)} -> ${r2(brokenGap)}). Either the injected CSS no longer ` +
        "left-packs this family, or the probe is not reading the child it names. " +
        "Nothing below this line means anything until it moves.",
      );
    }
    if (brokenGap <= EPS) {
      throw new Error(
        `${fam} still reads FLUSH (gap ${r2(brokenGap)}) with left-packing injected — ` +
        "the sabotage arm is not sabotaging.",
      );
    }
  });
}

// ── 5. THE VERDICT: outer box and children, named SEPARATELY ────────────────

const outerShort = rows.filter((r) => Math.abs(r.outerGap) > EPS);
check("the compose OUTER box is full-width in every family, context and width", () => {
  if (outerShort.length) {
    throw new Error(
      `${outerShort.length} of ${rows.length} cases have an outer box narrower than its container:\n      ` +
      outerShort.map((r) => `${r.fam} ${r.ctx} @${r.width}: gap ${r2(r.outerGap)}px`).join("\n      "),
    );
  }
});

// A pipeline whose flow overflows its scroll container is scrolling ON PURPOSE;
// its last node's edge is then not a width-model signal and is excluded here.
// Excluded cases are NAMED, so "0 failures" can never mean "0 measured".
const childRows = rows.filter((r) => !r.flowOverflows);
const excluded = rows.filter((r) => r.flowOverflows);
if (excluded.length) {
  console.log(
    `\nEXCLUDED from the child-edge verdict (scroll container overflowing BY DESIGN): ` +
    excluded.map((r) => `${r.fam} ${r.ctx} @${r.width}`).join(", "),
  );
}
const childShort = childRows.filter((r) => Math.abs(r.childGap) > EPS);
check("the LAST VISIBLE CHILD is flush with the container in every non-overflowing case", () => {
  if (!childRows.length) {
    throw new Error("every case was excluded as overflowing — nothing was measured, which is not a pass.");
  }
  if (childShort.length) {
    throw new Error(
      `${childShort.length} of ${childRows.length} measured cases leave a ragged right margin:\n      ` +
      childShort.map((r) => `${r.fam} ${r.ctx} @${r.width}: gap ${r2(r.childGap)}px`).join("\n      "),
    );
  }
});

console.log(
  `\nARBITER: outer box full-width in ${rows.length - outerShort.length}/${rows.length} cases; ` +
  `last visible child flush in ${childRows.length - childShort.length}/${childRows.length} measured cases ` +
  `(${excluded.length} excluded as by-design scroll).`,
);
console.log(
  outerShort.length === 0 && childShort.length === 0
    ? "ARBITER: the reader STRETCHES compose blocks — full-bleed outer box AND flush children,\n" +
      "         identically in the stacked and the horizontal arrangement. pdrender's left-packing\n" +
      "         is NOT reader parity; Path-A (right-pad to full width, BOTH orientations) is the\n" +
      "         consistent answer."
    : "ARBITER: the reader does NOT uniformly stretch — read the rows above before changing pdrender.",
);
console.log(failures === 0 ? "\nALL PASS" : `\n${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
