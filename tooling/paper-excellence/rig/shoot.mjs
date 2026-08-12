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

// The gate shoots all three widths. SHOT_WIDTHS narrows the set for the
// committed baseline panel (see baseline.sh / README §Baselines).
const VIEWPORTS = (process.env.SHOT_WIDTHS ?? "1440,768,360").split(",").map((n) => Number(n.trim()));
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
        const seen = await page.evaluate(() => {
          const main = document.querySelector("main.bp-paper-article");
          return {
            wrapper: !!main,
            classes: main ? main.className : null,
            // mermaid + asciicast are deliberately excluded (CDN blocked).
            paragraphs: main ? main.querySelectorAll("p").length : 0,
            columnWidth: main ? Math.round(main.getBoundingClientRect().width) : 0,
            // `none` means the .bp-paper-shell rule never applied — the
            // false-green shape where the page is measured at BODY width.
            maxWidth: main ? getComputedStyle(main).maxWidth : null,
          };
        });
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
          `rig/shoot: ${cell} — column ${seen.columnWidth}px, ${seen.paragraphs} paragraphs, ` +
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
