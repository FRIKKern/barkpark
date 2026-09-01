#!/usr/bin/env node
// metric-currency.mjs — guard against hand-coded live metrics drifting in prose.
//
// The truth-audit's #1 honest limit: docs that pin LIVE-COMPUTED numbers (the
// README Cody grade, per-critic scores) silently re-drift every commit. The
// audit fixed 83→81 once; without a guard it rots again. This compares the
// README grade table — overall, per-critic scores, AND the "N-critic" count
// claim — against the live `quality-report.json` and reports any drift.
// Default is REPORT-ONLY (a lead generator) — exits non-zero on drift so a
// standing loop / CI surfaces it. `--fix` re-syncs the README grade table
// (critic scores, overall /100, grade letter, N-critic count) FROM the live
// report — the audit's durable fix: regenerate the metric, don't hand-maintain
// it. Run it after a recompute and the grade can never silently rot.
//
//   node tooling/doc-truth/metric-currency.mjs [--json] [--fix]
//
// SKIPs cleanly (exit 0) when quality-report.json is absent (gitignored,
// regenerate via `node tooling/status/status.mjs`). Dependency-free, node: only.

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE })
  .toString().trim();
const REPORT = join(ROOT, "tooling/quality/quality-report.json");
const README = join(ROOT, "README.md");
const JSON_OUT = process.argv.includes("--json");
const FIX = process.argv.includes("--fix");

if (!existsSync(REPORT)) {
  const msg = "metric-currency: quality-report.json absent — run `node tooling/status/status.mjs` first. SKIP.";
  if (JSON_OUT) console.log(JSON.stringify({ status: "skip", reason: "no-report" }));
  else console.log(msg);
  process.exit(0); // pipe-exit-ok: top-level early SKIP, one short line, no `return` at module scope
}

const report = JSON.parse(readFileSync(REPORT, "utf8"));
// Normalize critic names so "Dead-code" (README) ≡ "Dead code" (report).
const norm = (s) => s.toLowerCase().replace(/[-\s]/g, "");
const live = {}; // normalized critic name -> { score, label }
for (const k of Object.keys(report.dimensions || {})) {
  const d = report.dimensions[k];
  if (d && d.name && typeof d.score === "number") live[norm(d.name)] = { score: d.score, label: d.name };
}
const liveOverall = report.overall;

const md = readFileSync(README, "utf8");
// scope to the "## Codebase grade" section only
const start = md.indexOf("## Codebase grade");
if (start < 0) {
  if (JSON_OUT) console.log(JSON.stringify({ status: "skip", reason: "no-grade-section" }));
  else console.log("metric-currency: README has no '## Codebase grade' section. SKIP.");
  process.exit(0); // pipe-exit-ok: top-level early SKIP, one short line, no `return` at module scope
}
const rest = md.indexOf("\n## ", start + 10);
const section = md.slice(start, rest < 0 ? md.length : rest);

const drift = [];

// per-critic cells: `Name | 85` / `**Name** | **64**`, restricted to known critics
const cellRe = /\*{0,2}([A-Z][A-Za-z-]+)\*{0,2}\s*\|\s*\*{0,2}(\d{1,3})\*{0,2}/g;
const seen = new Set();
let m;
while ((m = cellRe.exec(section))) {
  const key = norm(m[1]);
  if (!(key in live) || seen.has(key)) continue;
  seen.add(key);
  const readme = Number(m[2]);
  if (readme !== live[key].score) drift.push({ kind: "critic", name: live[key].label, mdName: m[1], readme, live: live[key].score });
}

// overall grade: every `NN / 100` in the section must equal liveOverall
for (const om of section.matchAll(/(\d{2,3})\s*\/\s*100/g)) {
  const v = Number(om[1]);
  if (v !== liveOverall) {
    drift.push({ kind: "overall", readme: v, live: liveOverall });
    break; // one report is enough
  }
}

// critic/dimension COUNT claims ("13-critic suite", "13-dimension scorecard") —
// the exact drift the audit fixed once (9 → 13). Same live source: # of dimensions.
const liveCount = Object.keys(live).length;
for (const cm of section.matchAll(/(\d+)[\s-](?:critic|dimension)/gi)) {
  const v = Number(cm[1]);
  if (v !== liveCount) { drift.push({ kind: "count", readme: v, live: liveCount, what: cm[0].trim() }); break; }
}

const missing = Object.keys(live).filter((n) => !seen.has(n)).map((n) => live[n].label);

// ── --fix: regenerate the grade-section numbers from the live report ─────────
if (FIX) {
  if (!drift.length) {
    console.log("metric-currency --fix: already FRESH — nothing to sync.");
    process.exit(0); // pipe-exit-ok: --fix path, one short line, never the piped report
  }
  const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  let fixed = section;
  for (const d of drift) {
    if (d.kind === "critic") {
      fixed = fixed.replace(
        new RegExp(`(\\*{0,2}${esc(d.mdName)}\\*{0,2}\\s*\\|\\s*\\*{0,2})${d.readme}(\\*{0,2})`),
        `$1${d.live}$2`);
    } else if (d.kind === "overall") {
      fixed = fixed.replace(new RegExp(`\\b${d.readme}(\\s*/\\s*100)`, "g"), `${d.live}$1`);
    } else if (d.kind === "count") {
      fixed = fixed.replace(new RegExp(`\\b${d.readme}([\\s-](?:critic|dimension))`, "gi"), `${d.live}$1`);
    }
  }
  // grade letter in the heading "— B+ ·" and "(B+)" → report.grade
  const lm = fixed.match(/## Codebase grade — ([A-F][+-]?) ·/);
  if (lm && report.grade && lm[1] !== report.grade) {
    fixed = fixed.split(`— ${lm[1]} ·`).join(`— ${report.grade} ·`).split(`(${lm[1]})`).join(`(${report.grade})`);
  }
  writeFileSync(README, md.slice(0, start) + fixed + md.slice(rest < 0 ? md.length : rest));
  console.log(`metric-currency --fix: synced ${drift.length} number(s) in the README grade section to the live report. Re-check budgets before committing.`);
  process.exit(0); // pipe-exit-ok: --fix path, one short line, never the piped report
}

if (JSON_OUT) {
  console.log(JSON.stringify({ status: drift.length ? "drift" : "fresh", drift, missingFromReadme: missing, liveOverall }, null, 2));
} else {
  console.log(`metric-currency — README grade vs live quality-report.json (computed ${report.at || "?"})`);
  if (!drift.length) {
    console.log(`  ✓ FRESH — overall ${liveOverall} and all ${seen.size} critic scores match.`);
  } else {
    console.log(`  ✗ DRIFT — ${drift.length} stale number(s):`);
    for (const d of drift) {
      if (d.kind === "overall") console.log(`    overall: README ${d.readme} → live ${d.live}`);
      else if (d.kind === "count") console.log(`    critic count ("${d.what}"): README ${d.readme} → live ${d.live}`);
      else console.log(`    ${d.name}: README ${d.readme} → live ${d.live}`);
    }
    console.log(`  Fix: run with --fix to regenerate the grade table from the live report (then re-check budgets).`);
  }
  if (missing.length) console.log(`  (note: ${missing.length} live critic(s) not found in the README table: ${missing.join(", ")})`);
}

// exitCode, never exit(): this is the last statement and it follows the
// whole report going into a `| tee` pipe. node exits on its own once
// stdout has drained, which exit() would not wait for.
process.exitCode = drift.length ? 1 : 0;
