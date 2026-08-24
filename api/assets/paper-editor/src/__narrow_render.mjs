// __narrow_render.mjs — the RENDERED half of the narrow-viewport sweep.
//
// `__narrow_overflow_guards.test.mjs` is a source guard: it greps
// paper-surface.css for declarations. That catches a deleted declaration, but
// it cannot tell you whether the page actually scrolls sideways on a phone,
// and it cannot find a block whose overflow nobody has thought about yet. Its
// own header says the rendered assertion "needs a browser harness — outside
// api/assets, left to that lane". This IS that harness, and it lives here
// because the thing under test is api/assets/paper-surface/paper-surface.css.
//
// WHY A REAL BROWSER. Reasoning about CSS from source is how a previous pass
// blamed an element whose proposed fix was byte-identical in effect: the
// element already had `overflow: hidden`, whose automatic minimum size is
// already 0 per the flexbox spec, so the "fix" changed nothing and the real
// causes were elsewhere. Every claim below is a measurement taken from
// headless Chromium, not an argument about cascade.
//
//   Run:  node src/__narrow_render.mjs          (or: npm run narrow:render)
//   Env:  BP_CHROME=/path/to/chrome   pin the binary
//         BP_NARROW_WIDTHS=390,320    viewports to test
//         BP_NARROW_VERBOSE=1         print every case, not just failures
//
// NO CHROMIUM, NO FAILURE. When no browser is found this prints SKIP and exits
// 0. It is deliberately NOT in `npm test`: the suite must stay runnable on a
// machine with no browser, and a gate that cannot run everywhere is a gate
// people learn to ignore.
//
// IT REDS ON THE COMMIT THAT INTRODUCES IT, ON PURPOSE. This harness landed
// before the three fixes it found (#13773 headings and the eyebrow role,
// #13774 the stat value and label, #13776 the task-detail title). Until those
// merge it reports exactly those rows and exits 1. That is the instrument
// telling the truth about the tree, not a broken instrument — and because it is
// opt-in it gates nothing while it says so. If it is still red after all three
// have landed, something else is wrong and the output names it.
//
// COVERAGE, HONESTLY. Two corpora, and neither is complete:
//   1. js/packages/react/tests/fixtures/pd-golden/*.golden.json — the frozen
//      HTML of the real Elixir emitter for 63 block types. Real markup, but
//      tame content: the fixtures carry short, well-behaved strings.
//   2. WORD_CASES below — the long unbreakable tokens a paper really receives
//      (a Norwegian or German compound, a paper URL, a task slug, a formatted
//      money figure) injected into one field at a time.
// Corpus 1 alone reports the sheet as clean at 390px. Every defect this file
// pins was found only by corpus 2. And 117 of the ~341 `.bp-*` classes that
// paper-surface.css styles are rendered by NO fixture at all, so corpus 1's
// silence is not evidence about them.
//
// THE CONTROL MATTERS. A plain `<p>` in this surface carries no wrap guard
// either, so "block X overflows with a 22-character unbreakable word" is only
// interesting if plain prose survives the same word. CONTROL_CASES measure the
// baseline and the block assertion below skips every token the control itself
// cannot survive.

import { readFileSync, readdirSync, writeFileSync, mkdtempSync, existsSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { tmpdir, homedir } from "node:os";

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO = join(__dirname, "../../../..");
const WIDTHS = (process.env.BP_NARROW_WIDTHS || "390,320").split(",").map(Number);
const VERBOSE = !!process.env.BP_NARROW_VERBOSE;

// ── 0. find a browser, or skip ───────────────────────────────────────────────

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
  console.log("SKIP  __narrow_render.mjs — no Chromium found.");
  console.log("      Set BP_CHROME=/path/to/chrome, or `npx @puppeteer/browsers install chrome-headless-shell`.");
  process.exit(0);
}

// ── 1. the page under test ───────────────────────────────────────────────────

const surfaceCss = readFileSync(join(REPO, "api/assets/paper-surface/paper-surface.css"), "utf8");

// The reader page's own container geometry. paper-surface.css deliberately does
// NOT carry it — Stylesheet.css/0 ships the sheet inside published documents
// "with no `.bp-paper-surface` element rules" — so these live in the root
// layout instead. Transcribed from the `.bp-paper-surface` block in
// api/lib/barkpark_web/layouts/root.html.heex; find it with
// `grep -n 'paper-gutter: 40px' api/lib/barkpark_web/layouts/root.html.heex`.
// A harness that omits them measures a surface with no gutter and no max-width,
// which is not the box a reader gets, and every threshold below would be wrong.
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

const TMP = mkdtempSync(join(tmpdir(), "bp-narrow-"));

// Measures ONE page and returns { vw, docScroll }. `docScroll > vw` is the
// whole assertion: the document scrolls sideways, which is what a reader on a
// phone actually suffers. It is deliberately NOT a per-element rect check —
// several blocks (.bp-table, .bp-chart, .bp-pipe-scroll, .bp-diff) overflow
// their own box ON PURPOSE inside an `overflow-x: auto` container, and a rect
// check flags all of them every run until nobody reads the output.
function measure(bodyHtml, width, extraCss = "") {
  const page = `<!doctype html><html><head><meta charset="utf-8"><style>
${CONTAINER_CSS}
${surfaceCss}
${extraCss}
</style></head><body>
<main class="bp-paper-surface"><div id="paper-body">${bodyHtml}</div></main>
<pre id="__out">pending</pre>
<script>
document.getElementById('__out').textContent = 'RESULT' + JSON.stringify({
  vw: window.innerWidth,
  docScroll: document.documentElement.scrollWidth
});
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

// ── 2. corpus 1: the real emitter's frozen HTML ──────────────────────────────

const goldenDir = join(REPO, "js/packages/react/tests/fixtures/pd-golden");
if (!existsSync(goldenDir)) {
  console.log("SKIP  golden corpus — js/packages/react/tests/fixtures/pd-golden is absent.");
} else {
  const names = readdirSync(goldenDir).filter((f) => f.endsWith(".golden.json"));
  for (const width of WIDTHS) {
    const bad = [];
    for (const f of names) {
      const html = JSON.parse(readFileSync(join(goldenDir, f), "utf8")).expectedHtml;
      if (!html) continue;
      const r = measure(html, width);
      if (r.docScroll > r.vw) bad.push(`${f.replace(".golden.json", "")} (${r.docScroll}px in a ${r.vw}px viewport)`);
    }
    check(`no golden fixture scrolls the page sideways at ${width}px`, () => {
      if (bad.length) {
        throw new Error(
          `${bad.length} of ${names.length} block fixtures give the document horizontal scroll:\n      ` +
          bad.join("\n      ") +
          "\n      A block must contain its own overflow — either wrap the content " +
          "(overflow-wrap) or give the block an `overflow-x: auto` scroll container " +
          "the way .bp-table and .bp-pipe-scroll do. Widening the page is never the answer.",
        );
      }
    });
  }
}

// ── 3. corpus 2: real long tokens in one field at a time ─────────────────────

// Every string here is one a Barkpark paper genuinely receives. None is a
// synthetic monster: the compounds are dictionary words in a language Barkpark
// publishes in (the ONIX/Bokbasen surface is Norwegian), the URL is this
// repo's own paper permalink shape, the money figure is what a `stat` block
// holds. `$1,234,567.89` offers no break opportunity at all — comma and period
// do not provide one inside a number — which is why 13 characters is enough.
const WORD_CASES = [
  ["norwegian compound", "menneskerettighetsorganisasjon"],
  ["norwegian compound 2", "implementasjonsdetaljer"],
  ["german compound", "Geschwindigkeitsbegrenzung"],
  ["paper permalink", "https://guerrilla.barkpark.cloud/papers/mechanical-spacing-doctrine"],
  ["paper path", "/papers/mechanical-spacing-doctrine"],
  ["task slug", "task-0e7a1a8ed32b5de5"],
  ["branch name", "feat/deploy-with-barkpark-warm-pool-provision"],
  ["formatted money", "$1,234,567.89"],
];

// The baseline. Plain prose carries no wrap guard anywhere in this sheet, so
// whatever it survives is the floor every other block is judged against.
const CONTROL_CASES = {
  "p": (t) => `<p>${t}</p>`,
  "li": (t) => `<ul><li>${t}</li></ul>`,
};

// The blocks under test. The `.bp-stats` grid puts the SAME long value in both
// cells on purpose: one long value in the first cell has room to spill into the
// second and still fit inside the viewport, so a single-cell probe reports a
// false clean. Every real stats row formats all of its values the same way.
const BLOCK_CASES = {
  "h1": (t) => `<h1>${t}</h1>`,
  "h2": (t) => `<h2>${t}</h2>`,
  "h3": (t) => `<h3>${t}</h3>`,
  "bp-role-ingress": (t) => `<p class="bp-role-ingress">${t}</p>`,
  "bp-role-pullquote": (t) => `<p class="bp-role-pullquote">${t}</p>`,
  "bp-role-eyebrow": (t) => `<p class="bp-role-eyebrow">${t}</p>`,
  "bp-stat__v in .bp-stats": (t) =>
    `<div class="bp-stats"><div class="bp-stat"><div class="bp-stat__v">${t}</div><div class="bp-stat__l">a</div></div>` +
    `<div class="bp-stat"><div class="bp-stat__v">${t}</div><div class="bp-stat__l">b</div></div></div>`,
  "bp-stat__v standalone": (t) => `<div class="bp-stat"><div class="bp-stat__v">${t}</div><div class="bp-stat__l">l</div></div>`,
  "bp-stat__l": (t) =>
    `<div class="bp-stats"><div class="bp-stat"><div class="bp-stat__v">42</div><div class="bp-stat__l">${t}</div></div>` +
    `<div class="bp-stat"><div class="bp-stat__v">9</div><div class="bp-stat__l">${t}</div></div></div>`,
  "bp-tasks__title": (t) => `<div class="bp-tasks"><div class="bp-tasks__title">${t}</div><div class="bp-tasks__list"></div></div>`,
  "bp-card__t": (t) => `<div class="bp-cards"><div class="bp-card"><div class="bp-card__t">${t}</div></div></div>`,
  "bp-tdetail__title": (t) => `<div class="bp-tdetail"><div class="bp-tdetail__title">${t}</div></div>`,
};

for (const width of WIDTHS) {
  const controlFails = new Set();
  for (const [, mk] of Object.entries(CONTROL_CASES)) {
    for (const [label, word] of WORD_CASES) {
      const r = measure(mk(word), width);
      if (r.docScroll > r.vw) controlFails.add(label);
    }
  }
  if (VERBOSE && controlFails.size) {
    console.log(`NOTE  at ${width}px the prose CONTROL itself overflows on: ${[...controlFails].join(", ")}`);
    console.log("      Those tokens are excluded below — a block that only matches the control");
    console.log("      is showing the surface's baseline behaviour, not a defect of its own.");
  }

  const bad = [];
  for (const [bname, mk] of Object.entries(BLOCK_CASES)) {
    for (const [label, word] of WORD_CASES) {
      // A block is only at fault where plain prose SURVIVES the same word.
      if (controlFails.has(label)) continue;
      const r = measure(mk(word), width);
      if (r.docScroll > r.vw) bad.push(`${bname} + ${label} "${word}" -> ${r.docScroll}px in ${r.vw}px`);
    }
  }
  check(`no block overflows on a token plain prose survives, at ${width}px`, () => {
    if (bad.length) {
      throw new Error(
        `${bad.length} block/token pairs scroll the page where a plain <p> does not:\n      ` +
        bad.join("\n      ") +
        "\n      These blocks set larger or bolder type than prose without the wrap " +
        "guard that larger type needs. `overflow-wrap: break-word` is the usual fix " +
        "(it does not participate in min-content sizing, so it cannot move a layout " +
        "that was not already overflowing); a shrink-to-fit box such as the " +
        "inline-flex `.bp-stat` needs `anywhere` instead, because only `anywhere` " +
        "reduces the intrinsic width the box is sized from.",
      );
    }
  });
}

console.log(failures === 0 ? "\nALL PASS" : `\n${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
