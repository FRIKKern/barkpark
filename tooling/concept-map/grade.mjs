#!/usr/bin/env node
// grade.mjs — cqv8 Phase 3: the grade pass.
//
// P1 detected the concepts and partitioned them onto the dependency-stability
// gradient. P2 learned the feature skeleton from the repo's own exemplars. P3 is
// the JUDGEMENT: for every concept it runs the spec's FIVE measured gaps and
// emits a verdict — kernel · clean · tangled — plus the named remediation edges
// (which edges to colocate, which to cut) and the scatter number.
//
//   node tooling/concept-map/grade.mjs [--json]
//
// ── THE FIVE GAPS (spec §5, Figure 5) ────────────────────────────────────────
//   1. GRATUITOUS-CORE  — "core keeps reusable machinery" is mostly a lie. For a
//      concept's CORE HALF (its barkpark/<name>* files, EXCLUDING the plugins/
//      tree) we measure what share of inbound edges come from OUTSIDE the
//      concept. A low external share means the core is reused only by its own
//      feature — it is gratuitously in the kernel and should be COLOCATED into
//      the feature folder. sheets' core half is ~94% sheets-internal (≈226 in,
//      ≈14 out) → GRATUITOUS. Contrast portable_doc (Ce 0, genuinely reused) —
//      kept in kernel. The rule is arithmetic: external% < GRATUITOUS_EXTERNAL_PCT
//      → flag colocate.
//   2. TEST-SCATTER     — count the DISTINCT test directories a concept's tests
//      live in. The target is 1. Every real Barkpark feature splits across 2–3+
//      dirs today — a universal flaw, not a framework requirement.
//   3. SIDEWAYS EDGES   — feature→feature edges: this concept depending on a
//      DIFFERENT non-kernel concept. Features should depend only inward on the
//      kernel; a sideways edge is a boundary violation, named and counted (the
//      exact "cut" list).
//   4. MANIFEST-ABSENCE — is there a per-feature manifest on disk declaring the
//      concept's identity / surface / owned-tables / allowed-deps? None exist
//      yet, so every concept is flagged. The manifest makes the boundary exact;
//      its absence is why the sideways/concept analysis still carries noise.
//   5. FRAMEWORK-SCATTER — dirSpread: how many top-level dir trees the concept's
//      symbols occupy. Phoenix genuinely forces web code under barkpark_web/, so
//      some spread is framework-forced; this number is the raw scatter, the gap
//      between it and the framework minimum is the actionable slice.
//
// ── THE VERDICT ──────────────────────────────────────────────────────────────
//   kernel   — P1 put it in the KERNEL band. High Ca IS the substrate role; it is
//              NOT graded as a feature (you do not colocate the kernel).
//   clean    — a non-kernel concept with NO gratuitous core, NO sideways edges,
//              and a single test home. The shape the whole capability targets.
//   tangled  — a non-kernel concept that trips ANY feature gap (gratuitous core,
//              sideways edges, or test-scatter). Carries the named colocate/cut
//              edges + the scatter number so the remediation is concrete.
//
// Dependency-free. ESM, node: builtins only. Reuses P1 (runConcepts) for the
// bands + per-concept coupling, the real symbol graph for the core-half + sideways
// arithmetic, and the on-disk test tree for test-scatter. Computes everything
// live — never hardcodes an expected number, edge, or verdict.

import { execFileSync } from "node:child_process";
import { readFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { runConcepts } from "./concepts.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE })
  .toString()
  .trim();

const SYMBOLS_PATH = join(ROOT, "tooling/symbol-graph/symbols.json");
const TEST_DIR = join(ROOT, "api/test");

// ── grade thresholds (computed-against, documented) ──────────────────────────
// GRATUITOUS_EXTERNAL_PCT — the external-reuse % at/below which a concept's core
// half is "gratuitously in the kernel": almost nobody outside the feature uses
// it, so it belongs IN the feature folder. 20% is the spec's stated line — 97%
// internal (3% external) is an obvious colocate; the threshold draws the line
// well clear of genuinely-shared infrastructure (portable_doc, Ce 0).
// TEST_HOME_TARGET — one test directory per feature. More than this is scatter.
// MIN_SIDEWAYS — a feature→feature edge cluster only counts as actionable at or
// above this many edges (one stray symbol reference is noise; a real coupling is
// a thick edge). Reported clusters below this are still listed, just not flagged.
export const GRATUITOUS_EXTERNAL_PCT = 20; // external% below this → colocate the core
export const TEST_HOME_TARGET = 1; // target distinct test dirs per feature
export const MIN_SIDEWAYS = 1; // a sideways cluster counts from this many edges

// ── load + concept assignment (mirrors concepts.mjs structural detection) ────
function loadGraph() {
  if (!existsSync(SYMBOLS_PATH)) {
    throw new Error(
      `symbol graph not found at ${SYMBOLS_PATH} — run tooling/symbol-graph/build-symbols.mjs first`
    );
  }
  return JSON.parse(readFileSync(SYMBOLS_PATH, "utf8"));
}

function primaryConcept(file) {
  let m;
  if ((m = file.match(/^api\/lib\/barkpark\/plugins\/([a-z0-9_]+)(?:[/.]|$)/))) return m[1];
  if ((m = file.match(/^api\/lib\/barkpark\/([a-z0-9_]+)(?:[/.]|$)/))) return m[1];
  return null;
}

// Reproduce the P1 two-pass concept assignment so the grade speaks the same
// concept vocabulary the bands were computed from.
function assignConcepts(graph) {
  const conceptOf = new Map();
  const concepts = new Set();
  for (const n of graph.nodes) {
    const c = primaryConcept(n.file);
    if (c) {
      conceptOf.set(n.id, c);
      concepts.add(c);
    }
  }
  const tokens = [...concepts].sort((a, b) => b.length - a.length);
  const tokenRe = new Map(
    tokens.map((t) => [t, new RegExp("(^|[/_.])" + t + "([/_.]|$)")])
  );
  for (const n of graph.nodes) {
    if (conceptOf.has(n.id)) continue;
    const low = n.file.toLowerCase();
    for (const t of tokens) {
      if (tokenRe.get(t).test(low)) {
        conceptOf.set(n.id, t);
        break;
      }
    }
  }
  const fileOf = new Map(graph.nodes.map((n) => [n.id, n.file]));
  return { conceptOf, fileOf };
}

// ── gap 1: gratuitous core-half ──────────────────────────────────────────────
// The CORE HALF of a concept is its files directly under api/lib/barkpark/<name>
// (a domain module), explicitly EXCLUDING anything under a plugins/ tree (that
// is the feature wiring, not the core). We tally inbound edges to those core
// nodes and split them by whether the source symbol belongs to this same concept
// (internal) or to anything else (external). A low external share means the core
// is reused only by its own feature — gratuitously in the kernel, colocate it.
function coreHalfReuse(concept, graph, conceptOf) {
  const coreRe = new RegExp("^api/lib/barkpark/" + concept + "(?:[/.]|$)");
  const coreIds = new Set();
  for (const n of graph.nodes) {
    if (coreRe.test(n.file) && !/\/plugins\//.test(n.file)) coreIds.add(n.id);
  }
  let internal = 0;
  let external = 0;
  if (coreIds.size > 0) {
    for (const e of graph.edges) {
      if (!coreIds.has(e.to)) continue;
      const fc = conceptOf.get(e.from);
      if (fc === concept) internal++;
      else external++;
    }
  }
  const inbound = internal + external;
  const externalPct = inbound ? (external / inbound) * 100 : null;
  return {
    coreNodes: coreIds.size,
    internalInbound: internal,
    externalInbound: external,
    externalPct,
    // gratuitous only if there IS a core half with real inbound AND its reuse is
    // overwhelmingly internal (externalPct strictly below the threshold).
    gratuitous: coreIds.size > 0 && inbound > 0 && externalPct < GRATUITOUS_EXTERNAL_PCT,
  };
}

// ── gap 2: test-scatter ──────────────────────────────────────────────────────
// Test files are not in the symbol graph; read them off disk and bucket by
// directory. A concept's tests are any test file whose path carries the concept
// token (same fuzzy match the concept-detection uses — its noise is exactly the
// noise gap 4's manifest would remove).
function listTestFiles(rootDir) {
  const out = [];
  function walk(d) {
    let entries;
    try {
      entries = readdirSync(d);
    } catch {
      return;
    }
    for (const name of entries) {
      const full = join(d, name);
      let st;
      try {
        st = statSync(full);
      } catch {
        continue;
      }
      if (st.isDirectory()) walk(full);
      else out.push(full);
    }
  }
  walk(rootDir);
  return out;
}

function testScatter(concept, allTestFiles) {
  const re = new RegExp("(^|[/_.])" + concept + "([/_.]|$)");
  const rel = (f) => f.slice(ROOT.length + 1);
  const matches = allTestFiles.filter((f) => re.test(f.toLowerCase()));
  const dirs = new Set(matches.map((f) => dirname(rel(f))));
  return { testFileCount: matches.length, testDirs: [...dirs].sort() };
}

// ── gap 3: sideways edges ────────────────────────────────────────────────────
// Feature→feature: an edge FROM this concept TO a DIFFERENT concept, where the
// target is itself a non-kernel feature. Kernel targets are allowed (depend
// inward); sideways targets are the violations. Returned as a counted, named
// "cut" list — exactly what boundary-lint would flag.
function sidewaysEdges(concept, graph, conceptOf, kernelSet) {
  const counts = new Map();
  for (const e of graph.edges) {
    if (conceptOf.get(e.from) !== concept) continue;
    const ct = conceptOf.get(e.to);
    if (!ct || ct === concept) continue;
    if (kernelSet.has(ct)) continue; // inward dep on the kernel is allowed
    counts.set(ct, (counts.get(ct) || 0) + 1);
  }
  return [...counts.entries()]
    .filter(([, n]) => n >= MIN_SIDEWAYS)
    .map(([to, edges]) => ({ to, edges }))
    .sort((a, b) => b.edges - a.edges || a.to.localeCompare(b.to));
}

// ── gap 4: manifest-absence ──────────────────────────────────────────────────
// A per-feature manifest declares identity / surface / owned-tables / allowed-
// deps in one place. P4 defines its schema; P3 just checks whether one exists.
// We probe the conventional locations a manifest could live for this concept.
function manifestPaths(concept) {
  return [
    "api/lib/barkpark/plugins/" + concept + "/manifest.json",
    "api/lib/barkpark/plugins/" + concept + ".manifest.json",
    "api/lib/barkpark/" + concept + "/manifest.json",
    "api/lib/barkpark/" + concept + ".manifest.json",
    "tooling/concept-map/manifests/" + concept + ".json",
  ];
}

function manifestPresence(concept) {
  for (const p of manifestPaths(concept)) {
    if (existsSync(join(ROOT, p))) return { present: true, path: p };
  }
  return { present: false, path: null };
}

// ── the verdict ──────────────────────────────────────────────────────────────
// kernel concepts are not feature-graded. A non-kernel concept is clean only if
// it trips NONE of the feature gaps (no gratuitous core, no sideways edges, one
// test home); otherwise tangled.
function verdictFor(band, gaps) {
  if (band === "KERNEL") return "kernel";
  const featureFlaw =
    gaps.gratuitousCore.gratuitous ||
    gaps.sideways.length > 0 ||
    gaps.testScatter.testDirs.length > TEST_HOME_TARGET;
  return featureFlaw ? "tangled" : "clean";
}

// ── public entrypoint ────────────────────────────────────────────────────────
export function runGrade() {
  const graph = loadGraph();
  const p1 = runConcepts();
  const kernelSet = new Set(p1.bands.kernel);
  const { conceptOf } = assignConcepts(graph);
  const allTestFiles = existsSync(TEST_DIR) ? listTestFiles(TEST_DIR) : [];

  const rows = [];
  for (const c of p1.concepts) {
    if (c.band === "noise") continue;

    const gratuitousCore = coreHalfReuse(c.concept, graph, conceptOf);
    const scatter = testScatter(c.concept, allTestFiles);
    const sideways = sidewaysEdges(c.concept, graph, conceptOf, kernelSet);
    const manifest = manifestPresence(c.concept);
    const gaps = {
      gratuitousCore,
      testScatter: scatter,
      sideways,
      manifestAbsent: !manifest.present,
      manifestPath: manifest.path,
      frameworkScatter: c.dirSpread,
    };

    const verdict = verdictFor(c.band, gaps);

    // named remediation edges: colocate (core into the feature) + cut (sideways).
    const colocate =
      gratuitousCore.gratuitous && c.band !== "KERNEL"
        ? [
            {
              what: c.concept + " core-half → feature folder",
              externalPct: Number(gratuitousCore.externalPct.toFixed(1)),
              internalInbound: gratuitousCore.internalInbound,
              externalInbound: gratuitousCore.externalInbound,
            },
          ]
        : [];
    const cut =
      c.band !== "KERNEL"
        ? sideways.map((s) => ({ edge: c.concept + " → " + s.to, edges: s.edges }))
        : [];

    rows.push({
      concept: c.concept,
      band: c.band,
      verdict,
      ca: c.ca,
      ce: c.ce,
      cohesion: c.cohesion,
      gaps,
      remediation: { colocate, cut, scatter: c.dirSpread },
    });
  }

  // order: tangled first (most actionable), then clean, then kernel; within a
  // verdict the worst sideways/scatter offenders lead.
  const VERDICT_ORDER = { tangled: 0, clean: 1, kernel: 2 };
  rows.sort(
    (a, b) =>
      VERDICT_ORDER[a.verdict] - VERDICT_ORDER[b.verdict] ||
      b.gaps.sideways.length - a.gaps.sideways.length ||
      b.gaps.testScatter.testDirs.length - a.gaps.testScatter.testDirs.length ||
      a.concept.localeCompare(b.concept)
  );

  const tangled = rows.filter((r) => r.verdict === "tangled");

  return {
    builtAt: new Date().toISOString(),
    graph: { nodes: graph.nodes.length, edges: graph.edges.length },
    thresholds: {
      gratuitousExternalPct: GRATUITOUS_EXTERNAL_PCT,
      testHomeTarget: TEST_HOME_TARGET,
      minSideways: MIN_SIDEWAYS,
    },
    counts: {
      total: rows.length,
      kernel: rows.filter((r) => r.verdict === "kernel").length,
      clean: rows.filter((r) => r.verdict === "clean").length,
      tangled: tangled.length,
    },
    concepts: rows,
  };
}

// ── human output ─────────────────────────────────────────────────────────────
const VERDICT_GLYPH = { kernel: "▓", clean: "░", tangled: "✗" };

function pad(s, n) {
  s = String(s);
  return s.length >= n ? s : s + " ".repeat(n - s.length);
}
function padL(s, n) {
  s = String(s);
  return s.length >= n ? s : " ".repeat(n - s.length) + s;
}

function printHuman(res) {
  const out = (s) => process.stdout.write(s);
  const bar = "─".repeat(82);
  out(`\n${bar}\n`);
  out(`cqv8 P3 — grade pass (five measured gaps)\n`);
  out(
    `${res.graph.nodes} nodes · ${res.graph.edges} edges · ` +
      `${res.counts.tangled} tangled · ${res.counts.clean} clean · ${res.counts.kernel} kernel\n`
  );
  out(`${bar}\n\n`);

  out(
    `  ${pad("concept", 16)}${pad("verdict", 9)}${padL("ext%", 7)}` +
      `${padL("tests", 7)}${padL("sdwys", 7)}${padL("scatter", 9)}  manifest\n`
  );
  out(`  ${"-".repeat(78)}\n`);
  for (const r of res.concepts) {
    const ext = r.gaps.gratuitousCore.externalPct;
    const extStr =
      ext == null ? "—" : ext.toFixed(1) + (r.gaps.gratuitousCore.gratuitous ? "!" : "");
    out(
      `  ${pad(r.concept, 16)}${pad(VERDICT_GLYPH[r.verdict] + " " + r.verdict, 9)}` +
        `${padL(extStr, 7)}${padL(r.gaps.testScatter.testDirs.length, 7)}` +
        `${padL(r.gaps.sideways.length, 7)}${padL(r.gaps.frameworkScatter, 9)}` +
        `  ${r.gaps.manifestAbsent ? "absent" : "present"}\n`
    );
  }

  // detail the tangled concepts — the named colocate/cut edges.
  out(`\nTANGLED — named remediation\n`);
  const tangled = res.concepts.filter((r) => r.verdict === "tangled");
  if (tangled.length === 0) out(`  (none)\n`);
  for (const r of tangled) {
    out(`\n  ✗ ${r.concept}  (Ca ${r.ca} · coh ${r.cohesion.toFixed(2)} · scatter ${r.remediation.scatter})\n`);
    for (const c of r.remediation.colocate) {
      out(
        `      colocate  ${c.what}  —  ${c.externalPct}% external ` +
          `(${c.internalInbound} internal / ${c.externalInbound} external inbound)\n`
      );
    }
    for (const c of r.remediation.cut) {
      out(`      cut       ${c.edge}  —  ${c.edges} edge(s)\n`);
    }
    if (r.gaps.testScatter.testDirs.length > 1) {
      out(`      tests     ${r.gaps.testScatter.testDirs.length} dirs (target 1):\n`);
      for (const d of r.gaps.testScatter.testDirs) out(`                  ${d}\n`);
    }
  }

  out(`\n${bar}\n`);
}

// ── CLI ──────────────────────────────────────────────────────────────────────
function main() {
  const argv = process.argv.slice(2);
  const res = runGrade();
  if (argv.includes("--json")) {
    process.stdout.write(JSON.stringify(res, null, 2) + "\n");
  } else {
    printHuman(res);
  }
  process.exit(0);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main();
}
