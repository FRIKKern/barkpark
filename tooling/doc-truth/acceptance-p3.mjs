#!/usr/bin/env node
// acceptance-p3.mjs — the repeatable acceptance test for the P3 highways
// (routing resolution + canonical-for uniqueness + byte-budget reporting).
//
// Gating metrics (MUST PASS), mirroring P1/P2 acceptance output style:
//
//   1. RESOLUTION — every `Load` target in the root CLAUDE.md routing table
//      resolves to exactly one canonical owner doc in ≤2 hops. Assert non-null
//      resolution for each row; print `N/N resolved` and list any failures.
//      Exit non-zero if any routing row fails.
//
//   2. UNIQUENESS — no `canonical-for` topic has more than one owner doc.
//      Print any duplicates (should be 0). Exit non-zero on a duplicate.
//
// Informational (must RUN, never gates):
//
//   3. BUDGET — run the doc-budget gate; print over-budget docs + card count.
//      A pre-existing budget violation is reported, NOT failed here — the gate
//      for THIS acceptance is routing-resolution + uniqueness.
//
// Dependency-free. ESM, node: builtins only.

import { execFileSync } from "node:child_process";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { runHighways } from "./highways.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
// keep parity with the sibling acceptance scripts (resolve repo root)
execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE });

function main() {
  const res = runHighways();
  const bar = "═".repeat(78);
  const out = (s) => process.stdout.write(s);

  out(`\n${bar}\nDOC-TRUTH HIGHWAYS (P3) — ACCEPTANCE\n${bar}\n`);
  out(`routing rows parsed: ${res.routes.length}  ·  corpus: ${res.corpusSize} docs\n`);

  // ── METRIC 1 — RESOLUTION ──────────────────────────────────────────────────
  const resolved = res.routes.filter((r) => r.resolved);
  const failures = res.routes.filter((r) => !r.resolved);
  const resolutionPass = res.routes.length > 0 && failures.length === 0;

  out(`\nMETRIC 1 — RESOLUTION (must pass)\n`);
  out(`  every Load target resolves to one canonical owner in ≤2 hops\n`);
  out(`  ${resolved.length}/${res.routes.length} resolved\n`);
  for (const r of resolved) {
    out(`    ✓ [${r.group}] ${r.loadTarget} → ${r.canonicalOwner} (${r.hops} hop${r.hops === 1 ? "" : "s"})\n`);
  }
  for (const r of failures) {
    out(`    ✗ [${r.group}] ${r.loadTarget} — ${r.failure}\n`);
  }
  out(`  RESOLUTION: ${resolutionPass ? "PASS" : "FAIL"}\n`);

  // ── METRIC 2 — UNIQUENESS ──────────────────────────────────────────────────
  const uniquenessPass = res.duplicateOwners.length === 0;
  out(`\nMETRIC 2 — UNIQUENESS (must pass)\n`);
  out(`  no canonical-for topic owned by >1 doc\n`);
  out(`  duplicate owners: ${res.duplicateOwners.length}\n`);
  for (const d of res.duplicateOwners) {
    out(`    ✗ ${d.topic} owned by: ${d.owners.join(", ")}\n`);
  }
  if (res.orphans.length) {
    out(`  orphan topics (referenced, no owner): ${res.orphans.length}\n`);
    for (const o of res.orphans) out(`    · ${o.topic} — ${o.reason}\n`);
  }
  out(`  UNIQUENESS: ${uniquenessPass ? "PASS" : "FAIL"}\n`);

  // ── METRIC 3 — BUDGET (informational) ──────────────────────────────────────
  out(`\nMETRIC 3 — BUDGET + CARD-CAP (informational, must run)\n`);
  if (!res.budget.ran) {
    out(`  budget gate did not run: ${res.budget.note}\n`);
  } else {
    out(`  budget gate: ${res.budget.ok ? "PASS" : "FAIL"} (exit ${res.budget.exitCode})\n`);
    out(`  card count: ${res.budget.cardCount == null ? "?" : res.budget.cardCount} / 7 cap\n`);
    out(`  violations: ${res.budget.violations.length}\n`);
    for (const v of res.budget.violations) out(`    ✗ ${v}\n`);
  }

  // ── summary ────────────────────────────────────────────────────────────────
  const allPass = resolutionPass && uniquenessPass;
  out(`\n${bar}\nSUMMARY\n${bar}\n`);
  out(`  RESOLUTION:  ${resolutionPass ? "PASS ✓" : "FAIL ✗"}  (${resolved.length}/${res.routes.length} rows, ≤2 hops)\n`);
  out(`  UNIQUENESS:  ${uniquenessPass ? "PASS ✓" : "FAIL ✗"}  (${res.duplicateOwners.length} duplicate owner(s))\n`);
  out(`  BUDGET:      ${res.budget.ran ? (res.budget.ok ? "clean" : `${res.budget.violations.length} violation(s) [informational]`) : "did not run"}\n`);
  out(`${bar}\n`);

  process.exit(allPass ? 0 : 1);
}

main();
