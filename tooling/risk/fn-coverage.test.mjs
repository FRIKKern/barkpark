#!/usr/bin/env node
// Proof for the per-PUBLIC-fn coverage refinement of the Tested dimension.
//
//   node tooling/risk/fn-coverage.test.mjs   (or: node --test)
//
// PART A — parser unit: elixirFnCov() finds the fn BOUNDARY and the PUBLIC flag
//   straight from the cover HTML source column (def vs defp), so a 0%-covered
//   PUBLIC fn is isolated even though the file rolls up ~57%.
// PART B — integration: quality.mjs's finding assembly surfaces that 0%-fn in a
//   high-reach file to the TOP findings — the exact pane_builder / find_doc_path
//   masking bug turned into a regression tripwire.

import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, cpSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { elixirFnCov, jsFnCov } from "./fn-coverage.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE }).toString().trim();

// Build a synthetic cover-HTML row (class = hit|miss|"" for non-coverable).
const row = (n, cls, src) =>
  `<tr${cls ? ` class="${cls}"` : ""}>\n<td class="line" id="L${n}"><a href="#L${n}">${n}</a></td>\n<td class="hits">${cls === "hit" ? 1 : ""}</td>\n<td class="source"><code>${src}</code></td>\n</tr>`;

test("PART A — parser isolates the 0% PUBLIC fn; ignores defp", () => {
  const html = [
    row(1, "", "defmodule Demo do"),
    row(2, "hit", "  def covered_a do"),
    row(3, "hit", "    :ok"),
    row(4, "hit", "  def covered_b do"),
    row(5, "hit", "    :ok"),
    row(6, "miss", "  def find_doc_path(x) do"),
    row(7, "miss", "    nil"),
    row(8, "miss", "  end"),
    row(9, "miss", "  defp private_helper, do: :secret"),
  ].join("\n");

  const fns = elixirFnCov(html);
  const below = fns.filter((f) => f.pct < 50);

  // exactly one PUBLIC fn below cutoff — the all-miss find_doc_path
  assert.equal(below.length, 1, "exactly one public fn below the cutoff");
  const bad = below[0];
  assert.equal(bad.name, "find_doc_path");
  assert.equal(bad.pct, 0);
  assert.equal(bad.hit, 0);
  assert.ok(bad.miss >= 1, "find_doc_path has miss lines");
  assert.equal(bad.exported, true);

  // private_helper must be filtered (defp), even though it is all-miss
  assert.ok(!fns.some((f) => f.name === "private_helper"), "defp is never reported");

  // covered_a / covered_b are public 100% — present at 100 or absent, never < cutoff
  for (const nm of ["covered_a", "covered_b"]) {
    const f = fns.find((x) => x.name === nm);
    if (f) assert.equal(f.pct, 100, `${nm} rolls up 100%`);
  }
});

test("jsFnCov — drops anonymous callbacks, keeps named uncalled fns", () => {
  const data = {
    fnMap: {
      "0": { name: "listWorkspaces", decl: { start: { line: 10 }, end: { line: 14 } } },
      "1": { name: "fetchRaw", decl: { start: { line: 20 }, end: { line: 25 } } },
      "2": { name: "(anonymous_3)", decl: { start: { line: 30 }, end: { line: 31 } } },
      "3": { name: "", decl: { start: { line: 40 }, end: { line: 41 } } },
    },
    f: { "0": 5, "1": 0, "2": 0, "3": 0 },
  };
  const fns = jsFnCov(data);
  const names = fns.map((f) => f.name).sort();

  // anonymous / unnamed entries are never reported as a public fn
  assert.deepEqual(names, ["fetchRaw", "listWorkspaces"], "only named fns");
  // called → 100%, uncalled → 0%
  assert.equal(fns.find((f) => f.name === "listWorkspaces").pct, 100);
  assert.equal(fns.find((f) => f.name === "fetchRaw").pct, 0);
});

test("PART B — a 0%-public-fn in a reach-80 file ranks to the TOP findings", () => {
  // Throwaway ROOT with just the report fixtures quality.mjs reads. quality.mjs
  // resolves ROOT via `git rev-parse`, so the sandbox must be a git repo.
  const tmp = mkdtempSync(join(tmpdir(), "bp-fncov-"));
  const w = (rel, obj) => { mkdirSync(dirname(join(tmp, rel)), { recursive: true }); writeFileSync(join(tmp, rel), JSON.stringify(obj)); };
  try {
    execFileSync("git", ["init", "-q"], { cwd: tmp });
    // copy the real tooling scorer + its lib deps into the sandbox
    cpSync(join(ROOT, "tooling"), join(tmp, "tooling"), { recursive: true });

    // reach: hi_reach.ex = 80 (>=40 gate), lo_reach.ex = 5
    w("tooling/usefulness/usefulness-report.json", { files: {
      "api/lib/hi_reach.ex": { reach: 80, reachScore: 80 },
      "api/lib/lo_reach.ex": { reach: 5, reachScore: 5 },
    } });
    w("tooling/file-importance/file-signals.json", { signals: [
      { path: "api/lib/hi_reach.ex", kind: "code", churn: 3 },
      { path: "api/lib/lo_reach.ex", kind: "code", churn: 1 },
    ] });
    w("tooling/ergonomics/ergonomics-report.json", { files: [], splitCandidates: [], summary: {} });
    // the file % (testScore 70) MASKS the 0% public fn — untestedFns carries it
    w("tooling/risk/risk-report.json", { coverageTotals: {}, files: {
      "api/lib/hi_reach.ex": { testScore: 70, realCoverage: 70, hasTest: true, defectDensity: 0,
        untestedFns: [{ name: "find_doc_path", pct: 0, hit: 0, miss: 5 }] },
      "api/lib/lo_reach.ex": { testScore: 70, realCoverage: 70, hasTest: true, defectDensity: 0, untestedFns: [] },
    } });
    // neutralize the other generators quality.mjs reads (absent → benign defaults)
    w("tooling/fit/scoring-config.json", { confidence: "low", sparse: true, thresholds: {} });

    execFileSync("node", [join(tmp, "tooling/quality/quality.mjs")], { cwd: tmp, encoding: "utf8" });
    const rpt = JSON.parse(readFileSync(join(tmp, "tooling/quality/quality-report.json"), "utf8"));

    const fnFinding = rpt.findings.find((f) => f.file === "api/lib/hi_reach.ex" && f.dim === "Tested");
    assert.ok(fnFinding, "a Tested finding exists for the high-reach file");
    assert.match(fnFinding.action, /find_doc_path/, "the finding names the culprit fn");

    // it must OUT-RANK any plain file-level 70% untested finding — i.e. the 0%-fn
    // severity beat the 70% file rollup. (Here dedupe collapses them onto this one;
    // assert it sits in the surfaced top findings, driven by reach × ¬0%.)
    const rank = rpt.findings.findIndex((f) => f === fnFinding);
    assert.ok(rank >= 0 && rank < 40, `fn-driven Tested finding is in the top findings (rank ${rank})`);

    // sev came from the WORST fn (0% ⇒ 1.0), NOT the 70% file → impact ≈ reach×1
    assert.ok(fnFinding.impact >= 60, `impact driven by reach 80 × ¬0% (got ${fnFinding.impact})`);
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});
