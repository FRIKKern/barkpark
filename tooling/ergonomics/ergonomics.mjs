#!/usr/bin/env node
// Agent-ergonomics pass — the refactor axis. Two opposing costs (calls vs bloat);
// for this repo the data shows bloat dominates. Per file: size-class +
// refactor_worth = bloat-excess × read-frequency × separability, so god-modules
// that are read constantly rank above big-but-singular files (templates/generated).
//
//   ergonomics.mjs   → ergonomics-report.json + console summary   [free]
// Thresholds from the measured token distribution (median ~1k, p95 ~5.2k).

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE }).toString().trim();
const sig = JSON.parse(readFileSync(join(ROOT, "tooling/file-importance/file-signals.json"), "utf8")).signals;

const IDEAL_CEIL = 4000, BLOAT = 8000, FRAGMENT = 250;
const tokens = (t) => Math.ceil(t.length / 4);
const defCount = (f, t) => (t.match(f.endsWith(".go") ? /^func\s/gm : /\.exs?$/.test(f) ? /^\s*defp?\s/gm : /^\s*export\s+(async\s+)?(function|const|class|interface|type)\s|^(async\s+)?function\s|^class\s/gm) || []).length;
const sizeClass = (t) => t > BLOAT ? "bloat" : t > IDEAL_CEIL ? "large" : t < FRAGMENT ? "fragment" : "ideal";
// A behaviour-CONTRACT module (Elixir @callback-dominated) is not a decomposition
// target — its "bloat" is @callback specs + the contract moduledoc, not splittable
// logic. Flagged so the Modularity dimension can exclude it (e.g. Barkpark.Plugin).
const cbCount = (t) => (t.match(/^\s*@(macro)?callback\s/gm) || []).length;

const rows = sig.filter(s => s.kind === "code" || s.kind === "test").map(s => {
  let txt = ""; try { txt = readFileSync(join(ROOT, s.path), "utf8"); } catch {}
  const t = tokens(txt), d = Math.max(1, defCount(s.path, txt)), cb = cbCount(txt);
  const worth = Math.round(Math.max(0, t - IDEAL_CEIL) * Math.log2(1 + s.churn) * Math.min(1, d / 30));
  return { path: s.path, stack: s.stack, loc: s.loc, churn: s.churn, tokens: t, defs: d, callbacks: cb, contract: cb >= 3, sizeClass: sizeClass(t), refactorWorth: worth };
});

const cls = (c) => rows.filter(r => r.sizeClass === c).length;
const splitCandidates = rows.filter(r => r.refactorWorth > 0).sort((a, b) => b.refactorWorth - a.refactorWorth);
const report = {
  at: new Date().toISOString(),
  thresholds: { fragment: FRAGMENT, idealCeil: IDEAL_CEIL, bloat: BLOAT },
  summary: { files: rows.length, fragment: cls("fragment"), ideal: cls("ideal"), large: cls("large"), bloat: cls("bloat"),
    splitCandidates: splitCandidates.filter(r => r.refactorWorth > 5000).length },
  splitCandidates: splitCandidates.slice(0, 30),
  files: rows,
};
writeFileSync(join(HERE, "ergonomics-report.json"), JSON.stringify(report, null, 2));

const e = (s) => process.stderr.write(s + "\n");
e(`ergonomics  ${rows.length} code files · fragment ${cls("fragment")} · ideal ${cls("ideal")} · large ${cls("large")} · bloat ${cls("bloat")}`);
e(`  → top split candidates (refactor_worth = bloat × churn × separability):`);
for (const r of splitCandidates.slice(0, 10)) e(`    worth ${String(r.refactorWorth).padStart(7)}  ${String(r.tokens).padStart(6)}tok ${String(r.defs).padStart(3)}defs churn${String(r.churn).padStart(4)}  ${r.path}`);
e(`  → ergonomics-report.json`);
