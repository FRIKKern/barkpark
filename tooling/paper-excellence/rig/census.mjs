// THE HEAVY-RULE CENSUS — one measurement function, run on both sides.
//
//   node tooling/paper-excellence/rig/census.mjs <file-or-url> [--root <sel>] [--structural <sel>] [--json]
//
// A paper's horizontal lines are its loudest typography. The benchmark artifact
// (tooling/paper-excellence/evidence/erasure.html) spends a HEAVY line — 2px —
// on exactly two things: the head of a section, and the frame around its closing
// declaration. Everything else it draws is a hairline. That is a hierarchy: the
// reader learns that a thick line means "a new argument starts here", and every
// other line means "these rows belong together".
//
// A component that draws its own 2px underline spends the section's currency on
// a table header, and the hierarchy stops meaning anything. This file is how
// that claim gets a number instead of an opinion.
//
// WHY IT IS ITS OWN FILE. The census has to run on the ARTIFACT (a standalone
// HTML file with its own stylesheet) and on a RENDERED PAPER (inside the rig's
// hermetic shoot), and a comparison is only worth something if both sides were
// measured by the same instrument. `censusRules` is exported as a plain,
// closure-free function so `page.evaluate` can serialize it into either page;
// the CLI below is the artifact side, `shoot.mjs` is the paper side, and neither
// owns a second copy of the method.

import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { pathToFileURL } from "node:url";

// A rule is HEAVY at 2px. The threshold sits at 1.5 so that sub-pixel layout
// rounding on a 2x capture cannot demote a 2px rule (nor promote a 1px one) —
// there is nothing between the two weights the design uses.
export const HEAVY_PX = 1.5;

/**
 * Count the horizontal rules a reader can see inside `rootSel`.
 *
 * Runs INSIDE the page (page.evaluate / a browser console). Closure-free on
 * purpose: everything it needs arrives as an argument.
 *
 * WHAT COUNTS AS A RULE, and why:
 *
 *   * A HORIZONTAL border edge — `border-top` / `border-bottom` — with a visible
 *     style, a non-zero width and a non-transparent colour. Vertical edges are
 *     NOT rules: a left edge is either half of a frame or a margin accent (the
 *     artifact's own `border-left: 3px` verdict colour), and neither is a line in
 *     the page's vertical rhythm. A four-sided FRAME therefore contributes its
 *     top and its bottom, which is exactly how the artifact's `.declaration`
 *     earns 2 of its 8 heavy rules.
 *   * Measured from the RENDERED page, never from the stylesheet. A rule
 *     declared on a class nothing emits does not exist, and a rule an inline
 *     style overrides is not the rule that ships.
 *
 * WHAT IS MERGED. A table header row is six `th` cells, each with its own
 * `border-bottom`. The reader sees ONE underline. So edges are merged into
 * visual runs: same weight bucket, same y within a pixel, x-ranges touching or
 * overlapping. Counting cells instead of lines would report a 6-column table as
 * six rules and make every number here a function of table width.
 *
 * `structuralSel` names what is ALLOWED to draw heavy — the artifact passes
 * `.sec-head, .declaration`, the reader passes its section-head legs. Every rule
 * comes back stamped `structural: true|false` against a real `element.matches`,
 * not against a class name guessed from the owner label, so a bare element that
 * happens to share a tag with a section head cannot pass as one.
 */
export function censusRules(rootSel, heavyPx, structuralSel) {
  const root = document.querySelector(rootSel) || document.body;
  const round = (n) => Math.round(n * 10) / 10;
  // A colour is invisible when its alpha is 0. `transparent` computes to
  // `rgba(0, 0, 0, 0)`, which is how `.bp-tabs__tab`'s at-rest 2px underline
  // hides — it is declared, it is 2px, and it draws nothing.
  const inked = (c) => {
    const m = /^rgba?\(([^)]+)\)/.exec(c);
    if (!m) return c !== "transparent";
    const parts = m[1].split(",").map((s) => parseFloat(s));
    return parts.length < 4 || parts[3] > 0.01;
  };

  const segments = [];
  const els = [root, ...root.querySelectorAll("*")];
  for (const el of els) {
    const r = el.getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0) continue;
    const cs = getComputedStyle(el);
    if (cs.visibility === "hidden" || cs.display === "none") continue;
    for (const edge of ["Top", "Bottom"]) {
      const w = parseFloat(cs[`border${edge}Width`]) || 0;
      if (w < 0.5) continue;
      const style = cs[`border${edge}Style`];
      if (style === "none" || style === "hidden") continue;
      if (!inked(cs[`border${edge}Color`])) continue;
      segments.push({
        px: round(w),
        // Measured with `matches`, not inferred from the owner label below: the
        // question is whether THIS element is a section head, and a class name
        // in a report string cannot answer it.
        structural: !!structuralSel && el.matches(structuralSel),
        // The line's own position: a top border occupies the first `w` px of the
        // border box, a bottom border the last `w`.
        y: round(edge === "Top" ? r.top : r.bottom - w),
        x0: round(r.left),
        x1: round(r.right),
        style,
        tag: el.tagName.toLowerCase(),
        cls: (el.getAttribute("class") || "").trim(),
        edge: edge.toLowerCase(),
      });
    }
  }

  // Merge into the lines a reader actually sees. Sorted by weight bucket, then
  // y, then x, so a run is a forward scan.
  segments.sort((a, b) => a.px - b.px || a.y - b.y || a.x0 - b.x0);
  const rules = [];
  for (const s of segments) {
    const last = rules[rules.length - 1];
    const contiguous =
      last &&
      last.px === s.px &&
      Math.abs(last.y - s.y) <= 1 &&
      s.x0 <= last.x1 + 2 &&
      s.x1 >= last.x0 - 2;
    if (contiguous) {
      last.x0 = Math.min(last.x0, s.x0);
      last.x1 = Math.max(last.x1, s.x1);
      last.parts += 1;
      // A merged run is structural only if EVERY segment in it is. A chrome
      // line that happens to abut a section head must not inherit its licence.
      last.structural = last.structural && s.structural;
      if (!last.owners.includes(s.cls || s.tag)) last.owners.push(s.cls || s.tag);
      continue;
    }
    rules.push({
      px: s.px,
      y: s.y,
      x0: s.x0,
      x1: s.x1,
      style: s.style,
      edge: s.edge,
      parts: 1,
      structural: s.structural,
      owners: [s.cls || s.tag],
    });
  }

  const heavy = rules.filter((r) => r.px >= heavyPx);
  return {
    rootSel,
    total: rules.length,
    heavy: heavy.length,
    heaviest: rules.length ? Math.max(...rules.map((r) => r.px)) : 0,
    // Every heavy rule, in document order, with what drew it. The gate reads
    // this; a human reading a before/after diff reads it too.
    heavyRules: heavy
      .slice()
      .sort((a, b) => a.y - b.y)
      .map((r) => ({ px: r.px, y: r.y, width: Math.round(r.x1 - r.x0), parts: r.parts, structural: r.structural, owners: r.owners })),
    // The census's verdict, and the shape the gate asserts on: how many heavy
    // rules a section boundary (or a declaration frame) accounts for, and how
    // many are something else drawing at the structural weight.
    structuralHeavy: heavy.filter((r) => r.structural).length,
    strayHeavy: heavy.filter((r) => !r.structural).length,
    // A weight histogram, so "quieter" is a shape and not one number.
    byWeight: rules.reduce((acc, r) => {
      acc[r.px] = (acc[r.px] || 0) + 1;
      return acc;
    }, {}),
  };
}

/**
 * Run `censusRules` inside an already-loaded Playwright page.
 *
 * The function is shipped as SOURCE (`toString()`) rather than referenced,
 * because `page.evaluate` serializes the callable it is handed and a serialized
 * function carries no module scope with it. This is the one call site both the
 * artifact CLI below and the rig's `shoot.mjs` go through, so "the same census,
 * both sides" is a fact about the code and not a promise in a commit message.
 */
export const runCensus = (page, rootSel, structuralSel) =>
  page.evaluate(
    `(${censusRules.toString()})(${JSON.stringify(rootSel)}, ${HEAVY_PX}, ${JSON.stringify(structuralSel ?? null)})`,
  );

// ── the artifact side: a CLI that runs the SAME function on any page ─────────

function playwrightCandidates(repoRoot) {
  const roots = [repoRoot];
  try {
    const common = execFileSync("git", ["rev-parse", "--git-common-dir"], { cwd: repoRoot, encoding: "utf8" }).trim();
    roots.push(path.dirname(path.resolve(repoRoot, common)));
  } catch {
    /* not a checkout — the repo-root candidates still apply */
  }
  const rel = ["js/node_modules/node_modules/playwright", "js/node_modules/playwright", "node_modules/playwright"];
  const out = [];
  if (process.env.PLAYWRIGHT_DIR) out.push(process.env.PLAYWRIGHT_DIR);
  for (const r of roots) for (const s of rel) out.push(path.join(r, s));
  return out;
}

async function main() {
  const args = process.argv.slice(2);
  const target = args.find((a) => !a.startsWith("--"));
  if (!target) {
    console.error(
      "usage: census.mjs <file-or-url> [--root <sel>] [--structural <sel>] [--width <px>] [--scheme light|dark] [--json]",
    );
    process.exit(2);
  }
  const rootSel = args.includes("--root") ? args[args.indexOf("--root") + 1] : "body";
  const structuralSel = args.includes("--structural") ? args[args.indexOf("--structural") + 1] : null;
  const width = args.includes("--width") ? Number(args[args.indexOf("--width") + 1]) : 1280;
  const scheme = args.includes("--scheme") ? args[args.indexOf("--scheme") + 1] : "light";

  const repoRoot = path.resolve(path.dirname(new URL(import.meta.url).pathname), "../../..");
  let chromium = null;
  for (const dir of playwrightCandidates(repoRoot)) {
    const entry = path.join(dir, "index.mjs");
    if (fs.existsSync(entry)) ({ chromium } = await import(pathToFileURL(entry).href));
    if (chromium) break;
  }
  if (!chromium) {
    console.error("census: Playwright not found — set PLAYWRIGHT_DIR or run `npm install` in js/");
    process.exit(1);
  }

  const url = /^https?:/.test(target) ? target : pathToFileURL(path.resolve(target)).href;
  const browser = await chromium.launch();
  const context = await browser.newContext({ viewport: { width, height: 1200 }, deviceScaleFactor: 2, colorScheme: scheme });
  const page = await context.newPage();
  await page.goto(url, { waitUntil: "load" });
  await page.evaluate((s) => document.documentElement.setAttribute("data-theme", s), scheme);
  await page.evaluate(() => document.fonts.ready);
  const out = await runCensus(page, rootSel, structuralSel);
  await browser.close();
  if (args.includes("--json")) {
    console.log(JSON.stringify(out, null, 2));
    return;
  }
  console.log(
    `census: ${target} @${width} ${scheme} — ${out.total} rules, ${out.heavy} HEAVY (>=${HEAVY_PX}px)` +
      (structuralSel ? ` — ${out.structuralHeavy} structural, ${out.strayHeavy} stray` : ""),
  );
  console.log(`  weights: ${JSON.stringify(out.byWeight)}`);
  for (const r of out.heavyRules) {
    console.log(
      `  heavy ${r.px}px  y=${r.y}  ${r.width}px wide  (${r.parts} segment${r.parts === 1 ? "" : "s"})` +
        `  ${structuralSel ? (r.structural ? "[structural] " : "[STRAY] ") : ""}${r.owners.join(" | ")}`,
    );
  }
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) await main();
