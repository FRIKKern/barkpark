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

// ── SAFETY CLASSIFIER — risk-awareness over the god-module split ranking ──────
// A PURE, DETERMINISTIC fn of (path, churn, contract). It encodes the SAME safety
// judgment the 5 done splits (#219–223) followed: test files + CLI/dev tools are
// safe to split (behaviour-preserving, zero/low prod risk); live prod-API + high-
// churn needs care; @callback-contract modules must not be split at all. It is the
// ORDERING + annotation layer only — it never touches the bloat/Modularity SCORE.
//
//   contract  — @callback-dominated (cb>=3, e.g. plugin.ex). DO NOT split: the
//               "bloat" is spec + contract moduledoc, not splittable logic.
//   test      — under a test tree (/test/, /spec/, __smoke, *_test.exs|.ex|.go,
//               *.test.mjs|.ts|.tsx, *.spec.*). SAFE: a test-file split is
//               behaviour-preserving with ZERO prod risk (#219 __smoke, #223 studio).
//   cli-tool  — a CLI / dev-tool path NOT on the served request path: cmd/,
//               internal/cli, api_tester, tooling/, bin/, scripts/ (#220 ApiTester
//               .Endpoints, #222 tui.go). LOW risk — a bug here never hits prod users.
//   prod      — everything else: live application code (api/lib serving path, web/
//               prod components, js/ published src). CARE — a behaviour-preserving
//               facade split is possible but carries real regression risk on the
//               running system; do only with explicit intent + the full test gate.
//
// CHURN OVERLAY (orthogonal to category): churn > 30 = "actively-changing, conflict
// risk" — so high-churn prod code (onixedit.ex churn-47) reads "prod · high-churn".
// CRUX: a prod module is NEVER labelled safe; a test file is NEVER labelled prod.
// Exported (pure, dependency-free) so the unit test can ground-truth it directly.
export const CHURN_HOT = 30;
export const isTestPath = (p) =>
  /(^|\/)(test|tests|spec)\//.test(p) ||
  /__smoke/.test(p) ||
  /(_test\.(exs?|go)|\.test\.(mjs|cjs|js|ts|tsx)|\.spec\.[a-z]+)$/.test(p);
export const isCliToolPath = (p) =>
  // `cmd/` only when it holds a Go main (Go's cmd/ convention) — so a hypothetical
  // prod module under e.g. api/lib/.../cmd/ stays `prod`, not mislabelled cli-tool.
  /(^|\/)cmd\/.*\.go$/.test(p) ||
  /(^|\/)internal\/cli(\/|$)/.test(p) ||
  /(^|\/)api_tester(\/|$|\.)/.test(p) ||
  /(^|\/)tooling\//.test(p) ||
  /(^|\/)bin\//.test(p) ||
  /(^|\/)scripts\//.test(p);
export function classifySafety(path, churn, contract) {
  const churnTag = churn > CHURN_HOT ? " · high-churn — conflict risk" : "";
  if (contract) return { safety: "contract", safetyNote: "@callback contract — do NOT split (spec, not splittable logic)" };
  if (isTestPath(path)) return { safety: "test", safetyNote: `SAFE — test-file split is behaviour-preserving, zero prod risk${churnTag}` };
  if (isCliToolPath(path)) return { safety: "cli-tool", safetyNote: `low risk — CLI/dev tool off the served request path${churnTag}` };
  return { safety: "prod", safetyNote: `CARE — live prod code; behaviour-preserving facade split only, full test gate${churnTag}` };
}

// A small per-safety ORDERING multiplier (NOT a score input): for equal refactor-
// worth, a safe split should surface above a risky one in the plan. Bounded ±, the
// Modularity dimension SCORE never reads this.
export const SAFETY_RANK_MULT = { test: 1.15, "cli-tool": 1.10, prod: 1.0, contract: 1.0 };

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
  const { safety, safetyNote } = classifySafety(s.path, s.churn, cb >= 3);
  return { path: s.path, stack: s.stack, loc: s.loc, churn: s.churn, tokens: t, defs: d, callbacks: cb, contract: cb >= 3, sizeClass: sizeClass(t), refactorWorth: worth, safety, safetyNote };
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
e(`  → top split candidates (refactor_worth = bloat × churn × separability · safety = risk of splitting):`);
const safTag = (r) => `[${r.safety}${r.churn > CHURN_HOT ? "·hot" : ""}]`;
for (const r of splitCandidates.slice(0, 10)) e(`    worth ${String(r.refactorWorth).padStart(7)}  ${String(r.tokens).padStart(6)}tok ${String(r.defs).padStart(3)}defs churn${String(r.churn).padStart(4)}  ${safTag(r).padEnd(14)} ${r.path}`);
e(`  → ergonomics-report.json`);
