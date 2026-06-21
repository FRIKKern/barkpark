#!/usr/bin/env node
// acceptance-p2.mjs — the repeatable acceptance test for the P2 waterfall
// (restatement detector + propose-only collapse).
//
// Two MUST-PASS metrics, mirroring P1's acceptance output style:
//
//   1. DETECTION — run the detector over the root CLAUDE.md and assert it finds
//      the Golden Rules ↔ Past Mistakes restatement cluster with a meaningful
//      shared-anchor count. Prints the shared factKeys. Exit non-zero if absent.
//
//   2. LOSE-NO-FACT — assert the proposed collapse preserves 100% of verifiable
//      claims: compute the factKey set of BOTH sections before, and the factKey
//      set of (canonical-section + non-shared-retained + pointer) after; assert
//      before ⊆ after. Print the count and any lost facts (must be 0).
//
// Dependency-free. ESM, node: builtins only.

import { execFileSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { runWaterfall } from "./waterfall.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE })
  .toString()
  .trim();

const TARGET = "CLAUDE.md";
const GR = "Golden Rules";
const PM = "Past Mistakes (NEVER REPEAT)";
// Conservative bar: the GR↔PM pair must surface with at least this many
// DISTINCTIVE shared anchors (generic top-dir prefixes excluded). The live
// detector finds 6; we assert ≥4 so the test tolerates minor doc edits.
const MIN_SHARED = 4;

function main() {
  // scope the detector to JUST the root CLAUDE.md (within-doc detection)
  const res = runWaterfall([TARGET]);

  // ── METRIC 1 — DETECTION ────────────────────────────────────────────────────
  const cluster = res.clusters.find((c) => {
    const pair = new Set([c.a.section, c.b.section]);
    return c.a.doc === TARGET && c.b.doc === TARGET && pair.has(GR) && pair.has(PM);
  });

  const detectionPass = !!cluster && cluster.sharedCount >= MIN_SHARED;

  const bar = "═".repeat(74);
  process.stdout.write(`\n${bar}\nDOC-TRUTH WATERFALL (P2) — ACCEPTANCE\n${bar}\n`);
  process.stdout.write(`target: ${TARGET}  ·  detector scoped to this doc\n`);
  process.stdout.write(`clusters found in target: ${res.clusters.length}\n`);

  process.stdout.write(`\nMETRIC 1 — DETECTION (must pass)\n`);
  process.stdout.write(`  looking for restatement cluster: "${GR}" ↔ "${PM}"\n`);
  if (cluster) {
    process.stdout.write(`  FOUND — ${cluster.sharedCount} distinctive shared anchors (jaccard ${cluster.jaccard})\n`);
    process.stdout.write(`  shared factKeys:\n`);
    for (const fk of cluster.sharedFactKeys) {
      process.stdout.write(`    · ${fk}\n`);
    }
    process.stdout.write(`  canonical home proposed: ${cluster.proposal.canonical.doc} » ${cluster.proposal.canonical.section}\n`);
    process.stdout.write(`  pointer into:            ${cluster.proposal.pointerInto.doc} » ${cluster.proposal.pointerInto.section}\n`);
    process.stdout.write(`  requiresOwnerSignoff:    ${cluster.proposal.requiresOwnerSignoff} (verbatim-exempt)\n`);
  } else {
    process.stdout.write(`  NOT FOUND — the GR↔PM restatement cluster was not detected.\n`);
  }
  process.stdout.write(`  DETECTION: ${detectionPass ? "PASS" : "FAIL"} (need ≥${MIN_SHARED} shared)\n`);

  // ── METRIC 2 — LOSE-NO-FACT ─────────────────────────────────────────────────
  process.stdout.write(`\nMETRIC 2 — LOSE-NO-FACT (must pass)\n`);
  let loseNoFactPass = false;
  if (cluster) {
    const ln = cluster.proposal.loseNoFact;
    loseNoFactPass = ln.ok && ln.lost.length === 0;
    process.stdout.write(`  facts present before collapse (union of both sections): ${ln.before}\n`);
    process.stdout.write(`  facts lost after collapse (canonical ∪ retained ∪ pointer): ${ln.lost.length}\n`);
    if (ln.lost.length) {
      for (const k of ln.lost) process.stdout.write(`    ✗ LOST: ${k}\n`);
    }
    process.stdout.write(`  LOSE-NO-FACT: ${loseNoFactPass ? "PASS" : "FAIL"} (0 facts may be lost)\n`);
  } else {
    process.stdout.write(`  skipped — no cluster to evaluate\n`);
    process.stdout.write(`  LOSE-NO-FACT: FAIL\n`);
  }

  // global invariant: NO emitted cluster anywhere may lose a fact
  const anyLost = res.clusters.filter((c) => !c.proposal.loseNoFact.ok);
  process.stdout.write(`\n  corpus-wide: emitted clusters that lose a fact (must be 0): ${anyLost.length}\n`);
  if (anyLost.length) loseNoFactPass = false;

  // ── summary ─────────────────────────────────────────────────────────────────
  const allPass = detectionPass && loseNoFactPass;
  process.stdout.write(`\n${bar}\nSUMMARY\n${bar}\n`);
  process.stdout.write(`  DETECTION:    ${detectionPass ? "PASS ✓" : "FAIL ✗"}` +
    (cluster ? `  (${cluster.sharedCount} shared anchors)` : ``) + `\n`);
  process.stdout.write(`  LOSE-NO-FACT: ${loseNoFactPass ? "PASS ✓" : "FAIL ✗"}` +
    (cluster ? `  (${cluster.proposal.loseNoFact.before} facts, 0 lost)` : ``) + `\n`);
  process.stdout.write(`  PROPOSE-ONLY: no doc was modified (detector never writes)\n`);
  process.stdout.write(`${bar}\n`);

  process.exit(allPass ? 0 : 1);
}

main();
