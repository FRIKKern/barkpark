#!/usr/bin/env node
// Unit test for compare.mjs — the aesthetics regression diff. Pure Node, no deps,
// no test runner. Run: node tooling/aesthetics/compare.test.mjs (exit 0 = pass).
//
// Asserts the two contract points the CI guard relies on:
//   1. a HEAD report with ONE new root-clutter finding → flags exactly that finding
//      (and a Bloat drop), and NEVER flags the bp-dependent dead-task drift.
//   2. identical base/head reports → NO flag (a clean PR raises no alarm).

import { compareReports, renderMarkdown } from "./compare.mjs";

let failures = 0;
const ok = (cond, msg) => { if (!cond) { console.error("FAIL: " + msg); failures++; } else { console.log("pass: " + msg); } };

// ── fixtures ──────────────────────────────────────────────────────────────────
const baseClean = {
  bloat: {
    score: 96,
    findings: [
      // a deliberate typedef artifact (NOT structural-removable — has no `sample`)
      { kind: "tracked-artifact", path: "api/priv/plugin_types.d.ts", severity: 0.2, why: "standalone .d.ts" },
    ],
  },
  aesthetics: {
    score: 99,
    // dead-task is bp-dependent — must be ignored by the structural diff
    findings: [{ kind: "dead-task", path: "bp-task:(unscoped-open ×3)", severity: 0.32, why: "3 unscoped open tasks" }],
  },
};

// head INTRODUCES one new root-clutter finding + drops Bloat; dead-task count also
// changed (×3 → ×5) but that must NOT be flagged.
const headWithNewClutter = {
  bloat: {
    score: 88,
    findings: [
      { kind: "root-clutter", path: "(repo root)", severity: 0.5, why: "8 source files (8 .go) sit in the repo ROOT", sample: ["a.go", "b.go"] },
      { kind: "tracked-artifact", path: "api/priv/plugin_types.d.ts", severity: 0.2, why: "standalone .d.ts" },
    ],
  },
  aesthetics: {
    score: 99,
    findings: [{ kind: "dead-task", path: "bp-task:(unscoped-open ×5)", severity: 0.32, why: "5 unscoped open tasks" }],
  },
};

// head that adds a NEW file to an existing build-output roll-up (sample grows)
const baseWithBuildOutput = {
  bloat: { score: 90, findings: [{ kind: "tracked-artifact", path: "js/dist/index.js", severity: 0.3, why: "regenerable build output", sample: ["js/dist/index.js"] }] },
  aesthetics: { score: 99, findings: [] },
};
const headBuildOutputGrew = {
  bloat: { score: 88, findings: [{ kind: "tracked-artifact", path: "js/dist/index.js", severity: 0.4, why: "regenerable build output", sample: ["js/dist/index.js", "js/dist/extra.js"] }] },
  aesthetics: { score: 99, findings: [] },
};

// ── 1. new root-clutter → flagged, exactly one new finding, dead-task ignored ──
{
  const d = compareReports(baseClean, headWithNewClutter);
  ok(d.flagged === true, "new root-clutter flags the PR");
  ok(d.newFindings.length === 1, `exactly one new structural finding (got ${d.newFindings.length})`);
  ok(d.newFindings[0] && d.newFindings[0].kind === "root-clutter", "the new finding is root-clutter");
  ok(d.bloatDropped === true, "Bloat drop (96 → 88) is detected");
  ok(!d.newFindings.some((f) => f.kind === "dead-task"), "dead-task drift is NOT flagged (bp-dependent, excluded)");
  const md = renderMarkdown(d, headWithNewClutter);
  ok(md.includes("NEW root source clutter"), "markdown names the new root-clutter finding");
  ok(md.includes("| Bloat | 96 | 88 |"), "markdown scores table shows base vs head Bloat");
}

// ── 2. identical reports → no alarm ───────────────────────────────────────────
{
  const d = compareReports(baseClean, baseClean);
  ok(d.flagged === false, "identical reports raise NO flag (clean PR = no alarm)");
  ok(d.newFindings.length === 0, "identical reports yield zero new findings");
  const md = renderMarkdown(d, baseClean);
  ok(md.includes("No new structural mess"), "markdown shows the clean-PR verdict");
}

// ── 3. a build-output roll-up that grows → flags the newly-added sample path ───
{
  const d = compareReports(baseWithBuildOutput, headBuildOutputGrew);
  ok(d.flagged === true, "a grown build-output roll-up flags the PR");
  ok(d.newSamples.length === 1, `exactly one new sample path (got ${d.newSamples.length})`);
  ok(d.newSamples[0] && d.newSamples[0].path === "js/dist/extra.js", "the new sample path is the added build file");
  ok(d.newFindings.length === 0, "no new headline finding (the roll-up already existed)");
}

// ── 4. a NEW deliberate/typedef artifact (no `sample`) is NOT structural ───────
{
  const headNewTypedef = {
    bloat: { score: 96, findings: [
      { kind: "tracked-artifact", path: "api/priv/plugin_types.d.ts", severity: 0.2, why: "standalone .d.ts" },
      { kind: "tracked-artifact", path: "js/new.d.ts", severity: 0.12, why: "deliberate served bundle" },
    ] },
    aesthetics: { score: 99, findings: [] },
  };
  const d = compareReports(baseClean, headNewTypedef);
  ok(d.flagged === false, "a new deliberate/typedef artifact (no sample) is NOT flagged");
}

if (failures) { console.error(`\n${failures} assertion(s) failed.`); process.exit(1); }
console.log("\nAll compare.test.mjs assertions passed.");
