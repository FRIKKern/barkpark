#!/usr/bin/env node
// priority.mjs — documentation proportioned by reach (cqv7 Phase 4).
//
// Joins doc COVERAGE against code REACH / IMPORTANCE / CHURN and emits a ranked
// work queue: high-reach code that's under-documented, and trivia that's
// over-documented. The point is to spend doc effort where a change ripples
// furthest — not uniformly across the tree.
//
//   node tooling/doc-truth/priority.mjs            → readable ranked report
//   node tooling/doc-truth/priority.mjs --json     → structured queue + overDocumented + buildSpec
//
// Signals — all from prebuilt artifacts, none invented:
//   • COVERAGE — invert tooling/doc-truth/doc-refs.json: file → [covering docs].
//                A code file referenced by 0 docs is uncovered.
//   • REACH    — the AUTHORITATIVE blast-radius signal. For each candidate file
//                we run tooling/map/what-breaks.mjs --json and take
//                verdict.closureSize (transitive dependents) + verdict.surfaceReach
//                (user-facing points reached). file-signals.json (self.reach /
//                fanIn) is a secondary importance signal. A file NOT in the
//                symbol graph has reach: null (unknown) — never guessed.
//   • CHURN    — cochange-report.json (cochangePartners) + file-signals churn.
//
// Candidate set: the 335 elixir source files that appear as NODES in
// tooling/symbol-graph/symbols.json. That is exactly the set for which
// what-breaks can compute a real file-level reverse closure — so every reach
// number is grounded, never a proxy. (JS/Go reach is module-grained and noisier;
// we keep the candidate set to the file-exact elixir graph for honesty.)
//
// Dependency-free. ESM, node: builtins only.

import { execFileSync } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE })
  .toString()
  .trim();

const DOC_REFS = join(ROOT, "tooling/doc-truth/doc-refs.json");
const SYMBOLS = join(ROOT, "tooling/symbol-graph/symbols.json");
const SIGNALS = join(ROOT, "tooling/file-importance/file-signals.json");
const COCHANGE = join(ROOT, "tooling/cochange/cochange-report.json");
const WHAT_BREAKS = join(ROOT, "tooling/map/what-breaks.mjs");

const readJson = (p) => JSON.parse(readFileSync(p, "utf8"));

// ── (a) coverage: invert doc-refs.json → file → [covering docs] ──────────────
// doc-refs.json = { refs: { <doc> → [referenced files/dirs/docs] } }. A code
// file is "covered" by a doc if the doc references it directly OR references a
// directory that contains it (e.g. a card referencing `api/lib/...` covers files
// beneath it loosely). We record both: exact refs and prefix refs, but only
// EXACT/prefix file references count toward a code file's coverage.
function buildCoverage() {
  const refs = readJson(DOC_REFS).refs || {};
  const byFile = new Map(); // file → Set<doc>
  const dirRefs = []; // [{doc, dir}] for prefix coverage

  const docExt = /\.(md|mdx)$/;
  const add = (file, doc) => {
    if (!byFile.has(file)) byFile.set(file, new Set());
    byFile.get(file).add(doc);
  };

  for (const [doc, targets] of Object.entries(refs)) {
    for (const t of targets) {
      // Only join CODE coverage: skip refs that are themselves docs.
      if (docExt.test(t)) continue;
      const clean = t.replace(/\/+$/, "");
      const abs = join(ROOT, clean);
      // A ref with a file extension → exact file coverage.
      if (/\.[A-Za-z0-9]+$/.test(clean) && existsSync(abs)) {
        add(clean, doc);
      } else if (existsSync(abs)) {
        // A directory ref → loose prefix coverage for files beneath it.
        dirRefs.push({ doc, dir: clean });
      }
    }
  }
  return { byFile, dirRefs };
}

// Resolve a candidate file's covering docs: exact refs + any doc that references
// an ancestor directory of the file. Directory coverage is marked "loose".
function coverageFor(file, coverage) {
  const exact = coverage.byFile.has(file) ? [...coverage.byFile.get(file)] : [];
  const loose = [];
  for (const { doc, dir } of coverage.dirRefs) {
    if (file === dir || file.startsWith(dir + "/")) {
      if (!exact.includes(doc) && !loose.includes(doc)) loose.push(doc);
    }
  }
  return { exact, loose, count: exact.length + loose.length, hasExact: exact.length > 0 };
}

// ── (b) candidate set: elixir files in the symbol graph ──────────────────────
function candidateFiles() {
  const sym = readJson(SYMBOLS);
  const files = new Set();
  for (const n of sym.nodes || []) {
    if (n && n.file && (n.file.endsWith(".ex") || n.file.endsWith(".exs"))) {
      files.add(n.file);
    }
  }
  return [...files].sort();
}

// ── (c) churn + importance overlays ──────────────────────────────────────────
function loadChurn() {
  const out = new Map(); // file → { cochangePartners, commitChurn }
  if (existsSync(COCHANGE)) {
    const c = readJson(COCHANGE);
    for (const [f, v] of Object.entries(c.files || {})) {
      out.set(f, { cochangePartners: v.cochangePartners || 0, commitChurn: null });
    }
  }
  if (existsSync(SIGNALS)) {
    const s = readJson(SIGNALS);
    for (const sig of s.signals || []) {
      const prev = out.get(sig.path) || { cochangePartners: 0, commitChurn: null };
      prev.commitChurn = typeof sig.churn === "number" ? sig.churn : null;
      prev.fanIn = typeof sig.fanIn === "number" ? sig.fanIn : null;
      prev.selfReach = null; // filled per-file from what-breaks self.reach
      out.set(sig.path, prev);
    }
  }
  return out;
}

// ── (d) reach via what-breaks (the authoritative blast-radius signal) ────────
// One shell-out per candidate file. We cap concurrency to 1 (sequential) but
// only over the candidate set (≈335), and each call reads prebuilt artifacts —
// no rebuild. Returns { reach, closureSize, surfaceReach, selfReach } or null
// when the file isn't resolvable in the graph (reach unknown — never guessed).
function reachFor(file) {
  let out;
  try {
    out = execFileSync("node", [WHAT_BREAKS, file, "--json"], {
      cwd: ROOT,
      maxBuffer: 64 * 1024 * 1024,
    }).toString();
  } catch {
    return null;
  }
  let j;
  try { j = JSON.parse(out); } catch { return null; }
  if (!j || !j.verdict) return null;
  const closureSize = j.verdict.closureSize || 0;
  const surfaceReach = j.verdict.surfaceReach || 0;
  const selfReach = j.self && typeof j.self.reach === "number" ? j.self.reach : null;
  // Composite reach: transitive dependents dominate, surface points amplify.
  // Both come straight from what-breaks; this is just a join, not a new metric.
  const reach = closureSize + surfaceReach * 2;
  return { reach, closureSize, surfaceReach, selfReach, score: j.verdict.score || 0 };
}

// ── (e) build-spec anchor ────────────────────────────────────────────────────
// cqv6 specced a canonical "how to build here" doc but it was never built. For
// barkpark the docs serving that role today are SETUP, PROD_OPS, and the build
// invariants in root CLAUDE.md. We name the canonical one, check whether the
// top-reach seam files are covered by it, and flag the dedicated-build-spec gap.
function buildSpecAnchor(ranked, coverage) {
  // Candidate build docs, in priority order. The first that exists is canonical.
  const candidates = [
    "docs/setup/SETUP.md",
    "docs/ops/PROD_OPS.md",
    "CLAUDE.md",
  ];
  const dedicated = "docs/build-spec.md"; // the cqv6 doc that was specced, not built
  const dedicatedExists = existsSync(join(ROOT, dedicated));

  let doc = null;
  for (const c of candidates) {
    if (existsSync(join(ROOT, c))) { doc = c; break; }
  }

  // Which high-reach seam files does the canonical build doc actually cover?
  // Take the top-decile reach files; check whether `doc` references each.
  const withReach = ranked.filter((r) => r.reach !== null);
  const topN = Math.max(1, Math.ceil(withReach.length * 0.1));
  const topReach = withReach.slice(0, topN);
  const referencedByDoc = (file) => {
    const cov = coverageFor(file, coverage);
    return cov.exact.includes(doc) || cov.loose.includes(doc);
  };
  const uncoveredSeams = topReach
    .filter((r) => !referencedByDoc(r.file))
    .map((r) => ({ file: r.file, reach: r.reach }));

  return {
    doc,
    exists: !!doc,
    dedicated,
    dedicatedExists,
    gap: !dedicatedExists, // no dedicated build-spec file exists → gap true
    note: dedicatedExists
      ? `dedicated build-spec present at ${dedicated}`
      : `no dedicated build-spec exists; "${doc}" is the de-facto canonical "how to build here" doc (cqv6 specced one but it was never built).`,
    topReachChecked: topReach.length,
    topReachUncoveredByBuildDoc: uncoveredSeams.slice(0, 15),
  };
}

// ── (f) scoring + verdicts ───────────────────────────────────────────────────
function classify(rows) {
  const withReach = rows.filter((r) => r.reach !== null).map((r) => r.reach).sort((a, b) => a - b);
  if (withReach.length === 0) return { p90: 0, p10: 0 };
  const pct = (arr, p) => arr[Math.min(arr.length - 1, Math.floor(arr.length * p))];
  return { p90: pct(withReach, 0.9), p10: pct(withReach, 0.1) };
}

// A file is "over-documented" when at least this many docs name it EXACTLY yet
// nothing depends on it (closure 0) and its reach sits at/below p10. In this
// repo even files named by 2 docs all turn out high-reach, so the honest bar is
// 1 exact reference + zero dependents — a leaf a doc bothered to name that no
// code reaches (e.g. a mix task). Raise to tighten.
const MIN_OVERDOC_COVERAGE = 1;

export function runPriority() {
  const coverage = buildCoverage();
  const candidates = candidateFiles();
  const churn = loadChurn();

  const rows = [];
  for (const file of candidates) {
    const r = reachFor(file);
    const cov = coverageFor(file, coverage);
    const ch = churn.get(file) || {};
    rows.push({
      file,
      reach: r ? r.reach : null,
      closureSize: r ? r.closureSize : null,
      surfaceReach: r ? r.surfaceReach : null,
      selfReach: r ? r.selfReach : null,
      // Coverage that COUNTS for verdicts is EXACT, file-level references only.
      // A card referencing the `api/` directory does not document content.ex —
      // loose directory coverage is kept informationally but never reads as
      // "documented" for the under/over verdict (that was the trap: every file
      // under api/ inherited spurious coverage from cards naming the dir).
      coverage: cov.exact.length,
      looseCoverage: cov.loose.length,
      coveringDocs: cov.exact,
      looseDocs: cov.loose,
      hasExactCoverage: cov.hasExact,
      commitChurn: ch.commitChurn ?? null,
      cochangePartners: ch.cochangePartners ?? null,
    });
  }

  // rank by reach desc (unknown reach sinks to the bottom)
  rows.sort((a, b) => (b.reach ?? -1) - (a.reach ?? -1) || a.file.localeCompare(b.file));

  const { p90, p10 } = classify(rows);

  // verdicts
  for (const r of rows) {
    if (r.reach === null) { r.verdict = "unknown-reach"; continue; }
    // Both verdicts key on EXACT, file-level coverage — a doc naming the file.
    // Loose directory coverage is informational only (it would falsely tag
    // every file under a card-referenced dir).
    if (r.reach >= p90 && r.coverage === 0) {
      // under-documented: high reach AND no doc names it.
      r.verdict = "under-documented";
    } else if (r.coverage >= MIN_OVERDOC_COVERAGE && (r.closureSize || 0) === 0 && r.reach <= p10) {
      // over-documented: explicitly named by ≥2 docs yet zero dependents —
      // doc attention disproportionate to blast radius.
      r.verdict = "over-documented";
    } else {
      r.verdict = "proportioned";
    }
  }

  // ── the ranked work queue ──────────────────────────────────────────────────
  const queue = rows
    .filter((r) => r.verdict === "under-documented")
    .map((r) => {
      // action: write-new if 0 covering docs; extend-canonical if a covering doc
      // exists but is thin. (under-documented means coverage 0 → always write-new
      // here, but we keep the branch so a low-coverage variant lands correctly if
      // the percentile bar is loosened.)
      // write-new when no doc names the file at all; extend-canonical when a
      // doc already loosely covers it (references its directory) — that doc is
      // the natural home for an explicit mention.
      let action, target;
      if (r.coverage > 0) {
        action = "extend-canonical";
        target = r.coveringDocs[0];
      } else if ((r.looseDocs || []).length > 0) {
        action = "extend-canonical";
        target = r.looseDocs[0];
      } else {
        action = "write-new";
        target = null;
      }
      return {
        file: r.file,
        reach: r.reach,
        closureSize: r.closureSize,
        surfaceReach: r.surfaceReach,
        coverage: r.coverage,
        looseCoverage: r.looseCoverage,
        commitChurn: r.commitChurn,
        cochangePartners: r.cochangePartners,
        action,
        target,
      };
    });

  const overDocumented = rows
    .filter((r) => r.verdict === "over-documented")
    .map((r) => ({
      file: r.file,
      reach: r.reach,
      closureSize: r.closureSize,
      coverage: r.coverage,
      coveringDocs: r.coveringDocs,
    }));

  const buildSpec = buildSpecAnchor(rows, coverage);

  return {
    candidateSet: {
      definition: "elixir source files present as nodes in tooling/symbol-graph/symbols.json (file-exact reverse closure available)",
      size: candidates.length,
      withReach: rows.filter((r) => r.reach !== null).length,
      unknownReach: rows.filter((r) => r.reach === null).length,
    },
    thresholds: { reachP90: p90, reachP10: p10 },
    queue,
    overDocumented,
    buildSpec,
  };
}

// ── reporting ────────────────────────────────────────────────────────────────
function printHuman(res) {
  const bar = "─".repeat(74);
  process.stdout.write(`\nDOC PRIORITY — documentation proportioned by reach (cqv7 P4)\n${bar}\n`);
  const cs = res.candidateSet;
  process.stdout.write(`candidate set: ${cs.size} files — ${cs.definition}\n`);
  process.stdout.write(`  reach known: ${cs.withReach} · reach unknown: ${cs.unknownReach}\n`);
  process.stdout.write(`reach thresholds: p90=${res.thresholds.reachP90} (under-doc bar) · p10=${res.thresholds.reachP10} (over-doc bar)\n`);

  process.stdout.write(`\n${bar}\nUNDER-DOCUMENTED WORK QUEUE — high reach, low/zero coverage (ranked by reach)\n${bar}\n`);
  if (res.queue.length === 0) {
    process.stdout.write(`  (none)\n`);
  }
  let i = 0;
  for (const q of res.queue) {
    i++;
    process.stdout.write(
      `${String(i).padStart(3)}. ${q.file}\n` +
      `     reach ${q.reach} (closure ${q.closureSize}, surface ${q.surfaceReach}) · coverage ${q.coverage}` +
      ` · churn ${q.commitChurn ?? "?"} · cochange ${q.cochangePartners ?? "?"}\n` +
      `     → ${q.action}${q.target ? ` ${q.target}` : ""}\n`);
  }

  process.stdout.write(`\n${bar}\nOVER-DOCUMENTED — substantial coverage, zero dependents\n${bar}\n`);
  if (res.overDocumented.length === 0) {
    process.stdout.write(`  (none)\n`);
  }
  for (const o of res.overDocumented) {
    process.stdout.write(
      `  ${o.file}  · coverage ${o.coverage} · reach ${o.reach}\n` +
      `     covered by: ${o.coveringDocs.join(", ")}\n`);
  }

  process.stdout.write(`\n${bar}\nBUILD-SPEC ANCHOR\n${bar}\n`);
  const b = res.buildSpec;
  process.stdout.write(`  canonical "how to build here" doc: ${b.doc || "(none found)"}\n`);
  process.stdout.write(`  dedicated build-spec (${b.dedicated}) exists: ${b.dedicatedExists} → gap: ${b.gap}\n`);
  process.stdout.write(`  ${b.note}\n`);
  process.stdout.write(`  top-reach seam files NOT covered by the build doc (${b.topReachUncoveredByBuildDoc.length} of top ${b.topReachChecked}):\n`);
  for (const u of b.topReachUncoveredByBuildDoc) {
    process.stdout.write(`    · ${u.file}  (reach ${u.reach})\n`);
  }
  process.stdout.write(`${bar}\n`);
}

// ── CLI ──────────────────────────────────────────────────────────────────────
function main() {
  const wantJson = process.argv.includes("--json");
  const res = runPriority();
  if (wantJson) {
    process.stdout.write(JSON.stringify(res, null, 2) + "\n");
  } else {
    printHuman(res);
  }
  process.exit(0);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  main();
}
