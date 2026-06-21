#!/usr/bin/env node
// acceptance.mjs — the repeatable acceptance test for the doc-truth verifier.
//
// Two metrics:
//   1. RECALL  — of the human-graded audit's real findings (falseAll+staleAll),
//      how many does the verifier reproduce? Match on (doc basename, category).
//      Reported honestly; NOT a hard gate (the audit was 22 LLM agents reading
//      prose — the verifier only catches the mechanical subset).
//   2. THE GATE (MUST PASS) — the verifier must NOT emit a false/stale finding
//      for `.github/workflows/js-tests.yml`, which exists on disk. This is the
//      never-worse guarantee the one-time audit lacked. Exit non-zero on fail.
//
// Dependency-free. ESM, node: builtins only.

import { execFileSync } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import { dirname, join, basename } from "node:path";
import { fileURLToPath } from "node:url";
import { runVerify } from "./verify-docs.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE })
  .toString()
  .trim();

const FINDINGS = join(HERE, "fixtures/audit-2026-06-21-findings.json");
const CORPUS = join(HERE, "fixtures/audit-2026-06-21-corpus.json");
const GATE_PATH = ".github/workflows/js-tests.yml";

// The audit classifies findings into "false" (factually wrong) and "stale"
// (drifted line numbers / counts). The verifier emits the same two categories.
// We match a verifier finding to an audit finding when they agree on the doc
// basename AND the category. Basename-level (not full-path) because the audit
// fixture sometimes records absolute paths, sometimes repo-relative.
function corpusDocs() {
  const c = JSON.parse(readFileSync(CORPUS, "utf8"));
  const all = [...(c.ctx || []), ...(c.batches || []).flat()];
  const present = [], skipped = [];
  for (const d of all) {
    if (existsSync(join(ROOT, d))) present.push(d);
    else skipped.push(d);
  }
  return { present, skipped };
}

function main() {
  const audit = JSON.parse(readFileSync(FINDINGS, "utf8"));
  const { present, skipped } = corpusDocs();
  const report = runVerify(present);

  // Build the verifier's emitted (doc-basename, category) multiset.
  // We count both findings (high-conf) AND the human queue toward recall — a
  // low-confidence lead on the right doc+category still "reproduces" the
  // mechanical signal the audit found. The GATE is separate and strict.
  const verifierHits = new Map(); // "basename|category" -> count
  const allLeads = [];
  for (const d of report.docs) {
    for (const f of [...d.findings, ...d.humanQueue]) {
      allLeads.push(f);
      const key = `${basename(f.doc)}|${f.status}`;
      verifierHits.set(key, (verifierHits.get(key) || 0) + 1);
    }
  }
  // Allow a 'false' verifier hit to satisfy a 'stale' audit finding on the same
  // doc and vice versa? No — keep categories strict, but track a doc-level
  // any-category fallback for the honest secondary number.
  const verifierDocAny = new Set(allLeads.map((f) => basename(f.doc)));

  function recallFor(list, category) {
    let strict = 0, docLevel = 0;
    const missed = [];
    for (const a of list) {
      const base = basename(a.file);
      const key = `${base}|${category}`;
      const consumed = (verifierHits.get(key) || 0) > 0;
      if (consumed) {
        strict++;
        verifierHits.set(key, verifierHits.get(key) - 1); // consume one
      } else {
        missed.push(`${base}: ${trunc(a.claim, 60)}`);
      }
      if (verifierDocAny.has(base)) docLevel++;
    }
    return { strict, docLevel, total: list.length, missed };
  }

  const falseR = recallFor(audit.falseAll, "false");
  // reset consumption tracking for stale (separate category space)
  const staleR = recallFor(audit.staleAll, "stale");

  const totalReal = audit.falseAll.length + audit.staleAll.length;
  const reproduced = falseR.strict + staleR.strict;
  const pct = ((reproduced / totalReal) * 100).toFixed(1);

  // ── THE GATE ───────────────────────────────────────────────────────────────
  const gateExists = existsSync(join(ROOT, GATE_PATH));
  const gateFindings = [];
  for (const d of report.docs) {
    for (const f of [...d.findings, ...d.humanQueue]) {
      if (f.raw && f.raw.includes("js-tests.yml") &&
          (f.status === "false" || f.status === "stale")) {
        gateFindings.push(f);
      }
    }
  }
  const gatePass = gateExists && gateFindings.length === 0;

  // ── report ───────────────────────────────────────────────────────────────
  const bar = "═".repeat(74);
  process.stdout.write(`\n${bar}\nDOC-TRUTH VERIFIER — ACCEPTANCE\n${bar}\n`);
  process.stdout.write(`corpus: ${present.length} docs verified` +
    (skipped.length ? `, ${skipped.length} skipped (off disk)\n` : `\n`));

  process.stdout.write(`\nMETRIC 1 — RECALL (mechanical subset of an LLM-graded audit)\n`);
  process.stdout.write(`  reproduced ${reproduced}/${totalReal} (${pct}%)\n`);
  process.stdout.write(`    false:  ${falseR.strict}/${falseR.total} same-category` +
    `  ·  ${falseR.docLevel}/${falseR.total} same-doc (any category)\n`);
  process.stdout.write(`    stale:  ${staleR.strict}/${staleR.total} same-category` +
    `  ·  ${staleR.docLevel}/${staleR.total} same-doc (any category)\n`);

  process.stdout.write(`\nMETRIC 2 — THE GATE (must pass)\n`);
  process.stdout.write(`  ${GATE_PATH} exists on disk: ${gateExists ? "yes" : "NO"}\n`);
  process.stdout.write(`  verifier false/stale findings on it: ${gateFindings.length}\n`);
  if (gateFindings.length) {
    for (const f of gateFindings) {
      process.stdout.write(`    ✗ ${f.doc} L${f.line} [${f.status}] ${f.evidence}\n`);
    }
  }
  process.stdout.write(`  GATE: ${gatePass ? "PASS" : "FAIL"}\n`);

  process.stdout.write(`\n${bar}\nSUMMARY\n${bar}\n`);
  process.stdout.write(
    `  recall ${reproduced}/${totalReal} (${pct}%)  ·  false ${falseR.strict}/${falseR.total}  ·  stale ${staleR.strict}/${staleR.total}\n`);
  process.stdout.write(`  GATE: ${gatePass ? "PASS ✓" : "FAIL ✗"}\n`);
  process.stdout.write(
    `  emitted findings (high-conf): ${report.docs.reduce((a, d) => a + d.findings.length, 0)}` +
    `  ·  human queue (low-conf): ${report.humanQueue.length}\n`);
  process.stdout.write(`${bar}\n`);

  process.exit(gatePass ? 0 : 1);
}

function trunc(s, n) { return (s || "").length > n ? s.slice(0, n - 1) + "…" : (s || ""); }

main();
