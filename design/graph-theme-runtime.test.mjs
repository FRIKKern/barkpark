// graph-theme-runtime.test.mjs — the LIGHT/DARK half of the bp-graph.js Canvas
// palette contract, as a STANDING gate.
//
// WHAT WAS ALREADY GUARDED, AND WHAT WAS NOT.
//   • scripts/check-bp-graph-drift.sh    — the four copies are byte-identical.
//   • design/emit.mjs --check            — the generated palette block matches
//                                          design/tokens.json.
//   • design/graph-palette-authority.test.mjs — no concrete colour literal lives
//                                          OUTSIDE the generated markers, i.e.
//                                          tokens.json is the SOLE source.
// All three are STATIC reads of the file. None of them runs the renderer, so
// none of them can see WHICH of a light/dark token pair the paint path actually
// selects. Swap the two arms of `theme === "light" ? BG_LIGHT : BG_DARK` and
// every gate above stays green: the literals are unchanged, they are still in
// the marker, they still match tokens.json — the graph just paints the wrong
// ground in both modes. That inversion class is what this file closes, and the
// planted-mutant control below proves the check discriminates it.
//
// HOW IT MEASURES: it does not read the source, it RUNS it. Each bp-graph.js is
// evaluated in a `node:vm` realm against a minimal DOM stub whose canvas
// context RECORDS every value assigned to `ctx.fillStyle` / `ctx.strokeStyle` /
// `ctx.shadowColor`. A frame is then driven by hand (the harness owns
// requestAnimationFrame, and `reducedMotion: true` makes wake() a single
// deterministic redraw rather than a live rAF loop). The recorded fill set IS
// the pixel evidence: what the renderer would have painted, captured at the
// Canvas 2D API boundary. A whole-canvas image digest would be useless here —
// the force layout is non-deterministic — but the SET of colours it paints is
// stable, which is why the assertions are membership, never image equality.
//
// WHAT IT ASSERTS, AND WHAT IT DELIBERATELY DOES NOT. For each light/dark token
// pair in design/tokens.json `color.graphCanvas.graph`, the light run must paint
// the light value and NOT its dark sibling, and the dark run must do the
// reverse — under all three entry points: an explicit `theme` option, a
// `setTheme()` flip in place, and `theme: "auto"` resolving through matchMedia.
// It asserts NOTHING about identity (iris/forest/…): `graphCanvas` is a D21
// PASSTHROUGH family in design/derive.mjs, so the palette is identity-invariant
// BY CHARTER, and pinning that invariance here would bake a ruling nobody has
// made. This file is the light/dark half only; the identity half of the row's
// criterion stays open on an owner ruling.
//
// ENROLMENT IS A PREDICATE, NOT A LIST — design/bp-graph-copies.mjs, the same
// walk design/graph-palette-authority.test.mjs and the mirror census use, so a
// fifth copy is covered the day it lands.

import test from "node:test";
import assert from "node:assert/strict";
import vm from "node:vm";
import { readFileSync } from "node:fs";
import { join, dirname, relative, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { findCopies, CANONICAL_REL } from "./bp-graph-copies.mjs";

const REPO = join(dirname(fileURLToPath(import.meta.url)), "..");
const rel = (p) => relative(REPO, p).split(sep).join("/");

const TOKENS = JSON.parse(readFileSync(join(REPO, "design", "tokens.json"), "utf8"));
const G = TOKENS.color.graphCanvas.graph;

// The light/dark token pairs this harness can actually OBSERVE being painted.
// Each entry is [token-pair label, light value, dark value, which scene paints
// it]. "populated" = a three-node graph with a root; "empty" = the authored
// zero-state. Both scenes are driven, because the slate/toast pair is only
// reachable through the empty bed. Every value is read from tokens.json — the
// file under test is never consulted for an expected value.
const PAIRS = [
  ["background", G.bgLight, G.bgDark, "populated"],
  ["accent (root node)", G.accentLight, G.accent, "populated"],
  ["monochrome node tint", G.monoLight, G.monoDark, "populated"],
  ["background (empty state)", G.bgLight, G.bgDark, "empty"],
  ["slate (empty-state message)", G.slateLight, G.slate, "empty"],
  ["toast/tooltip glass", G.toastBgLight, G.toastBgDark, "empty"],
];

// ───────────────────────────────────────────────────────────────── harness ──

function makeCtx(rec) {
  const noop = () => {};
  const ctx = {
    save: noop, restore: noop, beginPath: noop, closePath: noop, moveTo: noop,
    lineTo: noop, arc: noop, arcTo: noop, fill: noop, stroke: noop,
    fillRect: noop, strokeRect: noop, fillText: noop, strokeText: noop,
    clip: noop, rect: noop, translate: noop, scale: noop, rotate: noop,
    setTransform: noop, resetTransform: noop, setLineDash: noop,
    quadraticCurveTo: noop, bezierCurveTo: noop, ellipse: noop,
    clearRect: noop, drawImage: noop,
    createLinearGradient: () => ({ addColorStop: noop }),
    createRadialGradient: () => ({ addColorStop: noop }),
    measureText: (s) => ({
      width: String(s).length * 6,
      actualBoundingBoxAscent: 8,
      actualBoundingBoxDescent: 2,
    }),
    globalAlpha: 1, globalCompositeOperation: "source-over", lineWidth: 1,
    lineCap: "butt", lineJoin: "miter", font: "", letterSpacing: "0px",
    textAlign: "start", textBaseline: "alphabetic",
    shadowBlur: 0, shadowOffsetX: 0, shadowOffsetY: 0,
    filter: "none", imageSmoothingEnabled: true,
  };
  // The recording surface. Canvas 2D takes colour ONLY through these three.
  for (const k of ["fillStyle", "strokeStyle", "shadowColor"]) {
    let v = "#000000";
    Object.defineProperty(ctx, k, {
      get: () => v,
      set: (nv) => {
        v = nv;
        if (typeof nv === "string") rec[k].add(nv);
      },
    });
  }
  return ctx;
}

function makeEl(tag, ctx) {
  const el = {
    tagName: String(tag).toUpperCase(), nodeName: String(tag).toUpperCase(),
    style: {}, dataset: {}, childNodes: [], children: [],
    textContent: "", innerHTML: "", innerText: "", value: "", id: "", className: "",
    width: 0, height: 0, disabled: false, title: "", type: "", placeholder: "",
    parentNode: null, offsetWidth: 800, offsetHeight: 600,
    scrollTop: 0, scrollLeft: 0, scrollHeight: 600, clientWidth: 800, clientHeight: 600,
    setAttribute() {}, removeAttribute() {}, getAttribute() { return null; },
    hasAttribute() { return false; },
    appendChild(c) { this.children.push(c); this.childNodes.push(c); c.parentNode = this; return c; },
    insertBefore(c) { this.children.unshift(c); return c; },
    removeChild(c) {
      const i = this.children.indexOf(c);
      if (i >= 0) { this.children.splice(i, 1); this.childNodes.splice(i, 1); }
      return c;
    },
    remove() { if (this.parentNode) this.parentNode.removeChild(this); },
    replaceChildren() { this.children = []; this.childNodes = []; },
    addEventListener() {}, removeEventListener() {}, dispatchEvent() { return true; },
    focus() {}, blur() {}, click() {}, scrollIntoView() {},
    contains() { return false; },
    querySelector() { return null; }, querySelectorAll() { return []; },
    getBoundingClientRect: () => ({
      width: 800, height: 600, left: 0, top: 0, right: 800, bottom: 600, x: 0, y: 0,
    }),
    classList: { add() {}, remove() {}, toggle() {}, contains() { return false; } },
    setPointerCapture() {}, releasePointerCapture() {},
  };
  if (String(tag).toLowerCase() === "canvas") el.getContext = () => ctx;
  return el;
}

const POPULATED = {
  nodes: [
    { id: "a", type: "paper", title: "Alpha" },
    { id: "b", type: "task", title: "Beta" },
    { id: "c", type: "post", title: "Gamma" },
  ],
  edges: [{ source: "a", target: "b" }, { source: "a", target: "c" }],
  rootId: "a",
};
const EMPTY = { nodes: [], edges: [], rootId: null };

// mount(src, {theme, prefersLight, scene}) — evaluate a bp-graph.js source in a
// throwaway realm, mount the renderer, drive one settled frame, and hand back
// the recorded colour sets plus the live handle (so setTheme can be exercised).
function mount(src, o = {}) {
  const rec = { fillStyle: new Set(), strokeStyle: new Set(), shadowColor: new Set() };
  const ctx = makeCtx(rec);
  const raf = [];
  const sandbox = {
    console: { log() {}, warn() {}, error() {}, info() {}, debug() {} },
    requestAnimationFrame(fn) { raf.push(fn); return raf.length; },
    cancelAnimationFrame() {},
    setTimeout() { return 0; }, clearTimeout() {},
    setInterval() { return 0; }, clearInterval() {},
    getComputedStyle: () => ({ position: "relative", getPropertyValue: () => "" }),
    ResizeObserver: class { observe() {} unobserve() {} disconnect() {} },
    IntersectionObserver: class { observe() {} unobserve() {} disconnect() {} },
    localStorage: { getItem: () => null, setItem() {}, removeItem() {} },
    performance: { now: () => 0 },
    devicePixelRatio: 1,
    visualViewport: null,
    // The ONLY signal "auto" consults. Everything else about the page is stubbed
    // flat, so an "auto" run that lands on the wrong ground can only have come
    // from the renderer's own resolution.
    matchMedia(q) {
      return {
        matches: /prefers-color-scheme:\s*light/.test(q) ? !!o.prefersLight : false,
        media: q,
        addEventListener() {}, removeEventListener() {},
        addListener() {}, removeListener() {},
      };
    },
    document: {
      createElement: (t) => makeEl(t, ctx),
      documentElement: makeEl("html", ctx),
      body: makeEl("body", ctx),
      addEventListener() {}, removeEventListener() {},
      querySelector: () => null,
    },
  };
  sandbox.window = sandbox;
  sandbox.self = sandbox;
  sandbox.globalThis = sandbox;
  sandbox.addEventListener = () => {};
  sandbox.removeEventListener = () => {};
  vm.createContext(sandbox);
  vm.runInContext(src, sandbox, { filename: "bp-graph.js" });

  assert.equal(
    typeof sandbox.window.BarkparkGraphRenderer,
    "function",
    "bp-graph.js did not publish window.BarkparkGraphRenderer — the harness never reached the renderer",
  );

  const scene = o.scene === "empty" ? EMPTY : POPULATED;
  const container = makeEl("div", ctx);
  let now = 16;
  const pump = (rounds = 8) => {
    for (let i = 0; i < rounds; i++) {
      const batch = raf.splice(0, raf.length);
      if (!batch.length) break;
      now += 16;
      for (const fn of batch) fn(now);
    }
  };
  const reset = () => { for (const k of Object.keys(rec)) rec[k].clear(); };

  const handle = sandbox.window.BarkparkGraphRenderer(
    container,
    { nodes: scene.nodes, edges: scene.edges },
    { theme: o.theme || "auto", reducedMotion: true, rootId: scene.rootId },
  );
  pump();
  return { rec, handle, pump, reset };
}

// paintedColours(...) — every colour string the run pushed at the context.
const painted = (rec) =>
  new Set([...rec.fillStyle, ...rec.strokeStyle, ...rec.shadowColor]);

// checkPairs(lightSet, darkSet, scene) — the verdict, as a list of failure
// strings (empty = pass). Factored out so the planted-mutant control can run
// the SAME predicate and be shown to reject.
function checkPairs(lightSet, darkSet, scene) {
  const bad = [];
  for (const [label, lightVal, darkVal, want] of PAIRS) {
    if (want !== scene) continue;
    if (lightVal === darkVal) continue; // not a pair; nothing to discriminate
    if (!lightSet.has(lightVal)) bad.push(`light run never painted ${label} ${lightVal}`);
    if (lightSet.has(darkVal)) bad.push(`light run painted the DARK ${label} ${darkVal}`);
    if (!darkSet.has(darkVal)) bad.push(`dark run never painted ${label} ${darkVal}`);
    if (darkSet.has(lightVal)) bad.push(`dark run painted the LIGHT ${label} ${lightVal}`);
  }
  return bad;
}

const COPIES = findCopies(REPO).sort();
const SRC = new Map(COPIES.map((p) => [p, readFileSync(p, "utf8")]));

// ─────────────────────────────────────────────────────────────────── tests ──

test("enrolment: every bp-graph.js copy in the tree is a subject, canonical included", () => {
  const rels = COPIES.map(rel);
  assert.ok(rels.length >= 4, `expected at least the four known copies, found ${rels.length}: ${rels.join(", ")}`);
  assert.ok(rels.includes(CANONICAL_REL), `canonical ${CANONICAL_REL} missing from the walk: ${rels.join(", ")}`);
});

test("CONTROL: the harness actually paints — a light run records several distinct colours", () => {
  const src = SRC.get(join(REPO, CANONICAL_REL));
  assert.ok(src, `canonical source not readable at ${CANONICAL_REL}`);
  const run = mount(src, { theme: "light", scene: "populated" });
  const seen = painted(run.rec);
  // A probe that recorded nothing would "prove" every membership assertion
  // below vacuously in the NOT-present direction. Three distinct fills is the
  // floor: background + root accent + node tint.
  assert.ok(
    run.rec.fillStyle.size >= 3,
    `probe recorded only ${run.rec.fillStyle.size} distinct fillStyle values: ${[...seen].join(", ")}`,
  );
  assert.ok(seen.has(G.bgLight), `probe did not record the light ground ${G.bgLight}: ${[...seen].join(", ")}`);
});

test("CONTROL: a planted always-dark mutant is REJECTED by the same predicate", () => {
  const src = SRC.get(join(REPO, CANONICAL_REL));
  // Invert exactly the ground selector. Every static gate stays green on this
  // mutant — same literals, same marker, same tokens.json — so if checkPairs
  // did not reject it, nothing in the repo would.
  const needle = 'return theme === "light" ? BG_LIGHT : BG_DARK;';
  assert.ok(src.includes(needle), `the ground selector moved; expected to find ${needle}`);
  const mutant = src.replace(needle, "return BG_DARK;");
  assert.notEqual(mutant, src, "mutation was a no-op — the control would have measured nothing");

  const light = painted(mount(mutant, { theme: "light", scene: "populated" }).rec);
  const dark = painted(mount(mutant, { theme: "dark", scene: "populated" }).rec);
  const bad = checkPairs(light, dark, "populated");
  assert.ok(
    bad.some((b) => b.includes("background")),
    `the always-dark mutant was NOT rejected on the background pair; verdict was: ${bad.join(" | ") || "(clean)"}`,
  );
});

for (const p of COPIES) {
  const src = SRC.get(p);
  const name = rel(p);

  test(`${name}: explicit theme option selects the canonical light/dark token`, () => {
    for (const scene of ["populated", "empty"]) {
      const light = painted(mount(src, { theme: "light", scene }).rec);
      const dark = painted(mount(src, { theme: "dark", scene }).rec);
      const bad = checkPairs(light, dark, scene);
      assert.equal(bad.length, 0, `${scene}: ${bad.join(" | ")}`);
    }
  });

  test(`${name}: setTheme() flips the painted palette in place, both directions`, () => {
    const run = mount(src, { theme: "light", scene: "populated" });
    run.reset();
    run.handle.setTheme("dark");
    run.pump();
    const afterDark = painted(run.rec);
    run.reset();
    run.handle.setTheme("light");
    run.pump();
    const afterLight = painted(run.rec);
    const bad = checkPairs(afterLight, afterDark, "populated");
    assert.equal(bad.length, 0, bad.join(" | "));
  });

  test(`${name}: theme "auto" resolves through prefers-color-scheme`, () => {
    const light = painted(mount(src, { theme: "auto", prefersLight: true, scene: "populated" }).rec);
    const dark = painted(mount(src, { theme: "auto", prefersLight: false, scene: "populated" }).rec);
    const bad = checkPairs(light, dark, "populated");
    assert.equal(bad.length, 0, bad.join(" | "));
  });
}
