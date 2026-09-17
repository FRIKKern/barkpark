// graph-palette-authority.test.mjs — enforces the claim design/tokens.json
// makes about itself.
//
// `color.graphCanvas.graph._note` says the token block is
//
//     "the SOLE source for every concrete colour that renderer paints"
//
// and until now that was an ASSERTION with no gate behind it. Byte identity
// across the four copies IS guarded (scripts/check-bp-graph-drift.sh) and the
// emitted region IS kept in sync with tokens.json (design/emit.mjs artifacts,
// `node design/emit.mjs --check`). Neither watches the region's COMPLEMENT: a
// literal `ctx.fillStyle = "#abc"` added anywhere OUTSIDE the generated markers
// is byte-identical across all four mirrors and leaves every artifact in sync,
// so every existing gate stays green while that colour silently stops tracking
// tokens.json — invisible to the CSS gates because Canvas 2D never consumes
// `var()`. That is the Canvas-drift class this file closes.
//
// ENROLMENT IS A PREDICATE, NOT A LIST: every file named bp-graph.js under the
// repo (minus node_modules / .claude worktrees / _build) enrols itself, so a
// fifth copy is covered the day it lands. An enumeration would go stale the
// same way the template snapshots once did.
//
// Every scan here is paired with a CONTROL that fires on planted input, because
// a colour regex that matches nothing would otherwise report a perfect green
// over a file it never read.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, dirname, relative } from "node:path";
import { fileURLToPath } from "node:url";

const REPO = join(dirname(fileURLToPath(import.meta.url)), "..");

const BEGIN = "/* BEGIN GENERATED: bp-graph-palette";
const END = "/* END GENERATED: bp-graph-palette */";

// Concrete colour literals a Canvas 2D context can consume directly.
// `rgba?\(\s*\d` deliberately requires a DIGIT first so the file's own
// `rgba(MONO_LIGHT, 0.65)` helper call — which resolves THROUGH the generated
// block — is not mistaken for a literal.
const COLOR_RE = /#[0-9a-fA-F]{3,8}\b|(?:rgba?|hsla?)\(\s*\d[^)]*\)/g;

const SKIP_DIRS = new Set([
  "node_modules", ".git", ".claude", "_build", "deps", "dist", ".next",
  ".turbo", "priv/static/cache_manifest", "coverage",
]);

function findCopies(dir, out = []) {
  for (const name of readdirSync(dir)) {
    if (SKIP_DIRS.has(name)) continue;
    const p = join(dir, name);
    let st;
    try { st = statSync(p); } catch { continue; }
    if (st.isDirectory()) findCopies(p, out);
    else if (name === "bp-graph.js") out.push(p);
  }
  return out;
}

// Split a bp-graph.js source into the generated palette region and everything
// else. Returns null when the marker pair is absent or malformed.
function splitAtMarkers(src) {
  const b = src.indexOf(BEGIN);
  const e = src.indexOf(END);
  if (b === -1 || e === -1 || e < b) return null;
  if (src.indexOf(BEGIN, b + 1) !== -1) return null; // a second BEGIN
  if (src.indexOf(END, e + 1) !== -1) return null;   // a second END
  return {
    inside: src.slice(b, e + END.length),
    outside: src.slice(0, b) + src.slice(e + END.length),
  };
}

function colorsIn(text) {
  return (text.match(COLOR_RE) || []);
}

const copies = findCopies(REPO).map((p) => ({
  path: p,
  rel: relative(REPO, p),
  src: readFileSync(p, "utf8"),
}));

const tokens = JSON.parse(readFileSync(join(REPO, "design/tokens.json"), "utf8"));
const graphTokens = tokens.color.graphCanvas.graph;

// ── controls on the instrument itself ────────────────────────────────────────

test("control: the scanner finds colour literals in planted input", () => {
  assert.deepEqual(colorsIn('ctx.fillStyle = "#16161a";'), ["#16161a"]);
  assert.deepEqual(colorsIn('a = "rgba(15,17,23,0.5)";'), ["rgba(15,17,23,0.5)"]);
  assert.deepEqual(colorsIn('h = "hsl(210, 5%, 9%)";'), ["hsl(210, 5%, 9%)"]);
  // and is NOT fooled by the file's own helper call, which resolves through
  // the generated block rather than carrying a literal.
  assert.deepEqual(colorsIn("return rgba(MONO_LIGHT, 0.65);"), []);
});

test("control: splitAtMarkers puts a planted outside-literal OUTSIDE", () => {
  const synthetic = `var a = "#aabbcc";\n${BEGIN} x */\nvar B = "#16161a";\n${END}\nvar c = "#ddeeff";\n`;
  const parts = splitAtMarkers(synthetic);
  assert.ok(parts, "marker pair must be found in the synthetic source");
  assert.deepEqual(colorsIn(parts.inside), ["#16161a"]);
  assert.deepEqual(colorsIn(parts.outside).sort(), ["#aabbcc", "#ddeeff"]);
});

test("control: a missing or duplicated marker pair is refused, not ignored", () => {
  assert.equal(splitAtMarkers("no markers here"), null);
  assert.equal(splitAtMarkers(`${BEGIN} a */\n${BEGIN} b */\n${END}`), null);
  assert.equal(splitAtMarkers(`${END}\n${BEGIN} a */`), null);
});

// ── enrolment ────────────────────────────────────────────────────────────────

test("at least the four declared bp-graph.js copies enrol by predicate", () => {
  assert.ok(copies.length >= 4, `expected >= 4 bp-graph.js copies, found ${copies.length}: ${copies.map((c) => c.rel)}`);
  for (const want of [
    "api/priv/static/assets/bp-graph.js",
    "web/public/bp-graph.js",
    "templates/search-starter/public/bp-graph.js",
    "templates/astro-search-starter/public/bp-graph.js",
  ]) {
    assert.ok(copies.some((c) => c.rel === want), `${want} did not enrol — the walk missed it`);
  }
});

// ── the authority claim, per copy ────────────────────────────────────────────

for (const copy of copies) {
  test(`${copy.rel}: carries exactly one generated palette region`, () => {
    assert.ok(splitAtMarkers(copy.src), `${copy.rel} has no single well-formed ${BEGIN} … ${END} pair`);
  });

  test(`${copy.rel}: the generated region actually holds colour literals`, () => {
    // Guards the vacuous direction: an empty region would make the
    // outside-is-clean assertion below trivially true.
    const parts = splitAtMarkers(copy.src);
    assert.ok(parts);
    assert.ok(colorsIn(parts.inside).length >= 50,
      `expected the emitted palette to carry many literals, got ${colorsIn(parts.inside).length}`);
  });

  test(`${copy.rel}: NO colour literal lives outside the generated region`, () => {
    const parts = splitAtMarkers(copy.src);
    assert.ok(parts);
    const strays = colorsIn(parts.outside);
    assert.deepEqual(strays, [],
      `${copy.rel} paints ${strays.length} colour(s) design/tokens.json never wrote: ${[...new Set(strays)].join(", ")}. ` +
      `Move the value into color.graphCanvas.graph and re-run: node design/emit.mjs --write`);
  });
}

// ── the emitted values are token values ──────────────────────────────────────

test("every literal in the generated region is a value tokens.json carries", () => {
  const tokenColors = new Set();
  const walk = (v) => {
    if (typeof v === "string") for (const m of colorsIn(v)) tokenColors.add(m);
    else if (v && typeof v === "object") for (const k of Object.keys(v)) {
      if (k.startsWith("_")) continue; // prose notes are not palette values
      walk(v[k]);
    }
  };
  walk(graphTokens);
  assert.ok(tokenColors.size >= 50, `control: expected many token colours, got ${tokenColors.size}`);

  const canonical = copies.find((c) => c.rel === "api/priv/static/assets/bp-graph.js");
  assert.ok(canonical, "the canonical copy must enrol");
  const parts = splitAtMarkers(canonical.src);
  const unsourced = [...new Set(colorsIn(parts.inside))].filter((c) => !tokenColors.has(c));
  assert.deepEqual(unsourced, [],
    `the generated region holds colour(s) absent from design/tokens.json color.graphCanvas.graph: ${unsourced.join(", ")}`);
});
