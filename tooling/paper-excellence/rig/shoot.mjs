// Hermetic screenshot pass — serves the rendered page from a LOCAL static
// root on an ephemeral port and photographs it with Playwright. No network:
// every external origin is aborted (see BLOCKED_ORIGINS).
//
//   node tooling/paper-excellence/rig/shoot.mjs <rendered.html> <out-dir> [label]
//
// Design notes, each paid for by a bug on 2026-08-12:
//
//   * NO absolute machine or session paths. Playwright is resolved from
//     $PLAYWRIGHT_DIR, else from candidate node_modules roots derived at
//     runtime (this worktree, and the primary checkout via
//     `git rev-parse --git-common-dir`). The archived evidence/shot.mjs
//     hardcoded both a gitignored import path and a dead scratchpad OUT dir —
//     neither is inherited here.
//   * The server binds port 0 (the OS picks a free port), so a squatted port
//     cannot be mistaken for ours. And we NEVER assert on the HTTP status:
//     a squatted port once answered 200 with alien JSON. Assertions are on
//     DOM CONTENT — the .bp-paper-article wrapper and a live paragraph count.
//   * Shots are FULL PAGE at deviceScaleFactor 2. The legacy shots in
//     ../evidence/shots are fold-only at 1x and are NOT comparable below the
//     fold (see README).

import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";
import { runCensus, HEAVY_PX } from "./census.mjs";

const RIG_DIR = path.dirname(new URL(import.meta.url).pathname);
const REPO_ROOT = path.resolve(RIG_DIR, "../../..");

// The gate shoots all four widths. SHOT_WIDTHS narrows the set for the committed
// baseline panel (see baseline.sh / README §Baselines).
//
// 1440 was replaced by 1280 + 1920 with pe-w1-evidence-breakout. The evidence
// band is flat between ~1120px and 1600px and grows above it, so 1280 and 1440
// are the SAME cell as far as layout is concerned (both land the band at its
// 1040px base) while 1920 is the only width that exercises the growth clause at
// all. 360 and 768 stay: they are where the band collapses back into the column,
// which is the half of the contract that keeps narrow viewports readable.
const VIEWPORTS = (process.env.SHOT_WIDTHS ?? "1920,1280,768,360").split(",").map((n) => Number(n.trim()));
const SCHEMES = ["light", "dark"];
const DEVICE_SCALE_FACTOR = 2;
// Output format. PNG is the default (gate runs, pixel work). The COMMITTED
// baseline panel uses SHOT_FORMAT=jpeg: a full-page 2x capture of a 100-block
// paper is ~16 MB as PNG (166 MB for the 5-paper panel — unshippable), and the
// same panel is ~12 MB as q82 JPEG. JPEG baselines are for HUMAN review and
// layout regression, not for exact pixel diffing — quantization noise makes
// them unsuitable as a byte-comparison oracle.
const FORMAT = process.env.SHOT_FORMAT === "jpeg" ? "jpeg" : "png";
const JPEG_QUALITY = Number(process.env.SHOT_QUALITY ?? 82);
// Any real capture of a paper is far bigger than this; anything under it means
// the encoder failed silently.
const MIN_SHOT_BYTES = 10_000;

// `.bp-paper-shell { max-width: 820px }` — the widest the reader column may
// ever measure. Anything wider means the shell rules did not apply.
const MAX_COLUMN_PX = 820;

// ── The EVIDENCE BREAKOUT contract (pe-w1-evidence-breakout) ─────────────────
// A block that improves with width steps OUT of the prose column into a wider
// centered band. Three things must stay true while it does, and each is asserted
// per (scheme × width) cell rather than measured once and eyeballed:
//
//   1. THE PAGE NEVER SCROLLS SIDEWAYS. A band computed from `100cqw` with no
//      gutter allowance would clear the viewport by exactly the scrollbar width
//      and every paper would rock horizontally. The allowance below is NOT slack
//      for the band: it is the ONE pre-existing overflow this rig has always
//      measured — 3px at 360px from a long unbreakable token inside a `<p>`,
//      recorded in the README and unchanged by the breakout. A band that escapes
//      its gutters overflows by tens to hundreds of px and reds here.
//   2. THE BAND STAYS ON THE COLUMN'S AXIS. `width` without the matching
//      `margin-inline` pull is a half-breakout: the component is correctly WIDE
//      and grows entirely to the right. Any width-only assertion passes it. The
//      centre-offset assertion is what catches it.
//   3. PROSE KEEPS ITS MEASURE. The whole device is worthless if widening the
//      evidence also widened the sentences, so the paragraphs are measured in
//      CHARACTERS PER LINE at every width and held inside the editorial band.
const MAX_DOC_OVERFLOW_PX = 4;
// Half a device pixel at 2x, plus sub-pixel layout rounding.
const MAX_BAND_OFFCENTRE_PX = 1.5;
// The editorial measure band. The wave TARGETS 66-72; the gate floors the wider
// 55-75 the whole reader is designed against, so a fixture whose paragraphs are
// unusually short does not red a change that never touched type.
//
// The CEILING applies at EVERY width — a measure past 75 characters is a defect
// on any screen, and it is the one the breakout could plausibly cause. The FLOOR
// applies only where the column reached its designed 660px: at 360 the viewport
// is narrower than the column, so the measure is set by the phone and not by the
// type (measured 34.7 CPL there, before this change and after it). Flooring at
// 360 would red every narrow cell forever and teach the next author to widen the
// band to escape it — the exact inversion of what the assertion is for.
const CPL_FLOOR = 55;
const CPL_CEILING = 75;
// The components the wave decided improve with width. Kept in ONE place and
// reported per cell, so a class that silently stops breaking out shows up as a
// missing row rather than as a green run.
const BREAKOUT_SELECTOR = ".bp-table, .bp-stats, .bp-chart, .bp-diff, .bp-filetree, figure";

// ── The SECTION BOUNDARY contract (pe-w1-section-lever) ──────────────────────
// A level-2 heading opens a section, and the boundary is drawn with AIR above a
// RULE — the benchmark artifact's `section { margin-bottom: 92px }` plus
// `.sec-head { border-top: 2px; padding-top: 16px }`
// (tooling/paper-excellence/evidence/erasure.html). Both halves are asserted on
// the RENDERED page, per boundary, for the reason the band is: the tokens can be
// declared, bridged, consumed and still land nowhere. Before this change every
// section opened at 51.3px with no rule at all — 1.9em of the h2's own font size,
// which is prose rhythm wearing a section's job.
//
// The numbers are PINNED to the artifact rather than read back out of the CSS.
// Reading `--bp-section-beat` and comparing the render to it would pass for any
// value the token happened to hold; pinning 92 means shrinking the token reds
// here, which is the only version of this assertion worth having.
const SECTION_BEAT_PX = 92;
// Sub-pixel layout rounding plus the ~0.04px the 4.18 ratio leaves against 92.
const SECTION_BEAT_TOL_PX = 2;
const SECTION_RULE_MIN_PX = 1;

// ── The HEAVY-RULE CENSUS contract (pe-quiet-rules) ──────────────────────────
// The section head above is asserted to EXIST. This is the other half: that it is
// the only thing on the page drawing at that weight.
//
// The benchmark artifact draws 59 horizontal rules and spends the heavy weight
// (2px) on 8 — its six `.sec-head` openings and the two edges of its closing
// `.declaration` frame. Every other line is a hairline. That is not decoration,
// it is the hierarchy: a reader who has learned that a thick line means "a new
// argument starts here" can navigate a long paper at scroll speed, and one
// component drawing its own 2px underline mid-argument takes that away.
//
// Measured with `census.mjs` — the SAME function, on both sides — this reader had
// drifted: table headers at 2px, card top accents at 3px, button frames at 2px.
// 8/6/26/25 heavy rules on four of the seven committed fixtures where only
// 6/0/10/11 section boundaries existed to justify them.
//
// The assertion is NOT a count. A count would pass a page that swapped a section
// head for a table header, and would have to be re-blessed every time a fixture
// gained a section. Every heavy rule is attributed to the element that drew it,
// and the check is that the element IS a section head.
//
// `.bp-declaration` — the artifact's framed finale — is deliberately NOT on this
// list. No Barkpark block emits it yet, and an allowlist entry that can never
// match is a decoy: it reads as coverage and gates nothing. The device that ships
// the framed finale extends this list, on purpose, with a fixture behind it.
// `.bp-section` is the CONTAINER shape of a section head — a `section` block,
// whose boundary is the container's own `border-top`. It draws at the same
// `--bp-section-rule` weight as the heading shape and for the same reason, so it
// belongs on this list: without it every container boundary would be counted a
// STRAY heavy rule. It is not a decoy entry — seven of them exist across the
// committed panel (3 design-probe, 3 portabledoc-showcase, 1 eight-minute-erasure).
const STRUCTURAL_RULE_SELECTOR =
  ".bp-paper-surface > #paper-body > h2, .bp-paper-surface > #paper-body > div:not([class]) > h2, .bp-paper-surface .bp-section";

// ── The INGRESS RATIO contract (pe-w2-bl-device5-ratio-arm, charter D6) ──────
// The opening ingress reads BIGGER than the body prose, and that size
// relationship is asserted as a RATIO of characters-per-line: the SAME
// canonical probe text measured under the ingress's computed style and under a
// plain body paragraph's. The regression this arm catches is the inverse of
// pe-w1-reader-editorial-typography (#11626), which converted every role from
// `rem` to `em` precisely because a rem-sized ingress freezes to the root and
// collapses the ratio the moment the body token moves.
//
// CANONICAL TEXT on BOTH sides, never each element's own words: own-text ratios
// are per-character sampling noise — 0.759–0.821 healthy across the seven
// committed fixtures, leaving 0.003 of margin at any threshold — while the
// canonical form reads 0.783 on every fixture at every width with ~0.05 of
// margin per side (ledger
// ingress-ratio-arm-mutation-and-instrument-divergence-2026-08-17.md).
// Mutation-proven: re-imposing the pre-#11626 `font-size: 1.28rem` on
// `.bp-role-ingress` moves every cell to ~0.880, far past the tolerance.
const INGRESS_RATIO = 0.783;
const INGRESS_RATIO_TOL = 0.01;
const INGRESS_PROBE_TEXT =
  "The rig measures what the reader sees: rules, air over a rule, and a column held to its measure — 0123456789.";

// ── MARGINAL-COLOR-AS-VERDICT (charter D5/D21) — the tone census ─────────────
// The eight-device crown's "marginal color as verdict" device ALREADY SHIPS on
// the existing tone tokens: a callout's or card's verdict is carried by the
// colour in its left margin (border-left) and its tone pair, resolved through
// `--bp-tone-*-bg/-fg` (callouts) and `--st-*` (cards), per theme — ZERO new
// tokens. This rig NAMES that device by measuring it: the computed color,
// background and left-margin accent of every tone-classed variant present, per
// (scheme × width) cell, recorded in report.json — so a token remap or a dead
// tone class is a text diff against the committed baselines instead of an
// eyeballed screenshot.
const TONE_SELECTORS = [
  ".bp-callout--info",
  ".bp-callout--success",
  ".bp-callout--warning",
  ".bp-callout--danger",
  ".bp-card--info",
  ".bp-card--ok",
  ".bp-card--warn",
  ".bp-card--danger",
];

// Offline policy. The reader pulls mermaid + asciinema from cdn.jsdelivr.net,
// and papers may embed remote media. We abort EVERY request that is not our
// own loopback server, so the rig can never depend on the network — and can
// never quietly photograph a different day's CDN. Typography and geometry are
// unaffected (proven); mermaid/diagram and asciicast blocks do not hydrate and
// remote images do not load, so those block types are EXCLUDED from every
// assertion here. See README.
const ALLOWED_HOST = "127.0.0.1";
const NOTED_BLOCKED_ORIGINS = ["cdn.jsdelivr.net (mermaid, asciinema-player)", "all non-loopback hosts"];

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".woff2": "font/woff2",
  ".json": "application/json",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".wasm": "application/wasm",
  ".gz": "application/gzip",
};

function fail(msg) {
  console.error(`rig/shoot: FAIL — ${msg}`);
  process.exit(1);
}

// ── The committed measurements as an oracle ──────────────────────────────────
//
//   node shoot.mjs --report-diff <baseline.report.json> <fresh.report.json>
//
// Until 2026-08-17 NOTHING compared a fresh capture to the committed panel:
// gate.sh shot to a temp dir and asserted, baseline.sh overwrote the repo, and
// the README's promise that "a band regression is a text diff in report.json"
// had no code behind it. This is that diff, and `gate.sh --check` drives it.
//
// IMAGE BYTE COUNTS ARE IGNORED, and only they. The reports are otherwise
// byte-reproducible on one host (design-probe and eight-minute-erasure
// re-shoots matched the committed baselines exactly), but a JPEG byte count
// differed ~1.5% for `hobby-hardening-capstone` across hosts while every
// measurement matched — encoder noise, which the README already refuses as an
// oracle. Everything else — column width, evidence band per component, prose
// CPL, section beats, doubled rules, the rule census, paragraph count, scale,
// blocked requests — is a MEASUREMENT and drift in it is a red.
const IGNORED_PATHS = /^shots\[\d+\]\.bytes$/;

function flatten(value, prefix, out) {
  if (Array.isArray(value)) {
    value.forEach((v, i) => flatten(v, `${prefix}[${i}]`, out));
  } else if (value && typeof value === "object") {
    for (const key of Object.keys(value).sort()) {
      flatten(value[key], prefix ? `${prefix}.${key}` : key, out);
    }
  } else {
    out.set(prefix, value);
  }
  return out;
}

function readReport(file, which) {
  if (!fs.existsSync(file)) fail(`no ${which} report at ${file}`);
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch (err) {
    fail(`${which} report at ${file} is not readable JSON: ${err.message}`);
  }
}

// Both files are named `<slug>.report.json`, so a bare basename in the verdict
// would print the same word twice and say nothing about WHICH is which.
const shortPath = (p) => {
  const rel = path.relative(process.cwd(), p);
  return rel && !rel.startsWith("..") ? rel : p;
};

function reportDiff(baselineFile, freshFile) {
  const baseline = flatten(readReport(baselineFile, "baseline"), "", new Map());
  const fresh = flatten(readReport(freshFile, "fresh"), "", new Map());

  const paths = [...new Set([...baseline.keys(), ...fresh.keys()])].sort();
  const diffs = [];
  let compared = 0;
  let ignored = 0;

  for (const p of paths) {
    if (IGNORED_PATHS.test(p)) {
      ignored += 1;
      continue;
    }
    const had = baseline.has(p);
    const has = fresh.has(p);
    if (!had) {
      diffs.push(`${p}: NOT IN BASELINE → ${JSON.stringify(fresh.get(p))}`);
      continue;
    }
    if (!has) {
      diffs.push(`${p}: ${JSON.stringify(baseline.get(p))} → MISSING FROM THIS RUN`);
      continue;
    }
    compared += 1;
    if (baseline.get(p) !== fresh.get(p)) {
      diffs.push(`${p}: ${JSON.stringify(baseline.get(p))} → ${JSON.stringify(fresh.get(p))}`);
    }
  }

  if (diffs.length) {
    console.error(
      `rig/shoot: FAIL — ${diffs.length} measurement(s) drifted from ${shortPath(baselineFile)} ` +
        `(baseline → this run; ${compared} values compared, ${ignored} image byte counts ignored)`,
    );
    for (const d of diffs) console.error(`  ${d}`);
    console.error(
      "rig/shoot:        this is a layout change, not noise. Review it, then " +
        "re-baseline with `bash tooling/paper-excellence/rig/baseline.sh <slug>`.",
    );
    process.exit(1);
  }

  console.log(
    `rig/shoot: report-check OK — ${shortPath(freshFile)} matches ${shortPath(baselineFile)}: ` +
      `${compared} measured values compared, 0 differences (${ignored} image byte counts ignored)`,
  );
}

function playwrightCandidates() {
  const roots = [REPO_ROOT];
  try {
    // In a git worktree the primary checkout (which holds the installed
    // js/node_modules) is the parent of the COMMON git dir. Derived at
    // runtime — never a literal path in this file.
    const common = execFileSync("git", ["rev-parse", "--git-common-dir"], {
      cwd: REPO_ROOT,
      encoding: "utf8",
    }).trim();
    roots.push(path.dirname(path.resolve(REPO_ROOT, common)));
  } catch {
    /* not a git checkout — the repo-root candidates still apply */
  }

  const rel = ["js/node_modules/node_modules/playwright", "js/node_modules/playwright", "node_modules/playwright"];
  const out = [];
  if (process.env.PLAYWRIGHT_DIR) out.push(process.env.PLAYWRIGHT_DIR);
  for (const r of roots) for (const s of rel) out.push(path.join(r, s));
  return out;
}

async function loadPlaywright() {
  const tried = [];
  for (const dir of playwrightCandidates()) {
    const entry = path.join(dir, "index.mjs");
    tried.push(entry);
    if (fs.existsSync(entry)) return await import(pathToFileURL(entry).href);
  }
  fail(
    `Playwright not found. Set PLAYWRIGHT_DIR to a playwright package dir, or run \`npm install\` in js/.\nTried:\n  ${tried.join("\n  ")}`,
  );
}

function serve(rootDir) {
  const server = http.createServer((req, res) => {
    const rel = decodeURIComponent(req.url.split("?")[0]);
    const file = path.join(rootDir, rel === "/" ? "/index.html" : rel);
    if (!file.startsWith(rootDir) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) {
      res.writeHead(404);
      return res.end("not found");
    }
    res.writeHead(200, { "content-type": MIME[path.extname(file)] ?? "application/octet-stream" });
    fs.createReadStream(file).pipe(res);
  });
  return new Promise((resolve) =>
    // Port 0 = the OS hands us a free port. Nothing can be squatting it.
    server.listen(0, "127.0.0.1", () => resolve({ server, port: server.address().port })),
  );
}

function buildRoot(renderedHtml) {
  const root = fs.mkdtempSync(path.join(process.env.TMPDIR ?? "/tmp", "bp-rig-"));
  fs.mkdirSync(path.join(root, "fonts"), { recursive: true });
  fs.mkdirSync(path.join(root, "assets"), { recursive: true });
  fs.copyFileSync(renderedHtml, path.join(root, "index.html"));

  const staticDir = path.join(REPO_ROOT, "api/priv/static");
  for (const sub of ["fonts", "assets"]) {
    const src = path.join(staticDir, sub);
    if (!fs.existsSync(src)) continue;
    for (const name of fs.readdirSync(src)) {
      const from = path.join(src, name);
      if (fs.statSync(from).isFile()) fs.copyFileSync(from, path.join(root, sub, name));
    }
  }
  return root;
}

async function main() {
  const [renderedHtml, outDir, label = "rig"] = process.argv.slice(2);
  if (!renderedHtml || !outDir) fail("usage: shoot.mjs <rendered.html> <out-dir> [label]");
  if (!fs.existsSync(renderedHtml)) fail(`no rendered html at ${renderedHtml}`);

  const { chromium } = await loadPlaywright();
  const root = buildRoot(renderedHtml);
  const { server, port } = await serve(root);
  fs.mkdirSync(outDir, { recursive: true });

  const browser = await chromium.launch();
  const shots = [];
  let assertions = 0;

  try {
    for (const scheme of SCHEMES) {
      for (const width of VIEWPORTS) {
        const context = await browser.newContext({
          viewport: { width, height: 1200 },
          deviceScaleFactor: DEVICE_SCALE_FACTOR,
          colorScheme: scheme,
        });
        let blocked = 0;
        await context.route("**/*", (route) => {
          const host = new URL(route.request().url()).hostname;
          if (host === ALLOWED_HOST) return route.continue();
          blocked += 1;
          return route.abort();
        });
        const page = await context.newPage();
        await page.goto(`http://127.0.0.1:${port}/index.html`, { waitUntil: "load" });
        // Explicit toggle as well as the OS-level colorScheme: the reader
        // honours an explicit `data-theme` over prefers-color-scheme.
        await page.evaluate((s) => document.documentElement.setAttribute("data-theme", s), scheme);
        await page.evaluate(() => document.fonts.ready);

        // CONTENT assertions — never the HTTP status.
        const seen = await page.evaluate(({ sel, probeText, toneSelectors }) => {
          const main = document.querySelector("main.bp-paper-article");
          const round = (n) => Math.round(n * 10) / 10;
          if (!main) return { wrapper: false, classes: null, paragraphs: 0, columnWidth: 0, maxWidth: null };

          // The column's CONTENT box — what a block inside the article is
          // measured against, and the axis the evidence band centres on.
          const cs = getComputedStyle(main);
          const box = main.getBoundingClientRect();
          const padL = parseFloat(cs.paddingLeft) || 0;
          const padR = parseFloat(cs.paddingRight) || 0;
          const contentLeft = box.left + padL;
          const contentWidth = box.width - padL - padR;
          const contentCentre = contentLeft + contentWidth / 2;

          // ── prose measure, in CHARACTERS PER LINE ──────────────────────────
          // A paragraph's own text is re-measured in its own resolved font on a
          // hidden single-line span; dividing the paragraph's rendered width by
          // the resulting per-character advance gives the characters that fit on
          // one line. Doing it with the REAL text (rather than a canonical "n"
          // or a 0.5em rule of thumb) means the figure tracks this reader's font,
          // size, tracking and oldstyle-numeral feature settings, not a proxy.
          const cplSamples = [];
          for (const p of main.querySelectorAll("p")) {
            const text = p.textContent.trim();
            if (text.length < 120) continue;
            const pcs = getComputedStyle(p);
            const probe = document.createElement("span");
            probe.style.cssText = "position:absolute;left:-99999px;top:0;visibility:hidden;white-space:pre";
            probe.style.fontFamily = pcs.fontFamily;
            probe.style.fontSize = pcs.fontSize;
            probe.style.fontWeight = pcs.fontWeight;
            probe.style.fontStyle = pcs.fontStyle;
            probe.style.letterSpacing = pcs.letterSpacing;
            probe.style.fontFeatureSettings = pcs.fontFeatureSettings;
            probe.textContent = text;
            document.body.appendChild(probe);
            const perChar = probe.getBoundingClientRect().width / text.length;
            probe.remove();
            const w = p.getBoundingClientRect().width - (parseFloat(pcs.paddingLeft) || 0) - (parseFloat(pcs.paddingRight) || 0);
            if (perChar > 0 && w > 0) cplSamples.push(w / perChar);
          }
          cplSamples.sort((a, b) => a - b);
          const cpl = cplSamples.length ? cplSamples[Math.floor(cplSamples.length / 2)] : null;

          // The same measurement on figcaptions INSIDE a broken-out figure. A
          // caption is prose and must not stretch to a 1240px figure, and
          // "does not stretch" is not the same claim as "reads at a measure":
          // the artifact's literal `72ch` clamps at 653px and still holds ~97
          // characters, because `ch` is the advance of the digit zero and not
          // the mean. So the WORST caption on the page is reported, in the same
          // characters-per-line unit the prose is judged in.
          let captionCpl = null;
          let captionWidth = null;
          for (const fc of main.querySelectorAll("figcaption")) {
            const text = fc.textContent.trim();
            if (text.length < 60) continue;
            const ccs = getComputedStyle(fc);
            const probe = document.createElement("span");
            probe.style.cssText = "position:absolute;left:-99999px;top:0;visibility:hidden;white-space:pre";
            probe.style.fontFamily = ccs.fontFamily;
            probe.style.fontSize = ccs.fontSize;
            probe.style.fontWeight = ccs.fontWeight;
            probe.style.fontStyle = ccs.fontStyle;
            probe.style.letterSpacing = ccs.letterSpacing;
            probe.textContent = text;
            document.body.appendChild(probe);
            const perChar = probe.getBoundingClientRect().width / text.length;
            probe.remove();
            const w = fc.getBoundingClientRect().width;
            if (perChar <= 0 || w <= 0) continue;
            const v = w / perChar;
            if (captionCpl === null || v > captionCpl) {
              captionCpl = v;
              captionWidth = w;
            }
          }

          // ── the evidence band, per component ───────────────────────────────
          const bandRows = [];
          for (const el of main.querySelectorAll(sel)) {
            const r = el.getBoundingClientRect();
            if (r.width <= 0 || r.height <= 0) continue;
            const kind = el.tagName === "FIGURE" ? "figure" : (el.className.match(/bp-[a-z]+/) || ["?"])[0];
            // THE INKED EXTENT — where the component's visible content actually
            // sits, as opposed to where its BOX sits. These come apart when the
            // content is narrower than the band it was given: the box is the full
            // 1040px and perfectly centred, while the ink hugs one edge. The
            // box-centre assertion below cannot see that (it passes at
            // offCentre 0) — measured on the `design-probe` fixture, whose narrow
            // table has a 1040px centred box and 290.6px of ink pinned 374.7px
            // left of the column axis. Reported, not asserted: the band's fill
            // behaviour for narrow content is a separate finding with its own
            // task, and asserting it here would red a committed fixture for a
            // defect this change does not fix.
            const leaves = [...el.querySelectorAll("th, td, .bp-stat, li, p, img, svg, pre")]
              .map((c) => c.getBoundingClientRect())
              .filter((c) => c.width > 0 && c.height > 0);
            const inkLeft = leaves.length ? Math.min(...leaves.map((c) => c.left)) : r.left;
            const inkRight = leaves.length ? Math.max(...leaves.map((c) => c.right)) : r.right;
            bandRows.push({
              kind,
              width: round(r.width),
              // How far the component's centre sits from the column's centre. A
              // width-without-pull half-breakout shows up here and NOWHERE else.
              offCentre: round(r.left + r.width / 2 - contentCentre),
              left: round(r.left),
              right: round(r.right),
              inkWidth: round(inkRight - inkLeft),
              inkOffCentre: round((inkLeft + inkRight) / 2 - contentCentre),
            });
          }

          // ── the SECTION BEAT, per boundary ─────────────────────────────────
          // A level-2 heading opens a section. What separates one section from
          // the next is AIR — measured here as the distance from the previous
          // top-level block's border box to the heading's, which is the gap a
          // reader actually sees. Reported per boundary rather than summarised,
          // so a single collapsed boundary cannot hide inside an average.
          //
          // TWO DOMs, one measurement. The reader LiveView wraps every top-level
          // block in a keyed `<div id=… data-block-id=…>` (bulldocs_live.ex,
          // `phx-update="stream"`); this rig concatenates the same block HTML
          // bare. Both are unwrapped to the same element below, so the number
          // means the same thing on either — and a lever that only works in one
          // of the two shapes (a sibling selector, say) cannot pass here.
          const bodyEl = main.querySelector("#paper-body") || main;
          const topLevel = [...bodyEl.children];
          const unwrap = (el) => {
            if (el.tagName === "H2") return el;
            const only = el.children.length === 1 ? el.firstElementChild : null;
            return only && only.tagName === "H2" ? only : null;
          };
          // A paper opens a section in ONE of two shapes, and the rig has to be
          // able to see both or it will report a clean page for a broken one:
          //
          //   "heading"   — a top-level level-2 heading. The device sizes this one:
          //                 air + rule + gap on the h2 itself.
          //   "container" — a `section` BLOCK, which composes to a flex stack whose
          //                 FIRST child is a leading `<hr class="bp-hr">`
          //                 (compose_section_stack/2). Its head is that rule, and
          //                 the eyebrow + h2 that follow sit INSIDE the container,
          //                 so no `> #paper-body > … > h2` leg reaches them.
          //
          // BOTH shapes are now ASSERTED against the same target. The container
          // shape used to be measured-and-reported only, because it was unsized:
          // its head was a leading `<hr class="bp-hr">` carrying an INLINE
          // `border-top-width:1px` (walk.ex hr/2) that no stylesheet could
          // outrank, so it opened at 16px over a 1px rule against the heading
          // shape's 92px over 2px. The emitters now drop that hr — and the
          // trailing one — and the boundary is the container's OWN `border-top`
          // (`.bp-paper-surface .bp-section`), which is the SAME device the
          // heading shape gets. One law, two shapes, one assertion.
          //
          // The detector deliberately still knows the OLD shape. If it only
          // matched `.bp-section`, reverting the emitter would produce ZERO
          // container beats and the assertion below would pass vacuously — the
          // measurement would disappear instead of reddening. Detecting the
          // hr-led stack as the same `container` kind means a revert reports
          // 16px over a 1px rule and reds on the numbers.
          const sectionHead = (el) => {
            const h = unwrap(el);
            if (h) return { kind: "heading", el: h, label: h.textContent.trim().slice(0, 44) };
            // The section container: a class-less stream div wrapping the flex
            // stack (the LiveView keyed-stream item).
            const stack = el.tagName === "DIV" && el.children.length === 1 ? el.firstElementChild : null;
            if (!stack) return null;
            const h2 = stack.querySelector("h2");
            const label = (h2 ? h2.textContent : stack.textContent).trim().slice(0, 44);
            // Post-device: the container box IS the head (its border-top is the rule).
            if (stack.classList && stack.classList.contains("bp-section")) {
              return { kind: "container", el: stack, label };
            }
            // Pre-device: the head was the leading rule inside the stack.
            const lead = stack.firstElementChild;
            if (lead && lead.tagName === "HR") return { kind: "container", el: lead, label };
            return null;
          };

          const sectionBeats = [];
          for (let i = 1; i < topLevel.length; i++) {
            const found = sectionHead(topLevel[i]);
            if (!found) continue;
            const head = found.el;
            // Measure against the last block that actually PAINTS. The Mechanical
            // Spacing Doctrine authors vertical rhythm as empty paragraph blocks,
            // and the engines emit nothing for them — so the reader's stream
            // carries a real but ZERO-HEIGHT `<div id data-block-id></div>` for
            // each. A zero-height box has no margins of its own, so it comes to
            // rest somewhere INSIDE the collapsed margin run above the heading:
            // measuring to it reports a fraction of an air gap the reader sees in
            // full. (hobby-hardening-capstone stacks two of them before its first
            // h2 and reported 69.6px of a 92px boundary.) The last painted block
            // is the thing the eye actually measures from.
            let prev = null;
            for (let j = i - 1; j >= 0; j--) {
              const r = topLevel[j].getBoundingClientRect();
              if (r.height > 0) { prev = topLevel[j]; break; }
            }
            if (!prev) continue;
            const hcs = getComputedStyle(head);
            sectionBeats.push({
              kind: found.kind,
              head: found.label,
              // Border box to border box: the heading's own top border (the
              // section rule) is INSIDE its rect, so this is the air above the
              // rule, not the air above the words.
              gap: round(head.getBoundingClientRect().top - prev.getBoundingClientRect().bottom),
              rule: round(parseFloat(hcs.borderTopWidth) || 0),
              ruleGap: round(parseFloat(hcs.paddingTop) || 0),
              // How many zero-height spacing blocks sat between the two, so the
              // skip is visible in the report rather than inferred from a number.
              skippedEmpty: i - 1 - [...topLevel].indexOf(prev),
            });
          }
          // Headings nested inside a container block (a `section`'s own stack)
          // are NOT top-level. Their air is owned by the container's OWN top
          // border, which is measured above as a "container" beat. Counted so
          // the omission is visible rather than inferred.
          const nestedH2s = main.querySelectorAll("h2").length - topLevel.filter((el) => unwrap(el)).length;

          // THE DOUBLED BOUNDARY. `compose_section_stack/2` USED to wrap every
          // section in a leading AND a trailing rule, so two adjacent `section`
          // blocks put two hairlines a few px apart where the grammar wants one.
          // It was a THREE-engine contract (compose.ex, internal/pdrender/
          // blocks.go and js blocks/core.ts all emitted `PdHr, …, PdHr`), which
          // is why it could never be fixed in CSS — a stylesheet that hid one of
          // the two would leave the TUI and the SDK still drawing both. All
          // three emitters dropped the trailing rule; this list must now come
          // back EMPTY, and the assertion below is what keeps it empty.
          const doubledRules = [];
          for (let i = 1; i < topLevel.length; i++) {
            const prevStack = topLevel[i - 1].children.length === 1 ? topLevel[i - 1].firstElementChild : null;
            const tail = prevStack && prevStack.lastElementChild;
            const found = sectionHead(topLevel[i]);
            if (!tail || tail.tagName !== "HR" || !found || found.kind !== "container") continue;
            doubledRules.push({
              between: found.label,
              apart: round(found.el.getBoundingClientRect().top - tail.getBoundingClientRect().bottom),
            });
          }

          // ── the INGRESS RATIO, canonical text (see INGRESS_RATIO above) ────
          // The same probe string, measured per character under BOTH computed
          // styles; each side's CPL is its content width over that advance.
          const perCharUnder = (style, text) => {
            const probe = document.createElement("span");
            probe.style.cssText = "position:absolute;left:-99999px;top:0;visibility:hidden;white-space:pre";
            probe.style.fontFamily = style.fontFamily;
            probe.style.fontSize = style.fontSize;
            probe.style.fontWeight = style.fontWeight;
            probe.style.fontStyle = style.fontStyle;
            probe.style.letterSpacing = style.letterSpacing;
            probe.style.fontFeatureSettings = style.fontFeatureSettings;
            probe.textContent = text;
            document.body.appendChild(probe);
            const w = probe.getBoundingClientRect().width;
            probe.remove();
            return w / text.length;
          };
          const contentWidthOf = (el) => {
            const c = getComputedStyle(el);
            return el.getBoundingClientRect().width - (parseFloat(c.paddingLeft) || 0) - (parseFloat(c.paddingRight) || 0);
          };
          const ingressEl = main.querySelector(".bp-role-ingress");
          // The body side of the ratio: a PLAIN prose paragraph — no role
          // class, not inside a callout/card/figure/stat/quote — long enough
          // to be prose rather than a caption.
          const ingressBodyP = [...main.querySelectorAll("p")].find(
            (p) =>
              p !== ingressEl &&
              !/bp-role-/.test(p.className) &&
              !p.closest(".bp-callout, .bp-card, .bp-stats, figure, blockquote, .bp-role-ingress") &&
              p.textContent.trim().length >= 120,
          );
          let ingressRatio = null;
          let ingressNote = null;
          if (!ingressEl) {
            ingressNote = "no .bp-role-ingress in this fixture";
          } else if (!ingressBodyP) {
            ingressNote = "no plain body paragraph (>=120 chars) to compare against";
          } else {
            const ingCpl = contentWidthOf(ingressEl) / perCharUnder(getComputedStyle(ingressEl), probeText);
            const bodyCpl = contentWidthOf(ingressBodyP) / perCharUnder(getComputedStyle(ingressBodyP), probeText);
            if (ingCpl > 0 && bodyCpl > 0) ingressRatio = Math.round((ingCpl / bodyCpl) * 1000) / 1000;
            else ingressNote = "probe measured a non-positive advance";
          }

          // ── the tone census (marginal-color-as-verdict, D5/D21) ────────────
          // Computed per cell, so each theme's resolved token values are
          // recorded — the verdict colour IS the left-margin accent.
          const toneSamples = {};
          for (const tsel of toneSelectors) {
            const el = main.querySelector(tsel);
            if (!el) {
              toneSamples[tsel] = { absent: "not in this fixture" };
              continue;
            }
            const tcs = getComputedStyle(el);
            toneSamples[tsel] = { color: tcs.color, background: tcs.backgroundColor, accent: tcs.borderLeftColor };
          }

          // ── the prose h2, rendered px (device-3 will move this) ────────────
          const h2El = main.querySelector("h2");
          const h2Px = h2El
            ? (() => {
                const h = getComputedStyle(h2El);
                return { fontSize: h.fontSize, fontWeight: h.fontWeight };
              })()
            : { absent: "no h2 in this fixture" };

          // ── the stat-strip grid, in TRACKS (device 3's density signal) ─────
          // The computed grid-template-columns is the RESOLVED track list, so
          // its length is the column count the reader actually gets at this
          // width. Zero means .bp-stats stopped resolving as a grid — asserted
          // below, not here.
          const statStrips = [...main.querySelectorAll(".bp-stats")];
          let statTracks = null;
          let statTracksNote = null;
          if (!statStrips.length) {
            statTracksNote = "no .bp-stats in this fixture";
          } else {
            statTracks = statStrips.map((el) => {
              const v = getComputedStyle(el).gridTemplateColumns;
              return v && v !== "none" ? v.split(" ").filter(Boolean).length : 0;
            });
          }

          // ── the partial last row (task-0098ba55d2642545, charter D36) ──────
          // A strip whose cell count is not a multiple of its track count leaves
          // EMPTY tracks in its last row, and whatever the container paints shows
          // there. The hairline grid used to be a rule-tinted container ground
          // seen through 1px gaps, so the remainder rendered as a solid slab — a
          // geometry no published fixture happened to hit. Measured per strip:
          // the empty-track count, and when there are any, what an element probe
          // at the CENTRE of the first empty track hits and that element's
          // background. A slab is the strip's own container hit with a tinted
          // background; the remedy leaves it transparent. Asserted below.
          // ONLY a strip with TWO OR MORE rows can have one: `auto-fit`
          // collapses a track that is empty in EVERY row, so a single row of 4
          // cells over 8 tracks stretches the 4 to full width and there is no
          // remainder to probe (design-probe, measured 2026-09-02 — the probe
          // point landed outside the strip). With a full row above, the empty
          // tracks of the last row are occupied above and stay open.
          // `elementFromPoint` needs viewport coordinates, so the strip is
          // scrolled into view for the probe and the page is scrolled back — a
          // full-page capture is unaffected by scroll position.
          const statRemainder = statStrips.map((el, i) => {
            const cells = [...el.children].filter((c) => c.classList.contains("bp-stat"));
            const tracks = statTracks[i];
            const remainder = tracks > 0 && cells.length > tracks ? (tracks - (cells.length % tracks)) % tracks : 0;
            const out = { tracks, cells: cells.length, emptyTracks: remainder, probe: null };
            if (remainder === 0) return out;
            el.scrollIntoView({ block: "center" });
            const last = cells[cells.length - 1].getBoundingClientRect();
            // The gap is 1px; the first empty track starts one gap after the last cell.
            const x = last.right + 1 + last.width / 2;
            const y = last.top + last.height / 2;
            const hit = document.elementFromPoint(x, y);
            const describe = (n) =>
              n ? n.tagName.toLowerCase() + (n.classList.length ? "." + [...n.classList].join(".") : "") : null;
            out.probe = {
              hit: describe(hit),
              hitIsStrip: hit === el,
              hitBackground: hit ? getComputedStyle(hit).backgroundColor : null,
            };
            window.scrollTo(0, 0);
            return out;
          });

          return {
            wrapper: true,
            classes: main.className,
            // mermaid + asciicast are deliberately excluded (CDN blocked).
            paragraphs: main.querySelectorAll("p").length,
            sectionBeats,
            nestedH2s,
            doubledRules,
            columnWidth: Math.round(box.width),
            columnContentWidth: round(contentWidth),
            // `none` means the .bp-paper-shell rule never applied — the
            // false-green shape where the page is measured at BODY width.
            maxWidth: cs.maxWidth,
            proseCpl: cpl === null ? null : round(cpl),
            proseCplSamples: cplSamples.length,
            captionCpl: captionCpl === null ? null : round(captionCpl),
            captionWidth: captionWidth === null ? null : round(captionWidth),
            evidenceBand: bandRows.length ? Math.max(...bandRows.map((b) => b.width)) : null,
            bandRows,
            ingressPresent: !!ingressEl,
            ingressRatio,
            ingressNote,
            toneSamples,
            h2Px,
            statTracks,
            statTracksNote,
            statRemainder,
            docOverflow: round(document.documentElement.scrollWidth - document.documentElement.clientWidth),
            clientWidth: document.documentElement.clientWidth,
          };
        }, { sel: BREAKOUT_SELECTOR, probeText: INGRESS_PROBE_TEXT, toneSelectors: TONE_SELECTORS });
        const cell = `${label}__${scheme}__${width}`;
        if (!seen.wrapper) fail(`${cell}: no <main class="…bp-paper-article"> in the DOM`);
        if (!seen.classes.includes("bp-paper-surface")) fail(`${cell}: wrapper lost bp-paper-surface (${seen.classes})`);
        if (seen.paragraphs < 1) fail(`${cell}: zero paragraphs inside the paper — vacuous page`);
        // Width-independent liveness check for the shell rules: a dead rule
        // set leaves max-width `none` and the paper measures at BODY width.
        // (At 360px the shell legitimately fills the viewport, so comparing
        // against the viewport alone would be a false red.)
        if (!seen.maxWidth || seen.maxWidth === "none") {
          fail(`${cell}: main max-width is ${seen.maxWidth} — .bp-paper-shell/.bp-paper-article rules are dead`);
        }
        if (seen.columnWidth > MAX_COLUMN_PX) {
          fail(`${cell}: measured column ${seen.columnWidth}px exceeds the ${MAX_COLUMN_PX}px shell — rules not applied`);
        }
        assertions += 4;

        // ── the evidence-breakout contract, per cell ───────────────────────
        // 1. the page never scrolls sideways.
        if (seen.docOverflow > MAX_DOC_OVERFLOW_PX) {
          fail(
            `${cell}: the document scrolls sideways by ${seen.docOverflow}px ` +
              `(scrollWidth ${seen.clientWidth + seen.docOverflow} vs clientWidth ${seen.clientWidth}); ` +
              `allowance is ${MAX_DOC_OVERFLOW_PX}px for the pre-existing unbreakable-token overflow at 360`,
          );
        }
        // 2. every breakout component stays on the column's axis and inside the
        //    viewport. Both halves matter: off-axis is the width-without-pull
        //    half-breakout, and out-of-viewport is a band that escaped its
        //    gutters — the two ways this device fails that a width number hides.
        for (const b of seen.bandRows) {
          if (Math.abs(b.offCentre) > MAX_BAND_OFFCENTRE_PX) {
            fail(
              `${cell}: ${b.kind} sits ${b.offCentre}px off the column's centre axis ` +
                `(width ${b.width}px) — a component takes the band's width and its centring pull together`,
            );
          }
          if (b.left < -MAX_DOC_OVERFLOW_PX || b.right > seen.clientWidth + MAX_DOC_OVERFLOW_PX) {
            fail(
              `${cell}: ${b.kind} spans ${b.left}…${b.right}px outside the ${seen.clientWidth}px viewport — ` +
                `the evidence band crossed its gutters`,
            );
          }
          // 2b. AND ITS INK IS ON THE AXIS TOO. The box being centred is not the
          //     same claim as the reader seeing something centred: a table given
          //     the whole 1040px band but holding 291px of data had a perfectly
          //     centred box and cells pinned to the band's left edge, 374.7px off
          //     the column axis, and the box assertion above passed it at 0.
          //     Reported since #11651, asserted here.
          //
          //     A component whose ink is WIDER than its box is self-scrolling —
          //     the box is the frame, the ink runs past it, and where that ink
          //     sits is a scroll position rather than a layout fact. The box
          //     assertion already covers the frame, so those are exempt, and the
          //     exemption is a width comparison rather than a class list so a new
          //     component cannot quietly inherit it.
          if (b.inkWidth <= b.width + 1 && Math.abs(b.inkOffCentre) > MAX_BAND_OFFCENTRE_PX) {
            fail(
              `${cell}: ${b.kind} has a ${b.width}px box centred at ${b.offCentre}px but only ` +
                `${b.inkWidth}px of INK, sitting ${b.inkOffCentre}px off the column's centre axis — ` +
                `a block that does not fill the band must not claim it; the reader sees a small ` +
                `component hanging off one edge of a wide empty box`,
            );
          }
          // 2c. A component that WANTS more than the column must get at least the
          //     column. This was "no breakout component is ever narrower than the
          //     column", which was true while every component took the band's
          //     width unconditionally — and became wrong the moment a
          //     content-narrow table stopped claiming a band it does not fill (a
          //     291px table SHOULD measure 291px). What still cannot happen is a
          //     component whose ink needs more room than the column while its box
          //     is smaller than the column: that is the band clause having died,
          //     which is the regression this leg was built to catch.
          if (b.inkWidth > seen.columnContentWidth + 1 && b.width < seen.columnContentWidth - 1) {
            fail(
              `${cell}: ${b.kind} holds ${b.inkWidth}px of ink but measures only ${b.width}px, ` +
                `NARROWER than the ${seen.columnContentWidth}px column it should at minimum fill — ` +
                `the evidence band's width clause is not reaching this component`,
            );
          }
        }
        // 3. prose keeps its measure while the evidence widens.
        // The column is VIEWPORT-BOUND when it fills the screen rather than
        // reaching its own max-width; there the phone sets the measure, so only
        // the ceiling is meaningful.
        const columnBound = seen.columnWidth >= width;
        if (seen.proseCpl === null) {
          fail(`${cell}: no paragraph long enough to measure characters-per-line — the prose measure went unproven`);
        } else if (seen.proseCpl > CPL_CEILING || (!columnBound && seen.proseCpl < CPL_FLOOR)) {
          fail(
            `${cell}: prose measures ${seen.proseCpl} characters per line, outside the ` +
              `${columnBound ? `≤${CPL_CEILING}` : `${CPL_FLOOR}-${CPL_CEILING}`} editorial band ` +
              `(${seen.proseCplSamples} paragraphs sampled, column ${seen.columnWidth}px in a ${width}px viewport) — ` +
              `widening the evidence must never widen the sentences`,
          );
        }
        // 4. a caption inside a wide figure is prose too. Only the ceiling
        //    applies: a caption is allowed to be short, never to run long.
        if (seen.captionCpl !== null && seen.captionCpl > CPL_CEILING) {
          fail(
            `${cell}: the longest figcaption measures ${seen.captionCpl} characters per line ` +
              `(${seen.captionWidth}px) — a caption inside a broken-out figure must return to the ` +
              `reading measure, not follow the figure's width`,
          );
        }
        assertions += 2 + seen.bandRows.length + (seen.captionCpl === null ? 0 : 1);

        // ── the section-boundary contract, per boundary ────────────────────
        // Every boundary is checked, not a sample: one collapsed section is the
        // whole defect, and an average over ten good ones would hide it.
        // BOTH shapes are asserted against the target now. The container shape
        // used to be exempt because it was unsized (16px over a 1px rule); it
        // takes the same device as the heading shape, so it takes the same
        // assertion — that exemption WAS the finding.
        const sized = seen.sectionBeats.filter((b) => b.kind === "heading");
        const containers = seen.sectionBeats.filter((b) => b.kind === "container");
        for (const b of seen.sectionBeats) {
          if (Math.abs(b.gap - SECTION_BEAT_PX) > SECTION_BEAT_TOL_PX) {
            fail(
              `${cell}: the section opening "${b.head}" measures ${b.gap}px of air, not the ` +
                `${SECTION_BEAT_PX}±${SECTION_BEAT_TOL_PX}px the artifact opens a section with — ` +
                `a boundary a reader cannot see is not a boundary`,
            );
          }
          if (b.rule < SECTION_RULE_MIN_PX) {
            fail(
              `${cell}: the section opening "${b.head}" carries a ${b.rule}px rule — air alone reads ` +
                `as a long pause, and the rule is the half that says a NEW section began`,
            );
          }
        }
        // A paper with NO boundary of either shape means the selector stopped
        // matching the rendered document, which is the vacuous green this whole
        // measurement exists to refuse. A paper with only CONTAINER boundaries is
        // legitimate (the probe fixture is exactly that) and must not red.
        if (seen.sectionBeats.length === 0) {
          fail(
            `${cell}: no section boundary of EITHER shape under #paper-body — no top-level level-2 ` +
              `heading and no \`section\` container. Either this fixture has no sections (it should not ` +
              `be in the panel) or the rendered document shape moved out from under both, which is the ` +
              `failure this assertion exists to catch`,
          );
        }
        // ONE RULE PER BOUNDARY. `compose_section_stack/2` used to wrap every
        // section in a leading AND a trailing rule, so two adjacent sections put
        // two hairlines a few px apart where the grammar wants one. Both are
        // gone in all three engines (compose.ex, internal/pdrender/blocks.go, js
        // blocks/core.ts); this is the assertion that keeps them gone.
        if (seen.doubledRules.length) {
          fail(
            `${cell}: ${seen.doubledRules.length} DOUBLED section boundary/-ies — a section still ` +
              `closes with a rule of its own, so the next section's opening rule lands ` +
              `${seen.doubledRules.map((d) => `${d.apart}px`).join(", ")} below it. One boundary is one ` +
              `line; two lines read as a mistake, not as structure. Offenders: ` +
              seen.doubledRules.map((d) => `"${d.between}"`).join(", "),
          );
        }
        assertions += 2 * seen.sectionBeats.length + 2;

        // ── the heavy-rule census, per cell ────────────────────────────────
        // Same function the artifact is measured with (census.mjs), evaluated in
        // this page. Every rule that PAINTS, attributed to the element that drew
        // it; a stray heavy rule names itself here instead of being a count that
        // moved.
        const census = await runCensus(page, "main.bp-paper-article", STRUCTURAL_RULE_SELECTOR);
        if (census.strayHeavy > 0) {
          const worst = census.heavyRules.filter((r) => !r.structural).slice(0, 6);
          fail(
            `${cell}: ${census.strayHeavy} of ${census.heavy} heavy (>=${HEAVY_PX}px) horizontal rules are NOT ` +
              `section boundaries — a component is drawing the line that means "a new argument starts here". ` +
              `Heavy weight is reserved for structure; chrome draws at --bp-rule-hairline ` +
              `(design/tokens.json space.rule). Offenders:\n` +
              worst.map((r) => `      ${r.px}px at y=${r.y}, ${r.width}px wide — ${r.owners.join(" | ")}`).join("\n"),
          );
        }
        // The mirror failure: a paper whose section heads have stopped drawing at
        // all would report zero strays and be just as broken. Every boundary the
        // beat assertion above measured must also appear in the census as a heavy
        // rule, so the two halves cannot pass each other's absence.
        // BOTH shapes count here. This is also the check that pins the container
        // rule's WEIGHT: a container drawing its old inline 1px hairline is below
        // HEAVY_PX and never enters the heavy census, so the two halves disagree
        // and this reds — a boundary a reader cannot tell from chrome.
        const boundaries = seen.sectionBeats.length;
        if (census.structuralHeavy !== boundaries) {
          fail(
            `${cell}: the census sees ${census.structuralHeavy} heavy section rule(s) but ${boundaries} ` +
              `section boundary/-ies were measured (${sized.length} heading, ${containers.length} container) — ` +
              `a boundary is being counted whose rule does not paint (or paints below ${HEAVY_PX}px)`,
          );
        }
        assertions += 2;

        // ── the ingress-ratio arm, per cell (device 6) ─────────────────────
        // Anti-vacuity FIRST: a fixture that CARRIES an ingress must yield a
        // sample. An arm that silently skips the element it was built for is
        // the vacuous green this rig exists to refuse.
        if (seen.ingressPresent && seen.ingressRatio === null) {
          fail(
            `${cell}: the fixture carries .bp-role-ingress but the canonical ratio probe yielded no ` +
              `sample (${seen.ingressNote}) — the ingress arm went vacuous`,
          );
        }
        if (seen.ingressRatio !== null && Math.abs(seen.ingressRatio - INGRESS_RATIO) > INGRESS_RATIO_TOL) {
          fail(
            `${cell}: canonical ingress/body CPL ratio measures ${seen.ingressRatio}, outside ` +
              `${INGRESS_RATIO}±${INGRESS_RATIO_TOL} — the ingress lost its size relationship to the prose ` +
              `(a rem-sized role reads ~0.880 here; the em contract is #11626)`,
          );
        }
        // A stat strip that is PRESENT must measure as a grid. Zero tracks on
        // every strip means the density measurement is dead, not that the
        // fixture is stats-less — the null-with-reason path covers absence.
        if (seen.statTracks !== null && !seen.statTracks.some((n) => n > 0)) {
          fail(
            `${cell}: .bp-stats is present but no grid tracks were measured ` +
              `(${JSON.stringify(seen.statTracks)}) — the stat-strip measurement is dead`,
          );
        }
        assertions += (seen.ingressPresent ? 2 : 0) + (seen.statTracks === null ? 0 : 1);
        // The partial last row must be page ground, not a slab. Anti-vacuity
        // first: a strip WITH empty tracks must yield a probe — a probe that
        // silently skipped the geometry it was built for is the vacuous green.
        // Then the hit: the strip's own transparent container. A cell or a kilde
        // there means the geometry was mis-measured; a tinted container is the
        // slab (rgba(0, 0, 0, 0) is what Chromium reports for `transparent`).
        // Red-before (2026-09-02): with `background: var(--paper-rule)` restored
        // on `.bp-paper-surface .bp-stats`, stat-partial-row reds here —
        // "the container's background is rgb(221, 231, 226), not transparent"
        // (light, evergreen pin) — and goes green again once it is removed.
        for (const s of seen.statRemainder ?? []) {
          if (s.emptyTracks === 0) continue;
          if (!s.probe) {
            fail(`${cell}: a .bp-stats strip has ${s.emptyTracks} empty track(s) in its last row but the remainder probe yielded nothing — the slab arm went vacuous`);
          }
          if (!s.probe.hitIsStrip) {
            fail(
              `${cell}: the remainder probe (${s.cells} cells over ${s.tracks} tracks, ${s.emptyTracks} empty) hit ` +
                `${s.probe.hit ?? "nothing"}, not the strip's own container — the empty-track geometry was mis-measured`,
            );
          }
          if (s.probe.hitBackground !== "rgba(0, 0, 0, 0)") {
            fail(
              `${cell}: the partial last row of a .bp-stats strip (${s.cells} cells over ${s.tracks} tracks, ` +
                `${s.emptyTracks} empty) paints as a slab — the container's background is ${s.probe.hitBackground}, ` +
                `not transparent. The seams belong to the CELLS (paper-surface.css \`.bp-stats .bp-stat\`), ` +
                `never to a container ground the empty tracks would show`,
            );
          }
          assertions += 3;
        }

        // The capture itself is a place a false green hides: Playwright's JPEG
        // encoder writes a ZERO-BYTE file (no throw, no warning) when a
        // full-page capture exceeds JPEG's 65,535px dimension cap. So: never
        // trust the call, stat the file. An @1x demotion retry used to live
        // here for that case; it NEVER fired — zero `*@1x.*` files in
        // baselines/, and hobby-hardening-capstone, the paper it was written
        // for, captures at 2x in both formats — so the untested branch was
        // removed (pe-w2-bl-device5-ratio-arm) and an under-size capture is a
        // plain hard red below.
        const file = path.join(outDir, `${cell}.${FORMAT}`);
        await page.screenshot({
          path: file,
          fullPage: true,
          ...(FORMAT === "jpeg" ? { type: "jpeg", quality: JPEG_QUALITY } : {}),
        });

        const bytes = fs.statSync(file).size;
        if (bytes < MIN_SHOT_BYTES) fail(`${cell}: wrote ${bytes} B to ${file} — the capture did not produce an image`);
        assertions += 1;

        shots.push({
          cell,
          file: path.basename(file),
          scale: DEVICE_SCALE_FACTOR,
          bytes,
          ...seen,
          rules: {
            total: census.total,
            heavy: census.heavy,
            structuralHeavy: census.structuralHeavy,
            strayHeavy: census.strayHeavy,
            byWeight: census.byWeight,
            heavyRules: census.heavyRules,
          },
          blockedRequests: blocked,
        });
        console.log(
          `rig/shoot: ${cell} — column ${seen.columnWidth}px, band ${seen.evidenceBand ?? "n/a"}px ` +
            `(${seen.bandRows.length} components), ` +
            `${sized.length} heading section beats` +
            (sized.length ? ` at ${sized[0].gap}px over a ${sized[0].rule}px rule` : "") +
            (containers.length
              ? `, ${containers.length} container heads` +
                ` at ${containers[0].gap}px over a ${containers[0].rule}px rule`
              : "") +
            (seen.doubledRules.length ? `, ${seen.doubledRules.length} DOUBLED rules` : "") +
            `, ${census.total} rules (${census.heavy} heavy, all structural)` +
            `, prose ${seen.proseCpl ?? "n/a"} CPL, ` +
            `ingress ratio ${seen.ingressRatio ?? "n/a"}, ` +
            `h2 ${seen.h2Px.fontSize ?? "n/a"}/${seen.h2Px.fontWeight ?? "n/a"}, ` +
            `stat tracks ${seen.statTracks ? seen.statTracks.join("/") : "n/a"}, ` +
            `doc overflow ${seen.docOverflow}px, ${seen.paragraphs} paragraphs, ` +
            `${blocked} off-host requests blocked, ${DEVICE_SCALE_FACTOR}x, ${bytes} B`,
        );
        await context.close();
      }
    }
  } finally {
    await browser.close();
    server.close();
    fs.rmSync(root, { recursive: true, force: true });
  }

  fs.writeFileSync(
    path.join(outDir, `${label}.report.json`),
    JSON.stringify(
      {
        label,
        deviceScaleFactor: DEVICE_SCALE_FACTOR,
        fullPage: true,
        format: FORMAT,
        jpegQuality: FORMAT === "jpeg" ? JPEG_QUALITY : null,
        allowedHost: ALLOWED_HOST,
        blocked: NOTED_BLOCKED_ORIGINS,
        excludedFromAssertions: ["diagram/mermaid", "asciicast", "remote images"],
        shots,
      },
      null,
      2,
    ) + "\n",
  );
  console.log(
    `rig/shoot: OK — ${shots.length} full-page shots at ${DEVICE_SCALE_FACTOR}x, ${assertions} content assertions`,
  );
}

if (process.argv[2] === "--report-diff") {
  const [baselineFile, freshFile] = process.argv.slice(3);
  if (!baselineFile || !freshFile) fail("usage: shoot.mjs --report-diff <baseline.report.json> <fresh.report.json>");
  reportDiff(baselineFile, freshFile);
} else {
  await main();
}
