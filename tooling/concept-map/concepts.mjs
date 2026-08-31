#!/usr/bin/env node
// concepts.mjs — cqv8 Phase 1: the concept / coupling model.
//
// A CONCEPT is a cohesive cluster of symbols that the dependency graph already
// groups together but that the filesystem scatters across many trees. "sheets"
// is one concept even though it lives in barkpark/sheets*, plugins/sheets/*,
// barkpark_web live-views and tests. cqv8 P1 detects those concepts straight
// off the symbol graph, then computes Robert Martin's component algebra per
// concept — afferent (Ca) and efferent (Ce) coupling, instability I, cohesion —
// and partitions every concept into one of three bands on the
// dependency-stability gradient: KERNEL, CLEAN-FEATURE, UNSTABLE-EDGE.
//
//   node tooling/concept-map/concepts.mjs [--json]
//
// ── HOW CONCEPTS ARE DETECTED (computed, never hardcoded) ────────────────────
// The concept name of every symbol is derived structurally from its file path
// — the natural domain granularity Barkpark already uses:
//
//   api/lib/barkpark/plugins/<X>/…   → concept X   (a plugin feature)
//   api/lib/barkpark/plugins/<X>.ex  → concept X
//   api/lib/barkpark/<X>/…           → concept X   (a domain module)
//   api/lib/barkpark/<X>.ex          → concept X
//
// That first pass names every domain + plugin concept directly from the tree.
// A second pass folds the CROSS-TREE members in: web-layer files under
// barkpark_web/* and test files under test/* are attached to whichever already-
// discovered concept token appears as a path segment (longest token wins). This
// is what makes "sheets" span barkpark_web/live/sheets_reader_live.ex and the
// plugins/sheets tree as ONE concept. No concept list is written down anywhere —
// the set falls out of the graph.
//
// Mix CLI tasks (api/lib/mix/tasks/*) are the ONE cross-tree exception: they are
// ENTRY-POINTS that orchestrate a feature from the command line, not members of
// it. The fold skips them, so api/lib/mix/tasks/onix.import.ex is NOT a member of
// the "tasks" feature merely because its path contains "tasks" — it stays
// unconcepted, exactly like any other orchestration shell.
//
// ── THE COUPLING MATH (Martin's component algebra, live) ─────────────────────
//   intra — edges whose endpoints are both in this concept (cohesion numerator)
//   Ca    — AFFERENT: edges INBOUND to this concept from a different boundary
//           (another concept OR unconcepted code). "How much depends on me."
//   Ce    — EFFERENT: edges OUTBOUND from this concept to a different boundary.
//           "How much I depend on."
//   I     — instability = Ce / (Ca + Ce). 0 = maximally stable (only depended
//           upon); 1 = maximally unstable (only depends).
//   cohesion = intra / (intra + Ca + Ce). Share of a concept's edges that stay
//              inside its own boundary.
//
// ── THE BANDS ────────────────────────────────────────────────────────────────
//   KERNEL          high Ca, low I — depended-upon substrate. NOT extractable;
//                   high reach IS the substrate role (content Ca 390, tenancy 199).
//   CLEAN-FEATURE   high cohesion, low Ca, AND a plugin registration surface —
//                   a registered, extractable feature (sheets coh 0.87, onixedit).
//   CLEAN-NONPLUGIN clean by the SAME coupling math (high cohesion, low Ca) but
//                   WITHOUT the plugin registration surface — a pristine domain
//                   library, clean-by-coupling, just not a plugin (release coh
//                   1.00, portable_doc coh 0.86). The ONLY difference from
//                   CLEAN-FEATURE is the missing registration.
//   UNSTABLE-EDGE   high Ce, Ca ~0 — glue / entrypoints / seeders. Thin by design,
//                   wires into the kernel and is depended on by nothing.
//
// Dependency-free. ESM, node: builtins only. Computes everything from the real
// graph — never hardcodes an expected number.

import { execFileSync } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { isRegistered } from "./registration.mjs";
import { isMixTaskFile } from "./entrypoints.mjs";
import { conceptTokenMatchers } from "./concept-tokens.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE })
  .toString()
  .trim();

const SYMBOLS_PATH = join(ROOT, "tooling/symbol-graph/symbols.json");

// ── band thresholds (computed-against, documented) ───────────────────────────
// KERNEL is the depended-upon substrate: large afferent coupling, low
// instability. CLEAN-FEATURE is the extractable feature: high cohesion, low
// afferent coupling. UNSTABLE-EDGE is glue: maximal instability, ~no inbound.
// Concepts too small to characterise (MIN_FILES) are reported but unbanded.
export const KERNEL_CA = 150; // Ca at/above which a concept is depended-upon infra
export const KERNEL_I = 0.35; // instability below which a high-Ca concept is stable kernel
export const FEATURE_COHESION = 0.8; // cohesion at/above which a concept is a clean feature
export const FEATURE_CA = 30; // afferent coupling a clean feature stays below
export const EDGE_INSTABILITY = 0.85; // I at/above which a thin concept is an unstable edge
export const EDGE_CA = 10; // afferent coupling an unstable edge stays below
export const MIN_FILES = 2; // concepts with fewer files are unbanded noise

// ── load + concept detection ─────────────────────────────────────────────────
function loadGraph() {
  if (!existsSync(SYMBOLS_PATH)) {
    throw new Error(`symbol graph not found at ${SYMBOLS_PATH} — run tooling/symbol-graph/build-symbols.mjs first`);
  }
  return JSON.parse(readFileSync(SYMBOLS_PATH, "utf8"));
}

// Structural concept name for a domain/plugin file. Returns null for web-layer
// and test files (folded in by the second pass) and for Mix-task entry-points
// (deliberately NEVER folded — see assignConcepts).
function primaryConcept(file) {
  let m;
  if ((m = file.match(/^api\/lib\/barkpark\/plugins\/([a-z0-9_]+)(?:[/.]|$)/))) return m[1];
  if ((m = file.match(/^api\/lib\/barkpark\/([a-z0-9_]+)(?:[/.]|$)/))) return m[1];
  return null;
}

// Build node-id → concept. Two passes: (1) primary domain/plugin names off the
// tree; (2) cross-tree members (web + tests + anything else) attached to the
// longest already-discovered concept token that appears in their path.
function assignConcepts(graph) {
  const conceptOf = new Map(); // node id → concept
  const concepts = new Set();
  const filesOf = new Map(); // concept → Set<file>
  const topDirsOf = new Map(); // concept → Set<top-dir>

  for (const n of graph.nodes) {
    const c = primaryConcept(n.file);
    if (c) {
      conceptOf.set(n.id, c);
      concepts.add(c);
    }
  }

  // longest token first so "portable_doc" beats a stray "doc", etc.
  const tokens = [...concepts].sort((a, b) => b.length - a.length);
  const tokenRe = conceptTokenMatchers(tokens);

  for (const n of graph.nodes) {
    if (conceptOf.has(n.id)) continue;
    // Entry-point files (web controllers/LiveViews are folded for their feature
    // role; Mix CLI tasks are NOT) — a Mix task under api/lib/mix/tasks/ whose
    // path carries a feature token (onix.import.ex → "tasks") is orchestration,
    // not a member of that feature. Skipping the fold leaves it unconcepted, so
    // it never inflates a feature's file count or its sideways tally. Web-layer
    // files keep their historical fold behaviour (so tasks_controller.ex stays a
    // member of the tasks feature, media_controller.ex of media, etc.).
    if (isMixTaskFile(n.file)) continue;
    const low = n.file.toLowerCase();
    for (const t of tokens) {
      if (tokenRe.get(t).test(low)) {
        conceptOf.set(n.id, t);
        break;
      }
    }
  }

  for (const n of graph.nodes) {
    const c = conceptOf.get(n.id);
    if (!c) continue;
    if (!filesOf.has(c)) {
      filesOf.set(c, new Set());
      topDirsOf.set(c, new Set());
    }
    filesOf.get(c).add(n.file);
    topDirsOf.get(c).add(n.file.split("/").slice(0, 2).join("/"));
  }

  return { conceptOf, concepts, filesOf, topDirsOf };
}

// ── coupling computation ─────────────────────────────────────────────────────
function computeConcepts(graph) {
  const { conceptOf, concepts, filesOf, topDirsOf } = assignConcepts(graph);

  const stats = new Map();
  for (const c of concepts) stats.set(c, { intra: 0, ca: 0, ce: 0 });

  for (const e of graph.edges) {
    const cf = conceptOf.get(e.from); // concept of source (may be undefined)
    const ct = conceptOf.get(e.to); // concept of target (may be undefined)
    if (ct !== undefined && cf === ct) {
      stats.get(ct).intra++; // both ends inside one concept
      continue;
    }
    // edge crosses a boundary: inbound to ct (Ca), outbound from cf (Ce).
    if (ct !== undefined) stats.get(ct).ca++;
    if (cf !== undefined) stats.get(cf).ce++;
  }

  const rows = [];
  for (const c of concepts) {
    const s = stats.get(c);
    const denom = s.intra + s.ca + s.ce;
    const cohesion = denom ? s.intra / denom : 0;
    const instability = s.ca + s.ce ? s.ce / (s.ca + s.ce) : 0;
    const fileCount = filesOf.get(c).size;
    const dirSpread = topDirsOf.get(c).size;
    rows.push({
      concept: c,
      intra: s.intra,
      ca: s.ca,
      ce: s.ce,
      instability,
      cohesion,
      fileCount,
      dirSpread,
      band: classify({ concept: c, ca: s.ca, ce: s.ce, instability, cohesion, fileCount }),
    });
  }

  // sort by afferent coupling desc — the gradient reads kernel → feature → edge
  rows.sort((a, b) => b.ca - a.ca || b.cohesion - a.cohesion);
  return rows;
}

// Partition a concept onto the dependency-stability gradient. KERNEL is checked
// first (depended-upon substrate trumps everything); then the clean band — split
// into CLEAN-FEATURE (registered plugin) vs CLEAN-NONPLUGIN (clean by the same
// coupling math but lacking the plugin registration surface); then unstable edge;
// otherwise the concept is "mixed" (or "noise" if tiny). The clean-by-coupling
// gate is identical for both clean bands — only the registration surface differs.
function classify(m) {
  if (m.fileCount < MIN_FILES) return "noise";
  if (m.ca >= KERNEL_CA && m.instability <= KERNEL_I) return "KERNEL";
  if (m.cohesion >= FEATURE_COHESION && m.ca < FEATURE_CA) {
    return isRegistered(m.concept) ? "CLEAN-FEATURE" : "CLEAN-NONPLUGIN";
  }
  if (m.instability >= EDGE_INSTABILITY && m.ca < EDGE_CA) return "UNSTABLE-EDGE";
  return "mixed";
}

// ── public entrypoint ────────────────────────────────────────────────────────
export function runConcepts() {
  const graph = loadGraph();
  const rows = computeConcepts(graph);
  const banded = (b) => rows.filter((r) => r.band === b);
  return {
    builtAt: new Date().toISOString(),
    graph: { nodes: graph.nodes.length, edges: graph.edges.length },
    conceptCount: rows.length,
    bands: {
      kernel: banded("KERNEL").map((r) => r.concept),
      cleanFeature: banded("CLEAN-FEATURE").map((r) => r.concept),
      cleanNonplugin: banded("CLEAN-NONPLUGIN").map((r) => r.concept),
      unstableEdge: banded("UNSTABLE-EDGE").map((r) => r.concept),
    },
    concepts: rows,
  };
}

// ── human output ─────────────────────────────────────────────────────────────
const BAND_GLYPH = {
  KERNEL: "▓",
  "CLEAN-FEATURE": "░",
  "CLEAN-NONPLUGIN": "▒",
  "UNSTABLE-EDGE": "·",
  mixed: " ",
  noise: " ",
};

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
  out(`cqv8 P1 — concept / coupling model\n`);
  out(`${res.graph.nodes} nodes · ${res.graph.edges} edges · ${res.conceptCount} concepts detected\n`);
  out(`${bar}\n\n`);

  // gradient table — concepts in Ca-descending order
  out(
    `  ${pad("concept", 16)}${padL("Ca", 5)}${padL("Ce", 5)}${padL("intra", 7)}` +
      `${padL("I", 6)}${padL("coh", 6)}${padL("files", 7)}${padL("dirs", 5)}  band\n`
  );
  out(`  ${"-".repeat(78)}\n`);
  for (const r of res.concepts) {
    if (r.band === "noise") continue;
    out(
      `  ${pad(r.concept, 16)}${padL(r.ca, 5)}${padL(r.ce, 5)}${padL(r.intra, 7)}` +
        `${padL(r.instability.toFixed(2), 6)}${padL(r.cohesion.toFixed(2), 6)}` +
        `${padL(r.fileCount, 7)}${padL(r.dirSpread, 5)}  ${BAND_GLYPH[r.band]} ${r.band}\n`
    );
  }

  out(`\nBANDS\n`);
  out(`  ▓ KERNEL        (Ca ≥ ${KERNEL_CA}, I ≤ ${KERNEL_I}) — depended-upon, NOT extractable\n`);
  out(`      ${res.bands.kernel.join(", ") || "none"}\n`);
  out(`  ░ CLEAN-FEATURE (cohesion ≥ ${FEATURE_COHESION}, Ca < ${FEATURE_CA}, registered) — extractable plugin\n`);
  out(`      ${res.bands.cleanFeature.join(", ") || "none"}\n`);
  out(`  ▒ CLEAN-NONPLUGIN (cohesion ≥ ${FEATURE_COHESION}, Ca < ${FEATURE_CA}, NOT registered) — pristine domain lib\n`);
  out(`      ${res.bands.cleanNonplugin.join(", ") || "none"}\n`);
  out(`  · UNSTABLE-EDGE (I ≥ ${EDGE_INSTABILITY}, Ca < ${EDGE_CA}) — thin glue / entrypoints\n`);
  out(`      ${res.bands.unstableEdge.join(", ") || "none"}\n`);
  out(`\n${bar}\n`);
}

// ── CLI ──────────────────────────────────────────────────────────────────────
function main() {
  const argv = process.argv.slice(2);
  const res = runConcepts();
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
