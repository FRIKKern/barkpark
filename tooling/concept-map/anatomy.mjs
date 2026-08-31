#!/usr/bin/env node
// anatomy.mjs — cqv8 Phase 2: the anatomy-learner.
//
// cqv8 is learned-first, not template-first. It does not ship a "correct feature
// shape" baked in — it DERIVES the shape from the repo's own best-formed features
// (the EXEMPLARS) and uses that derived SKELETON for both grading (P3) and
// scaffolding (P4). This module is the learner.
//
//   node tooling/concept-map/anatomy.mjs [--json]
//
// ── THE THREE STEPS (spec §4, Figure 4) ──────────────────────────────────────
//   1. PICK EXEMPLARS — the repo's best-formed features: high cohesion, low
//      afferent coupling (Ca), AND a real registration call (a true plugin, not
//      a domain module or a trivial leaf). The coupling math is what teaches us
//      which features to EXCLUDE — media (Ca 28, half-infrastructure) and frt
//      (too trivial, cohesion below the floor) fall out automatically.
//   2. EXTRACT THE SKELETON — the recurring structural ROLE-SET across exemplars
//      (engine · session · structure · live · controller · registry · core ·
//      test), the REGISTRATION call shape they all share, and the kernel
//      concepts every exemplar depends inward on (allowedKernelDeps).
//   3. THE SKELETON IS THE TEMPLATE — P3 grades against it, P4 instantiates it.
//
//   Curated fallback: with fewer than MIN_CLEAN_EXEMPLARS clean exemplars, fall
//   back to a per-language archetype (marked usedCuratedFallback:true) so the
//   output is honest about its grounding.
//
// ── HOW EXEMPLARS ARE CHOSEN (computed, never hardcoded) ─────────────────────
//   Candidates are non-kernel, non-noise concepts (from P1's bands) that sit in
//   the clean-feature region of the gradient:
//       Ca       ≤ EXEMPLAR_CA_MAX   (low afferent coupling — extractable)
//       cohesion ≥ EXEMPLAR_COH_MIN  (genuinely cohesive)
//   …AND carry the repo's registration convention in their plugin entry file
//   (def register_schemas / def register_routes). The registration filter is the
//   discriminator that separates real features (sheets, onixedit, tasks) from
//   high-cohesion-but-trivial domain modules (release, indx) and from
//   half-infrastructure (media). Exemplars are then ranked by ROLE-VARIETY
//   (richest anatomy first) then cohesion — the spec's "most role-variety to
//   learn from" criterion.
//
// ── HOW THE SKELETON IS EXTRACTED ────────────────────────────────────────────
//   roles[]            — union of detected role markers across exemplars, each
//                        with the count of exemplars exhibiting it (a role is
//                        "recurring" when ≥2 exemplars show it). core +
//                        registration + test are structural roles every feature
//                        carries; the rest are read off file paths + the test
//                        tree.
//   registration       — the recurring registration call shape (the call names
//                        every exemplar's plugin file actually defines).
//   allowedKernelDeps  — the INTERSECTION of each exemplar's efferent targets
//                        that land in P1's KERNEL band. A feature is allowed to
//                        depend inward on exactly these; anything else is a
//                        sideways edge P3 will flag.
//
// Dependency-free. ESM, node: builtins only. Reads P1 via runConcepts(); reads
// the real symbol graph + the on-disk test tree. Never hardcodes an expected
// number, exemplar, or role.

import { execFileSync } from "node:child_process";
import { readFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { runConcepts } from "./concepts.mjs";
import { conceptTokenRe, conceptTokenMatchers } from "./concept-tokens.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE })
  .toString()
  .trim();

const SYMBOLS_PATH = join(ROOT, "tooling/symbol-graph/symbols.json");
const PLUGINS_DIR = join(ROOT, "api/lib/barkpark/plugins");
const TEST_DIR = join(ROOT, "api/test");

// ── exemplar-selection thresholds (computed-against, documented) ─────────────
// An exemplar must be a genuine CLEAN-FEATURE — the band (from P1's coupling
// classifier) already encodes cohesion ≥ the feature gate, low Ca, AND a plugin
// registration surface. We gate on the BAND, not a hand-tuned Ca/cohesion pair:
// the old EXEMPLAR_CA_MAX=25 was set just below media's Ca (~28), so when the
// media-storage extraction dropped media's Ca to 25, a tangled `mixed` concept
// slipped in. The band moves with the math; a magic number doesn't.
// EXEMPLAR_CA_MAX / EXEMPLAR_COH_MIN are retained for reference/back-compat only.
export const EXEMPLAR_CA_MAX = 25; // (superseded by the CLEAN-FEATURE band gate)
export const EXEMPLAR_COH_MIN = 0.7; // (superseded by the CLEAN-FEATURE band gate)
export const MIN_CLEAN_EXEMPLARS = 2; // below this, use the curated fallback (sheets+onixedit are the repo's two genuine clean features)
export const MAX_EXEMPLARS = 5; // cap on how many exemplars feed the skeleton

// The repo's registration convention — the recurring wiring call. cqv8 LOOKS for
// it (it is the discriminator that proves a concept is a real, pluggable
// feature); it never assumes a concept has it. These are the @callback names the
// Barkpark.Plugin behaviour declares.
const REGISTRATION_CALLS = ["register_schemas", "register_routes"];
const REGISTRATION_RE = new RegExp(
  "def\\s+(" + REGISTRATION_CALLS.join("|") + ")\\b"
);
const BEHAVIOUR_RE = /@behaviour\s+Barkpark\.Plugin|use\s+Barkpark\.Plugin/;

// ── role-marker vocabulary ───────────────────────────────────────────────────
// Each role is a canonical name plus a path matcher. Roles are detected off a
// concept's member file paths (engine/session/structure/live/controller/
// registry/reader/grid/worker/schema) — the recurring anatomy the spec lists.
// `core` and `registration` and `test` are structural roles handled separately.
const ROLE_MARKERS = [
  { role: "engine", re: /(^|[/_])engine([/_.]|$)/ },
  { role: "session", re: /(^|[/_])session([/_.]|$)/ },
  { role: "structure", re: /(^|[/_])structure([/_.]|$)/ },
  { role: "live", re: /_live([/_.]|$)|(^|\/)live\// },
  { role: "controller", re: /(^|[/_])controller([/_.]|$)|_controller\b/ },
  { role: "registry", re: /(^|[/_])regist(ry|er)([/_.]|$)/ },
  { role: "reader", re: /(^|[/_])reader([/_.]|$)/ },
  { role: "grid", re: /(^|[/_])grid([/_.]|$)/ },
  { role: "worker", re: /(^|[/_])worker([/_.]|$)/ },
  { role: "schema", re: /(^|[/_])schemas?([/_.]|$)/ },
];

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

// Reproduce the P1 two-pass concept assignment so anatomy speaks the same
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
  const tokenRe = conceptTokenMatchers(tokens);
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
  const filesOf = new Map();
  for (const n of graph.nodes) {
    const c = conceptOf.get(n.id);
    if (!c) continue;
    if (!filesOf.has(c)) filesOf.set(c, new Set());
    filesOf.get(c).add(n.file);
  }
  return { conceptOf, filesOf };
}

// ── registration-call detection ──────────────────────────────────────────────
// A concept carries the registration convention when its plugin entry file
// (api/lib/barkpark/plugins/<concept>.ex) defines the recurring wiring calls.
function registrationOf(concept) {
  const pf = join(PLUGINS_DIR, concept + ".ex");
  if (!existsSync(pf)) return null;
  const src = readFileSync(pf, "utf8");
  const calls = REGISTRATION_CALLS.filter((c) =>
    new RegExp("def\\s+" + c + "\\b").test(src)
  );
  if (calls.length === 0) return null;
  return {
    file: "api/lib/barkpark/plugins/" + concept + ".ex",
    calls,
    behaviour: BEHAVIOUR_RE.test(src) ? "Barkpark.Plugin" : null,
  };
}

// ── on-disk test-tree detection ──────────────────────────────────────────────
// Test files are NOT in the symbol graph, so the `test` role is read off the
// filesystem: any file under api/test whose path carries the concept token.
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

function testFilesForConcept(concept, allTestFiles) {
  const re = conceptTokenRe(concept);
  return allTestFiles.filter((f) => re.test(f.toLowerCase()));
}

// ── role detection for one exemplar ──────────────────────────────────────────
function rolesOfConcept(concept, files, registration, hasTests) {
  const roles = new Set();
  // structural roles always present for a real feature.
  roles.add("core");
  if (registration) roles.add("registration");
  if (hasTests) roles.add("test");
  // path-derived anatomy roles.
  for (const f of files) {
    const low = f.toLowerCase();
    for (const m of ROLE_MARKERS) {
      if (m.re.test(low)) roles.add(m.role);
    }
  }
  return roles;
}

// ── kernel-dep extraction for one exemplar ───────────────────────────────────
// Efferent targets of the concept whose concept lands in the KERNEL band.
function kernelDepsOfConcept(concept, conceptOf, edges, kernelSet) {
  const deps = new Set();
  for (const e of edges) {
    if (conceptOf.get(e.from) !== concept) continue;
    const ct = conceptOf.get(e.to);
    if (ct && ct !== concept && kernelSet.has(ct)) deps.add(ct);
  }
  return deps;
}

// ── the curated per-language fallback ────────────────────────────────────────
// Used only when the repo has fewer than MIN_CLEAN_EXEMPLARS clean exemplars.
// Marked explicitly so callers know the skeleton is not repo-grounded.
function curatedFallback() {
  return {
    exemplars: [],
    roles: [
      { role: "core", exemplars: 0, recurring: true },
      { role: "registration", exemplars: 0, recurring: true },
      { role: "test", exemplars: 0, recurring: true },
    ],
    registration: { file: null, calls: REGISTRATION_CALLS.slice(), behaviour: "Barkpark.Plugin" },
    allowedKernelDeps: ["content"],
    usedCuratedFallback: true,
  };
}

// ── public entrypoint ────────────────────────────────────────────────────────
export function runAnatomy() {
  const graph = loadGraph();
  const p1 = runConcepts();
  const kernelSet = new Set(p1.bands.kernel);
  const byName = new Map(p1.concepts.map((c) => [c.concept, c]));

  const { conceptOf, filesOf } = assignConcepts(graph);
  const allTestFiles = existsSync(TEST_DIR) ? listTestFiles(TEST_DIR) : [];

  // ── step 1: pick exemplars ──────────────────────────────────────────────
  // candidate region of the gradient: non-kernel, non-noise, low Ca, cohesive,
  // AND carrying the registration convention (a real pluggable feature).
  const candidates = [];
  for (const c of p1.concepts) {
    // Gate on the CLEAN-FEATURE band (clean-by-coupling AND registered) — not a
    // hand-tuned Ca/cohesion pair. This robustly excludes tangled `mixed`
    // concepts like media (Ce-heavy) regardless of where their Ca happens to sit.
    if (c.band !== "CLEAN-FEATURE") continue;
    const registration = registrationOf(c.concept);
    if (!registration) continue; // CLEAN-FEATURE implies registered; keep as a guard
    const files = filesOf.get(c.concept) || new Set();
    const testFiles = testFilesForConcept(c.concept, allTestFiles);
    const roles = rolesOfConcept(c.concept, files, registration, testFiles.length > 0);
    candidates.push({
      concept: c.concept,
      cohesion: c.cohesion,
      ca: c.ca,
      ce: c.ce,
      band: c.band,
      fileCount: files.size,
      testFileCount: testFiles.length,
      registration,
      roles, // Set
      roleCount: roles.size,
      kernelDeps: kernelDepsOfConcept(c.concept, conceptOf, graph.edges, kernelSet), // Set
    });
  }

  // richest anatomy first (most roles to learn from), then most cohesive.
  candidates.sort(
    (a, b) => b.roleCount - a.roleCount || b.cohesion - a.cohesion || a.ca - b.ca
  );

  if (candidates.length < MIN_CLEAN_EXEMPLARS) {
    return {
      builtAt: new Date().toISOString(),
      graph: { nodes: graph.nodes.length, edges: graph.edges.length },
      candidateCount: candidates.length,
      ...curatedFallback(),
    };
  }

  const exemplars = candidates.slice(0, MAX_EXEMPLARS);

  // ── step 2: extract the shared skeleton ─────────────────────────────────
  // roles[] — union with per-role exemplar counts. recurring = shown by ≥2.
  const roleCounts = new Map();
  for (const ex of exemplars) {
    for (const r of ex.roles) roleCounts.set(r, (roleCounts.get(r) || 0) + 1);
  }
  // stable, meaningful ordering: structural roles first, then by frequency.
  const STRUCTURAL_ORDER = ["core", "registration", "test"];
  const roleEntries = [...roleCounts.entries()].map(([role, n]) => ({
    role,
    exemplars: n,
    recurring: n >= 2,
  }));
  roleEntries.sort((a, b) => {
    const sa = STRUCTURAL_ORDER.indexOf(a.role);
    const sb = STRUCTURAL_ORDER.indexOf(b.role);
    if (sa !== -1 || sb !== -1) {
      if (sa === -1) return 1;
      if (sb === -1) return -1;
      return sa - sb;
    }
    return b.exemplars - a.exemplars || a.role.localeCompare(b.role);
  });

  // registration — the recurring call shape (calls present in EVERY exemplar).
  let regCalls = null;
  for (const ex of exemplars) {
    const c = new Set(ex.registration.calls);
    regCalls = regCalls === null ? c : new Set([...regCalls].filter((x) => c.has(x)));
  }
  const registration = {
    behaviour: exemplars.every((e) => e.registration.behaviour)
      ? "Barkpark.Plugin"
      : null,
    calls: [...(regCalls || new Set())].sort(),
  };

  // allowedKernelDeps — INTERSECTION of each exemplar's kernel deps.
  let allowed = null;
  for (const ex of exemplars) {
    allowed = allowed === null ? new Set(ex.kernelDeps) : new Set([...allowed].filter((x) => ex.kernelDeps.has(x)));
  }
  const allowedKernelDeps = [...(allowed || new Set())].sort();

  return {
    builtAt: new Date().toISOString(),
    graph: { nodes: graph.nodes.length, edges: graph.edges.length },
    candidateCount: candidates.length,
    exemplars: exemplars.map((e) => ({
      concept: e.concept,
      cohesion: e.cohesion,
      ca: e.ca,
      ce: e.ce,
      band: e.band,
      fileCount: e.fileCount,
      testFileCount: e.testFileCount,
      roles: [...e.roles].sort(),
      kernelDeps: [...e.kernelDeps].sort(),
    })),
    roles: roleEntries,
    registration,
    allowedKernelDeps,
    usedCuratedFallback: false,
  };
}

// ── human output ─────────────────────────────────────────────────────────────
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
  out(`cqv8 P2 — anatomy-learner\n`);
  out(`${res.graph.nodes} nodes · ${res.graph.edges} edges · ${res.candidateCount} candidate exemplars\n`);
  if (res.usedCuratedFallback) out(`⚠ curated fallback in use — fewer than ${MIN_CLEAN_EXEMPLARS} clean exemplars\n`);
  out(`${bar}\n\n`);

  out(`EXEMPLARS  (richest anatomy first)\n`);
  out(`  ${pad("concept", 14)}${padL("coh", 6)}${padL("Ca", 5)}${padL("files", 7)}${padL("tests", 7)}  roles\n`);
  out(`  ${"-".repeat(78)}\n`);
  for (const e of res.exemplars) {
    out(
      `  ${pad(e.concept, 14)}${padL(e.cohesion.toFixed(2), 6)}${padL(e.ca, 5)}` +
        `${padL(e.fileCount, 7)}${padL(e.testFileCount, 7)}  ${e.roles.join(" · ")}\n`
    );
  }
  if (res.exemplars.length === 0) out(`  (none — using curated fallback)\n`);

  out(`\nSKELETON\n`);
  out(`  roles (recurring marked ◆):\n`);
  for (const r of res.roles) {
    out(`    ${r.recurring ? "◆" : "·"} ${pad(r.role, 14)} ${r.exemplars} exemplar(s)\n`);
  }
  out(`\n  registration: ${res.registration.calls.join(" + ") || "(none)"}`);
  if (res.registration.behaviour) out(`   [@behaviour ${res.registration.behaviour}]`);
  out(`\n  allowedKernelDeps: ${res.allowedKernelDeps.join(", ") || "(none)"}\n`);
  out(`\n${bar}\n`);
}

// ── CLI ──────────────────────────────────────────────────────────────────────
function main() {
  const argv = process.argv.slice(2);
  const res = runAnatomy();
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
