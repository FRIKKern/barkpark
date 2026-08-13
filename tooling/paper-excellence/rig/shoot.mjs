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
        // Scale can be demoted below (JPEG height cap) — see the retry.
        let scale = DEVICE_SCALE_FACTOR;
        const context = await browser.newContext({
          viewport: { width, height: 1200 },
          deviceScaleFactor: scale,
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
        const seen = await page.evaluate((sel) => {
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
            bandRows.push({
              kind,
              width: round(r.width),
              // How far the component's centre sits from the column's centre. A
              // width-without-pull half-breakout shows up here and NOWHERE else.
              offCentre: round(r.left + r.width / 2 - contentCentre),
              left: round(r.left),
              right: round(r.right),
            });
          }

          return {
            wrapper: true,
            classes: main.className,
            // mermaid + asciicast are deliberately excluded (CDN blocked).
            paragraphs: main.querySelectorAll("p").length,
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
            docOverflow: round(document.documentElement.scrollWidth - document.documentElement.clientWidth),
            clientWidth: document.documentElement.clientWidth,
          };
        }, BREAKOUT_SELECTOR);
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
          if (b.width < seen.columnContentWidth - 1) {
            fail(`${cell}: ${b.kind} measures ${b.width}px, NARROWER than the ${seen.columnContentWidth}px column it broke out of`);
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

        // The capture itself is a place a false green hides: Playwright's JPEG
        // encoder writes a ZERO-BYTE file (no throw, no warning) when a
        // full-page capture exceeds JPEG's 65,535px dimension cap — which a
        // ~100-block paper at 2x does. Caught on 2026-08-12 with
        // hobby-hardening-capstone. So: never trust the call, stat the file.
        let file = path.join(outDir, `${cell}.${FORMAT}`);
        const shoot = async () =>
          page.screenshot({
            path: file,
            fullPage: true,
            ...(FORMAT === "jpeg" ? { type: "jpeg", quality: JPEG_QUALITY } : {}),
          });
        await shoot();

        if (fs.statSync(file).size < MIN_SHOT_BYTES && FORMAT === "jpeg") {
          // Over the JPEG height cap. Re-capture the SAME full page at 1x —
          // half the pixel height — and say so in the filename, so a shorter
          // baseline can never be mistaken for a 2x one.
          fs.rmSync(file);
          scale = 1;
          file = path.join(outDir, `${cell}@1x.jpeg`);
          const ctx1x = await browser.newContext({
            viewport: { width, height: 1200 },
            deviceScaleFactor: scale,
            colorScheme: scheme,
          });
          await ctx1x.route("**/*", (route) =>
            new URL(route.request().url()).hostname === ALLOWED_HOST ? route.continue() : route.abort(),
          );
          const p1x = await ctx1x.newPage();
          await p1x.goto(`http://127.0.0.1:${port}/index.html`, { waitUntil: "load" });
          await p1x.evaluate((s) => document.documentElement.setAttribute("data-theme", s), scheme);
          await p1x.evaluate(() => document.fonts.ready);
          await p1x.screenshot({ path: file, fullPage: true, type: "jpeg", quality: JPEG_QUALITY });
          await ctx1x.close();
          console.log(`rig/shoot: ${cell} — over JPEG's 65535px cap at 2x, re-captured full page at 1x`);
        }

        const bytes = fs.statSync(file).size;
        if (bytes < MIN_SHOT_BYTES) fail(`${cell}: wrote ${bytes} B to ${file} — the capture did not produce an image`);
        assertions += 1;

        shots.push({ cell, file: path.basename(file), scale, bytes, ...seen, blockedRequests: blocked });
        console.log(
          `rig/shoot: ${cell} — column ${seen.columnWidth}px, band ${seen.evidenceBand ?? "n/a"}px ` +
            `(${seen.bandRows.length} components), prose ${seen.proseCpl ?? "n/a"} CPL, ` +
            `doc overflow ${seen.docOverflow}px, ${seen.paragraphs} paragraphs, ` +
            `${blocked} off-host requests blocked, ${scale}x, ${bytes} B`,
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
  const demoted = shots.filter((s) => s.scale !== DEVICE_SCALE_FACTOR);
  console.log(
    `rig/shoot: OK — ${shots.length} full-page shots ` +
      `(${shots.length - demoted.length} at ${DEVICE_SCALE_FACTOR}x` +
      (demoted.length ? `, ${demoted.length} demoted to 1x by the JPEG height cap` : "") +
      `), ${assertions} content assertions`,
  );
}

await main();
