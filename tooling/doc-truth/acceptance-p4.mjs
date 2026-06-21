#!/usr/bin/env node
// acceptance-p4.mjs — repeatable acceptance for P4 (priority / docs-by-reach).
//
// Two checks, mirroring P1/P2's acceptance output style:
//
//   1. TOP-UNDER-DOCUMENTED IS GENUINELY HIGH-REACH (must pass) — take the #1
//      under-documented file the queue surfaces, INDEPENDENTLY re-fetch its
//      reach from what-breaks.mjs --json, and assert it sits in the top reach
//      tier (top-decile of the candidate set's reach distribution). This proves
//      the flag is grounded in real blast-radius, not a heuristic guess. Exit
//      non-zero if the top-flagged file is NOT actually high-reach.
//
//   2. BUILD-SPEC NAMED (must run) — assert the canonical "how to build here"
//      doc is identified, and print whether a dedicated build-spec gap exists.
//
// Dependency-free. ESM, node: builtins only.

import { execFileSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { runPriority } from "./priority.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE })
  .toString()
  .trim();

const WHAT_BREAKS = join(ROOT, "tooling/map/what-breaks.mjs");

// Independently re-fetch a file's reach from what-breaks — the same composite
// the scorer uses, but computed here from scratch so the test can't be fooled by
// a cached row inside priority.mjs.
function independentReach(file) {
  const out = execFileSync("node", [WHAT_BREAKS, file, "--json"], {
    cwd: ROOT,
    maxBuffer: 64 * 1024 * 1024,
  }).toString();
  const j = JSON.parse(out);
  const closureSize = j.verdict.closureSize || 0;
  const surfaceReach = j.verdict.surfaceReach || 0;
  return closureSize + surfaceReach * 2;
}

function main() {
  const res = runPriority();
  const bar = "═".repeat(74);
  process.stdout.write(`\n${bar}\nDOC-TRUTH PRIORITY (P4) — ACCEPTANCE\n${bar}\n`);
  process.stdout.write(`candidate set: ${res.candidateSet.size} files (${res.candidateSet.definition})\n`);
  process.stdout.write(`  reach known ${res.candidateSet.withReach} · unknown ${res.candidateSet.unknownReach}\n`);
  process.stdout.write(`reach thresholds: p90=${res.thresholds.reachP90} · p10=${res.thresholds.reachP10}\n`);
  process.stdout.write(`under-documented queue: ${res.queue.length} · over-documented: ${res.overDocumented.length}\n`);

  // ── CHECK 1 — TOP-UNDER-DOCUMENTED IS GENUINELY HIGH-REACH ──────────────────
  process.stdout.write(`\nCHECK 1 — TOP UNDER-DOCUMENTED IS GENUINELY HIGH-REACH (must pass)\n`);
  let check1Pass = false;
  let detail = "";
  if (res.queue.length === 0) {
    detail = "  queue is EMPTY — nothing to validate (scorer surfaced no under-documented file).";
    process.stdout.write(detail + "\n");
  } else {
    const top = res.queue[0];
    // Independently re-fetch reach — do NOT trust the queue's own number.
    const realReach = independentReach(top.file);

    // Top-decile cutoff: the published p90 over the whole candidate set's reach
    // distribution. realReach (re-fetched independently) must be ≥ p90 to count
    // as genuinely high-reach — not a heuristic the scorer could fake.
    const p90 = res.thresholds.reachP90;
    const inTopTier = realReach >= p90;

    // percentile of realReach among the under-documented queue (illustrative)
    const sorted = res.queue.map((q) => q.reach).sort((a, b) => a - b);
    const below = sorted.filter((r) => r <= realReach).length;
    const pctile = Math.round((below / sorted.length) * 100);

    check1Pass = inTopTier;
    process.stdout.write(`  #1 under-documented file: ${top.file}\n`);
    process.stdout.write(`  queue-reported reach:     ${top.reach}\n`);
    process.stdout.write(`  INDEPENDENT reach (what-breaks): ${realReach}` +
      `  (closure + 2×surface)\n`);
    process.stdout.write(`  top-decile cutoff (p90):  ${p90}\n`);
    process.stdout.write(`  realReach ≥ p90:          ${inTopTier} → ${realReach}${pctile ? `  (~${pctile}th pct within queue)` : ""}\n`);
    process.stdout.write(`  action: ${top.action}${top.target ? ` ${top.target}` : ""}\n`);
  }
  process.stdout.write(`  CHECK 1: ${check1Pass ? "PASS ✓" : "FAIL ✗"} (top flag must sit in real top-decile reach)\n`);

  // ── CHECK 2 — BUILD-SPEC NAMED ──────────────────────────────────────────────
  process.stdout.write(`\nCHECK 2 — BUILD-SPEC NAMED (must run)\n`);
  const b = res.buildSpec;
  const check2Pass = !!b.doc;
  process.stdout.write(`  canonical "how to build here" doc: ${b.doc || "(none)"}\n`);
  process.stdout.write(`  dedicated build-spec (${b.dedicated}) exists: ${b.dedicatedExists}\n`);
  process.stdout.write(`  dedicated-build-spec GAP: ${b.gap}\n`);
  process.stdout.write(`  ${b.note}\n`);
  process.stdout.write(`  top-reach seams uncovered by build doc: ${b.topReachUncoveredByBuildDoc.length} of top ${b.topReachChecked}\n`);
  process.stdout.write(`  CHECK 2: ${check2Pass ? "PASS ✓" : "FAIL ✗"} (a canonical build doc must be named)\n`);

  // ── over-documented sample (informational) ──────────────────────────────────
  if (res.overDocumented.length) {
    process.stdout.write(`\nOVER-DOCUMENTED (named by docs, zero dependents):\n`);
    for (const o of res.overDocumented.slice(0, 5)) {
      process.stdout.write(`  · ${o.file}  reach ${o.reach} · covered by ${o.coveringDocs.join(", ")}\n`);
    }
  }

  // ── summary ─────────────────────────────────────────────────────────────────
  const allPass = check1Pass && check2Pass;
  process.stdout.write(`\n${bar}\nSUMMARY\n${bar}\n`);
  process.stdout.write(`  TOP-FLAG GROUNDED:  ${check1Pass ? "PASS ✓" : "FAIL ✗"}` +
    (res.queue.length ? `  (${res.queue[0].file})` : ``) + `\n`);
  process.stdout.write(`  BUILD-SPEC NAMED:   ${check2Pass ? "PASS ✓" : "FAIL ✗"}` +
    `  (${b.doc || "none"}${b.gap ? ", dedicated gap" : ""})\n`);
  process.stdout.write(`${bar}\n`);

  process.exit(allPass ? 0 : 1);
}

main();
