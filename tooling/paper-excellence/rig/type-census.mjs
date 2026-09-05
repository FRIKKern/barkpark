// type-census — the READING FLOOR probe: every text node on a paper, measured.
//
// census.mjs answers "how many horizontal rules does this page paint, and are
// any of them strays". This answers the other half of the same question, on the
// other axis: is any TEXT on this page too small to read, or too faint against
// the ground it actually sits on.
//
// It is deliberately NOT part of shoot.mjs's baseline report. shoot.mjs pins
// scalars and reds on ANY drift, which is right for geometry (a caption width,
// a rule position) and wrong for this: a floor is a THRESHOLD, and the useful
// output is the list of violations, not a number that must never move. So this
// runs as its own gate and prints what fails.
//
//   node tooling/paper-excellence/rig/type-census.mjs <file.html|url> [--root '#paper-body'] [--min-px 12] [--min-contrast 4.5] [--scheme light|dark|both] [--width 1280] [--json]
//
// exit 0 = clean, 1 = violations, 2 = could not run.
//
// TWO measurements per text node:
//
//   font-size  — `getComputedStyle(parent).fontSize`. For SVG <text> that number
//                is in USER UNITS, not px: the chart svg is authored in a 640-wide
//                viewBox and painted at whatever width the band gives it, so an
//                11px tick paints 17.9px at the 1040px band and 4.3px at 360.
//                Both are reported (`px` and `screenPx`, via getScreenCTM), and
//                the floor is judged on the SMALLER of the two — a label that
//                paints below the floor fails even if its authored size is legal,
//                and one authored below the floor fails even when a scale-up
//                rescues it, because the authored number is what the next
//                container width inherits.
//
//   contrast   — WCAG 2.1 relative-luminance ratio against the COMPOSITED
//                background, not against `background-color` on the parent. Most
//                small text on a paper sits on a transparent element inside a
//                tinted card inside the page ground, so the parent's own
//                background is `rgba(0,0,0,0)` and reading it alone reports the
//                page ground and MISSES every card. So the ground is composited:
//                walk up painting each ancestor's background-color over the last,
//                and fold each ancestor's `opacity` in on the way (an 0.5-opacity
//                row halves its own contrast and no colour on the element says so).
//
// The `<= 4.5:1` threshold is WCAG AA for normal text. Text at >= 18.66px bold or
// >= 24px is "large" and legal at 3:1; the probe applies that carve-out, and says
// which rule it used per violation.
//
// WHY IT LIVES IN THE RIG: it needs a real browser (composited backgrounds and
// SVG screen scale are layout results, not stylesheet facts), it needs the same
// fixture render every other rig probe uses, and the PROBE ITSELF is pasteable —
// `CENSUS_FN` below is one self-contained function with no imports, so the same
// code that runs here runs in a DevTools console on the live reader. That
// matters: the measurement in a task row and the measurement in CI must be the
// same measurement.

import { existsSync, readFileSync, mkdtempSync, cpSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, dirname, basename, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { createRequire } from "node:module";
import { execSync } from "node:child_process";

// ── THE PROBE ───────────────────────────────────────────────────────────────
// Self-contained on purpose: paste the body of this function into a DevTools
// console on /papers/<slug> and it runs unchanged. Keep it dependency-free.
const CENSUS_FN = function (rootSel, minPx, minContrast) {
  const root = document.querySelector(rootSel) || document.body;

  const parseColor = (c) => {
    const m = String(c).match(/rgba?\(([^)]+)\)/);
    if (!m) return null;
    const p = m[1].split(/[,/]/).map((s) => parseFloat(s.trim()));
    return { r: p[0], g: p[1], b: p[2], a: p.length > 3 && !Number.isNaN(p[3]) ? p[3] : 1 };
  };
  // src OVER dst (both premultiplied-free straight alpha); dst is assumed opaque.
  const over = (src, dst) => ({
    r: src.r * src.a + dst.r * (1 - src.a),
    g: src.g * src.a + dst.g * (1 - src.a),
    b: src.b * src.a + dst.b * (1 - src.a),
    a: 1,
  });
  const lum = (c) => {
    const f = (v) => {
      v /= 255;
      return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
    };
    return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
  };
  const ratio = (a, b) => {
    const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p);
    return (x + 0.05) / (y + 0.05);
  };

  // The composited ground under `el`: every ancestor background-color painted in
  // document order over the page ground, with each ancestor's opacity folded in.
  const groundOf = (el) => {
    const chain = [];
    for (let n = el; n; n = n.parentElement) chain.push(n);
    const html = document.documentElement;
    let base = parseColor(getComputedStyle(html).backgroundColor) || { r: 255, g: 255, b: 255, a: 0 };
    if (base.a === 0) base = { r: 255, g: 255, b: 255, a: 1 };
    let ground = { ...base, a: 1 };
    for (const n of chain.reverse()) {
      const cs = getComputedStyle(n);
      const bg = parseColor(cs.backgroundColor);
      const op = parseFloat(cs.opacity);
      if (bg && bg.a > 0) ground = over({ ...bg, a: bg.a * (Number.isNaN(op) ? 1 : op) }, ground);
    }
    return ground;
  };
  // Effective opacity multiplied down the ancestor chain — the text's own alpha.
  const chainOpacity = (el) => {
    let o = 1;
    for (let n = el; n && n !== document.documentElement; n = n.parentElement) {
      const v = parseFloat(getComputedStyle(n).opacity);
      if (!Number.isNaN(v)) o *= v;
    }
    return o;
  };

  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
    acceptNode(n) {
      if (!n.nodeValue || !n.nodeValue.trim()) return NodeFilter.FILTER_REJECT;
      const el = n.parentElement;
      if (!el) return NodeFilter.FILTER_REJECT;
      const cs = getComputedStyle(el);
      if (cs.display === "none" || cs.visibility === "hidden") return NodeFilter.FILTER_REJECT;
      if (parseFloat(cs.opacity) === 0) return NodeFilter.FILTER_REJECT;
      const tag = el.tagName.toLowerCase();
      if (tag === "script" || tag === "style" || tag === "title") return NodeFilter.FILTER_REJECT;
      return NodeFilter.FILTER_ACCEPT;
    },
  });

  const sizeViolations = [];
  const contrastViolations = [];
  const sizes = {};
  let counted = 0;

  const describe = (el) => {
    const cls = (el.getAttribute("class") || "").trim().split(/\s+/).filter(Boolean).slice(0, 3);
    return el.tagName.toLowerCase() + (cls.length ? "." + cls.join(".") : "");
  };

  for (let n = walker.nextNode(); n; n = walker.nextNode()) {
    const el = n.parentElement;
    const cs = getComputedStyle(el);
    const px = parseFloat(cs.fontSize);

    // SVG text is authored in user units; report what it actually paints.
    let screenPx = px;
    if (el.ownerSVGElement && typeof el.getScreenCTM === "function") {
      const m = el.getScreenCTM();
      if (m) screenPx = px * Math.sqrt(Math.abs(m.a * m.d - m.b * m.c));
    }
    const judged = Math.min(px, screenPx);
    counted++;
    const key = judged.toFixed(2);
    sizes[key] = (sizes[key] || 0) + 1;

    const sample = n.nodeValue.trim().slice(0, 48);
    if (judged < minPx) {
      sizeViolations.push({
        selector: describe(el),
        px: +px.toFixed(2),
        screenPx: +screenPx.toFixed(2),
        sample,
      });
    }

    const ground = groundOf(el);
    const fg0 = parseColor(cs.color);
    if (!fg0) continue;
    const fg = over({ ...fg0, a: fg0.a * chainOpacity(el) }, ground);
    const r = ratio(fg, ground);

    // WCAG AA large-text carve-out: >= 24px, or >= 18.66px at weight >= 700.
    const weight = parseInt(cs.fontWeight, 10) || 400;
    const large = judged >= 24 || (judged >= 18.66 && weight >= 700);
    const need = large ? 3 : minContrast;
    if (r < need) {
      contrastViolations.push({
        selector: describe(el),
        px: +judged.toFixed(2),
        weight,
        color: cs.color,
        ground: `rgb(${ground.r.toFixed(0)}, ${ground.g.toFixed(0)}, ${ground.b.toFixed(0)})`,
        ratio: +r.toFixed(2),
        need,
        rule: large ? "AA large" : "AA normal",
        sample,
      });
    }
  }

  const bySize = Object.entries(sizes)
    .map(([px, n]) => ({ px: +px, n }))
    .sort((a, b) => a.px - b.px);

  return {
    root: rootSel,
    textNodes: counted,
    minPx,
    minContrast,
    smallest: bySize.length ? bySize[0].px : null,
    bySize: bySize.slice(0, 12),
    sizeViolations,
    contrastViolations,
  };
};

// ── driver ──────────────────────────────────────────────────────────────────
const args = process.argv.slice(2);
if (!args.length || args[0].startsWith("--")) {
  console.error(
    "usage: node type-census.mjs <file.html|url> [--root SEL] [--min-px N] [--min-contrast N] [--scheme light|dark|both] [--width N] [--json]",
  );
  process.exit(2);
}
const target = args[0];
const flag = (name, dflt) => {
  const i = args.indexOf(`--${name}`);
  return i === -1 ? dflt : args[i + 1];
};
const ROOT = flag("root", "#paper-body");
const MIN_PX = parseFloat(flag("min-px", "12"));
const MIN_CONTRAST = parseFloat(flag("min-contrast", "4.5"));
const WIDTH = parseInt(flag("width", "1280"), 10);
const SCHEME = flag("scheme", "both");
const AS_JSON = args.includes("--json");

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, "../../..");

// Same Playwright resolution shoot.mjs uses — the rig has no node_modules of its
// own, so it borrows the js/ workspace's (and the primary checkout's, when this
// runs from a worktree whose deps were never installed).
function loadPlaywright() {
  const candidates = [];
  if (process.env.PLAYWRIGHT_DIR) candidates.push(process.env.PLAYWRIGHT_DIR);
  let common = null;
  try {
    common = execSync("git rev-parse --git-common-dir", { cwd: repoRoot }).toString().trim();
  } catch {}
  const roots = [repoRoot];
  if (common) roots.push(resolve(repoRoot, common, ".."));
  for (const r of roots) {
    candidates.push(
      join(r, "js/node_modules/node_modules/playwright"),
      join(r, "js/node_modules/playwright"),
      join(r, "node_modules/playwright"),
    );
  }
  for (const c of candidates) {
    if (existsSync(join(c, "package.json"))) {
      return createRequire(join(c, "package.json"))(c);
    }
  }
  throw new Error(
    `playwright not found (looked in: ${candidates.join(", ")}). Set PLAYWRIGHT_DIR.`,
  );
}

const isUrl = /^https?:\/\//.test(target);

async function serve(htmlPath) {
  // Mirror shoot.mjs: copy the page + the api's static assets into one temp root
  // and serve on 127.0.0.1:0, so /fonts and /assets resolve like the real reader.
  const root = mkdtempSync(join(tmpdir(), "bp-type-census-"));
  const name = basename(htmlPath);
  writeFileSync(join(root, name), readFileSync(htmlPath));
  for (const dir of ["fonts", "assets"]) {
    const src = join(repoRoot, "api/priv/static", dir);
    if (existsSync(src)) cpSync(src, join(root, dir), { recursive: true });
  }
  const types = {
    ".html": "text/html", ".css": "text/css", ".js": "text/javascript",
    ".woff2": "font/woff2", ".woff": "font/woff", ".svg": "image/svg+xml",
    ".png": "image/png", ".jpg": "image/jpeg", ".json": "application/json",
  };
  const server = createServer((req, res) => {
    const p = decodeURIComponent(new URL(req.url, "http://127.0.0.1").pathname);
    if (p.includes("..")) { res.writeHead(403).end(); return; }
    const f = join(root, p === "/" ? name : p.slice(1));
    if (!f.startsWith(root) || !existsSync(f)) { res.writeHead(404).end(); return; }
    const ext = f.slice(f.lastIndexOf("."));
    res.writeHead(200, { "content-type": types[ext] || "application/octet-stream" });
    res.end(readFileSync(f));
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  return { server, url: `http://127.0.0.1:${server.address().port}/${name}` };
}

const { chromium } = loadPlaywright();
let served = null;
let url = target;
if (!isUrl) {
  const p = resolve(process.cwd(), target);
  if (!existsSync(p)) { console.error(`no such file: ${p}`); process.exit(2); }
  served = await serve(p);
  url = served.url;
}

const schemes = SCHEME === "both" ? ["light", "dark"] : [SCHEME];
const browser = await chromium.launch();
const reports = {};
let violations = 0;

for (const scheme of schemes) {
  const ctx = await browser.newContext({
    colorScheme: scheme,
    viewport: { width: WIDTH, height: 1400 },
    deviceScaleFactor: 1,
  });
  const page = await ctx.newPage();
  // Block anything off-host: the probe measures OUR paint, never a CDN's.
  await page.route("**/*", (route) => {
    const h = new URL(route.request().url()).hostname;
    return h === "127.0.0.1" || h === "localhost" ? route.continue() : route.abort();
  });
  await page.goto(url, { waitUntil: "networkidle" });
  await page.evaluate((s) => document.documentElement.setAttribute("data-theme", s), scheme);
  await page.waitForTimeout(250);
  const report = await page.evaluate(
    ([fn, root, minPx, minContrast]) =>
      new Function(`return (${fn})`)()(root, minPx, minContrast),
    [CENSUS_FN.toString(), ROOT, MIN_PX, MIN_CONTRAST],
  );
  reports[scheme] = report;
  violations += report.sizeViolations.length + report.contrastViolations.length;
  await ctx.close();
}
await browser.close();
if (served) served.server.close();

if (AS_JSON) {
  console.log(JSON.stringify(reports, null, 2));
} else {
  for (const [scheme, r] of Object.entries(reports)) {
    console.log(`\n── ${scheme} @ ${WIDTH} — ${r.root}: ${r.textNodes} text nodes`);
    console.log(`   smallest ${r.smallest}px (floor ${r.minPx}px), sizes: ` +
      r.bySize.map((b) => `${b.px}×${b.n}`).join("  "));
    const s = r.sizeViolations, c = r.contrastViolations;
    console.log(`   below the ${r.minPx}px floor: ${s.length}`);
    for (const v of s.slice(0, 20))
      console.log(`      ${v.px}px (paints ${v.screenPx}px)  ${v.selector}  "${v.sample}"`);
    console.log(`   below ${r.minContrast}:1 contrast: ${c.length}`);
    for (const v of c.slice(0, 20))
      console.log(`      ${v.ratio}:1 (needs ${v.need}, ${v.rule})  ${v.px}px  ${v.selector}  ${v.color} on ${v.ground}  "${v.sample}"`);
  }
  console.log(violations === 0 ? "\ntype-census: CLEAN" : `\ntype-census: ${violations} violation(s)`);
}
process.exit(violations === 0 ? 0 : 1);
