// Pins: an ABSENT derived report renders as absence, never as a number.
//
// Two halves, because the defect had two halves. The BEHAVIOUR tests pin what
// tooling/status/measured.mjs answers when a derived report is missing; the
// SOURCE tests pin that the two readers actually ask it, so that restoring the
// old `{ pct: 0, … }` / `{ overall: 0, … }` default at either call site reds
// this file instead of silently reintroducing the zero one layer above the
// scanner that already refuses to print it (coverage.mjs LEDGER_ABSENT, #14996).

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

import {
  readCoverageReport, coverageMeasured, coverageLabel, coveragePending, lastFullResearchLabel,
  readQualityReport, qualityMeasured, qualityLabel, findingsLabel, qualityOrEmpty,
  COVERAGE_REPORT, COVERAGE_RERUN, QUALITY_REPORT, QUALITY_RERUN, NOT_MEASURED,
} from "../measured.mjs";

const STATUS_DIR = join(dirname(fileURLToPath(import.meta.url)), "..");
const src = (f) => readFileSync(join(STATUS_DIR, f), "utf8");
const READERS = ["status.mjs", "report.mjs"];
const PCT = /\d+(\.\d+)?%/;

// A throwaway ROOT holding (or deliberately not holding) a report.
function withRoot(files, fn) {
  const root = mkdtempSync(join(tmpdir(), "bp-status-absence-"));
  try {
    for (const [rel, body] of Object.entries(files)) {
      mkdirSync(join(root, dirname(rel)), { recursive: true });
      writeFileSync(join(root, rel), typeof body === "string" ? body : JSON.stringify(body));
    }
    return fn(root);
  } finally { rmSync(root, { recursive: true, force: true }); }
}

// ───────────────────────── coverage: absence is absence ──────────────────────
test("absent coverage report reads as null, not as a zero-valued report", () => {
  withRoot({}, (root) => {
    assert.equal(readCoverageReport(root), null);
    assert.equal(coverageMeasured(readCoverageReport(root)), false);
  });
});

test("absent coverage renders N/A with the re-run command, never 0%", () => {
  withRoot({}, (root) => {
    const label = coverageLabel(readCoverageReport(root));
    assert.match(label, /^N\/A\b/, `absent coverage must render as N/A, got: ${label}`);
    assert.ok(label.includes(COVERAGE_RERUN), `absent coverage must name the re-run command, got: ${label}`);
    assert.equal(COVERAGE_RERUN, "node tooling/research-coverage/coverage.mjs scan");
    assert.doesNotMatch(label, PCT, `absent coverage must render NO percentage, got: ${label}`);
  });
});

test("absent coverage leaves pending UNKNOWN (null), not 0", () => {
  withRoot({}, (root) => {
    // A 0 here would let the board print "✓ fresh" on a checkout that never scanned.
    assert.equal(coveragePending(readCoverageReport(root)), null);
    assert.equal(lastFullResearchLabel(readCoverageReport(root)), NOT_MEASURED);
  });
});

// ──────────────────── coverage: a measured zero IS a measurement ─────────────
test("coverage report with pct 0 renders 0% — a real zero is not laundered into N/A", () => {
  withRoot({ [COVERAGE_REPORT]: { pct: 0, stale: 0, new: 0, lastFullResearch: null } }, (root) => {
    const cov = readCoverageReport(root);
    assert.equal(coverageMeasured(cov), true);
    assert.equal(coverageLabel(cov), "0%");
    assert.equal(coveragePending(cov), 0);
  });
});

test("present coverage report renders its measured percentage and pending count", () => {
  withRoot({ [COVERAGE_REPORT]: { pct: 74.6, stale: 3, new: 4, lastFullResearch: "2026-06-26T10:00:00Z" } }, (root) => {
    const cov = readCoverageReport(root);
    assert.equal(coverageLabel(cov), "74.6%");
    assert.equal(coveragePending(cov), 7);
    assert.equal(lastFullResearchLabel(cov), "2026-06-26");
  });
});

test("present-but-unusable coverage report (no numeric pct / malformed JSON) is absence, not 0%", () => {
  for (const bad of [{ stale: 2 }, { pct: null }, { pct: "74.6" }, "{not json"]) {
    withRoot({ [COVERAGE_REPORT]: bad }, (root) => {
      assert.equal(readCoverageReport(root), null, `expected absence for ${JSON.stringify(bad)}`);
      assert.doesNotMatch(coverageLabel(readCoverageReport(root)), PCT);
    });
  }
});

// ───────────────────── quality: the same disease, same shape ─────────────────
test("absent quality report renders N/A with its re-run command, never 0/100 · 0 findings", () => {
  withRoot({}, (root) => {
    const q = readQualityReport(root);
    assert.equal(q, null);
    assert.equal(qualityMeasured(q), false);
    assert.match(qualityLabel(q), /^N\/A\b/);
    assert.ok(qualityLabel(q).includes(QUALITY_RERUN));
    assert.doesNotMatch(qualityLabel(q), /\d+\/100/, "an unrun assessment must not render a score");
    assert.equal(findingsLabel(q), `findings ${NOT_MEASURED}`);
    // The collections stay empty — an empty table is honest; only the numbers lied.
    const shape = qualityOrEmpty(q);
    assert.deepEqual(shape.dimensions, []);
    assert.equal(shape.overall, null);
    assert.equal(shape.totalFindings, null);
  });
});

test("quality report with overall 0 renders 0/100 — a real zero is a measurement", () => {
  withRoot({ [QUALITY_REPORT]: { grade: "F", overall: 0, dimensions: [], totalFindings: 0 } }, (root) => {
    const q = readQualityReport(root);
    assert.equal(qualityMeasured(q), true);
    assert.equal(qualityLabel(q), "F (0/100)");
    assert.equal(findingsLabel(q), "0 findings");
  });
});

test("present quality report renders its measured grade and findings", () => {
  withRoot({ [QUALITY_REPORT]: { grade: "B+", overall: 81, dimensions: [{ name: "Tested", score: 90 }], totalFindings: 12 } }, (root) => {
    const q = readQualityReport(root);
    assert.equal(qualityLabel(q), "B+ (81/100)");
    assert.equal(findingsLabel(q), "12 findings");
    assert.equal(qualityOrEmpty(q).dimensions.length, 1);
  });
});

// ───────────── source: the readers must ASK, not default to a number ─────────
// This is the half that reds when a `{ pct: 0, … }` / `{ overall: 0, … }`
// default is restored at a call site. Without it, such a mutation would leave
// the helper's own tests green while the board printed 0% again.
for (const f of READERS) {
  test(`${f} never defaults a measured report to a value`, () => {
    const s = src(f);
    for (const [rel, reader] of [[COVERAGE_REPORT, "readCoverageReport"], [QUALITY_REPORT, "readQualityReport"]]) {
      const bad = new RegExp(`${rel.replace(/[./]/g, "\\$&")}"\\s*,`);
      assert.doesNotMatch(s, bad, `${f} passes a default alongside ${rel} — an absent report would render as that default`);
      assert.ok(s.includes(`${reader}(ROOT)`), `${f} must read ${rel} through measured.mjs (${reader})`);
    }
    for (const dead of [/\bcov\.pct\b/, /\$\{q\.overall\}/, /\$\{q\.totalFindings\}/]) {
      assert.doesNotMatch(s, dead, `${f} interpolates a raw measurement (${dead}) — use the label helpers`);
    }
    assert.match(s, /coverageLabel\(cov\)/, `${f} must render coverage through coverageLabel`);
    assert.match(s, /qualityLabel\(qRep\)/, `${f} must render the grade through qualityLabel`);
    assert.match(s, /findingsLabel\(qRep\)/, `${f} must render the finding count through findingsLabel`);
  });
}

test("status.mjs treats an unmeasured report as pending, never as fresh", () => {
  const s = src("status.mjs");
  assert.match(s, /const covMissing = !coverageMeasured\(cov\)/);
  assert.match(s, /allFresh = qualityMeasured\(qRep\) && !covMissing/,
    "an unmeasured coverage or quality report must keep the board out of FRESH");
});
