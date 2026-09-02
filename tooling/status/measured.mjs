// The absence-aware reads for tooling/status — "render absence as absence".
//
// WHY THIS FILE EXISTS. Every report the status board joins is DERIVED and
// gitignored: coverage-report.json, quality-report.json and friends exist only
// on a machine that has run the pass. Both readers used to default them to
// NUMBERS (`{ pct: 0, … }`, `{ overall: 0, totalFindings: 0 }`), so a clean
// checkout or a CI job rendered "coverage 0%" and "quality ? (0/100) · 0
// findings" as if something had measured them. That is the same silent zero
// coverage.mjs itself stopped printing in PR #14996: `scan` now REFUSES with
// LEDGER_ABSENT (exit 3) rather than publish a percentage computed against an
// instrument that is not here. This module carries that refusal one layer up,
// into the board that publishes the figure.
//
// The distinction that matters, and the reason a boolean is not enough:
//   report ABSENT (or present without the numeric field) → absence, rendered as
//     absence, together with the command that would make it a measurement.
//   report PRESENT with the value 0 → a REAL zero, rendered as "0%". A measured
//     zero is a measurement and must not be laundered into N/A either.

import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";

export const NOT_MEASURED = "N/A — not measured";
export const rerun = (cmd) => `${NOT_MEASURED}; run: ${cmd}`;

export const COVERAGE_REPORT = "tooling/research-coverage/coverage-report.json";
export const COVERAGE_RERUN = "node tooling/research-coverage/coverage.mjs scan";
export const COVERAGE_ABSENT_LABEL = rerun(COVERAGE_RERUN);

export const QUALITY_REPORT = "tooling/quality/quality-report.json";
export const QUALITY_RERUN = "node tooling/quality/quality.mjs";
export const QUALITY_ABSENT_LABEL = rerun(QUALITY_RERUN);

// Returns the parsed report, or null. NEVER a numeric default: a caller asking
// "what did this measure" must be able to tell "nothing measured it" from "it
// measured zero", and only null can carry the first answer.
export function readMeasuredReport(root, rel, field) {
  const p = join(root, rel);
  if (!existsSync(p)) return null;
  let parsed;
  try { parsed = JSON.parse(readFileSync(p, "utf8")); } catch { return null; }
  return measured(parsed, field) ? parsed : null;
}

export const measured = (rep, field) =>
  rep != null && typeof rep === "object" && typeof rep[field] === "number" && Number.isFinite(rep[field]);

// ─────────────────────────────── research coverage ───────────────────────────
export const readCoverageReport = (root) => readMeasuredReport(root, COVERAGE_REPORT, "pct");
export const coverageMeasured = (cov) => measured(cov, "pct");

// "74.6%" | "0%" (a real zero) | the absence label carrying the re-run command.
export const coverageLabel = (cov) => (coverageMeasured(cov) ? `${cov.pct}%` : COVERAGE_ABSENT_LABEL);

// How many files still need research. Only a present report knows; absent →
// null (UNKNOWN), never 0 — a 0 here prints the board "✓ fresh" on a checkout
// where nothing was ever scanned.
export const coveragePending = (cov) => (coverageMeasured(cov) ? (cov.stale || 0) + (cov.new || 0) : null);

export const lastFullResearchLabel = (cov) =>
  coverageMeasured(cov) ? (cov.lastFullResearch ? String(cov.lastFullResearch).slice(0, 10) : "—") : NOT_MEASURED;

// ────────────────────────────────── quality ──────────────────────────────────
// Same disease, same shape: `{ grade: "?", overall: 0, totalFindings: 0 }` made
// an unrun assessment read as a hard-earned zero.
export const readQualityReport = (root) => readMeasuredReport(root, QUALITY_REPORT, "overall");
export const qualityMeasured = (q) => measured(q, "overall");

// "B+ (81/100)" | "F (0/100)" (a real zero) | the absence label.
export const qualityLabel = (q) => (qualityMeasured(q) ? `${q.grade ?? "?"} (${q.overall}/100)` : QUALITY_ABSENT_LABEL);
export const findingsLabel = (q) =>
  qualityMeasured(q) && typeof q.totalFindings === "number" ? `${q.totalFindings} findings` : `findings ${NOT_MEASURED}`;

// The shape the board iterates over. Empty collections are honest for an absent
// report (an empty table renders as an empty table); only the NUMBERS lie.
export const qualityOrEmpty = (q) =>
  q || { grade: "?", overall: null, dimensions: [], findings: [], totalFindings: null, effortUnits: 0, composites: { config: {}, worklists: {} } };
