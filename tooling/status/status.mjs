#!/usr/bin/env node
// Status Quo — the single entry point for the comprehensive quality report.
// Runs the whole PROGRAMMATIC chain (free), reports freshness, and always
// regenerates the full report from whatever verdicts currently exist (cached +
// fresh). Idempotent: run it → it says FRESH or lists pending agent work; do the
// agent work → run it again → FRESH. When the codebase hasn't moved, it spends
// ZERO agent tokens and still emits the most up-to-date full assessment.

import { execFileSync } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE }).toString().trim();
const rd = (p, d) => existsSync(join(ROOT, p)) ? JSON.parse(readFileSync(join(ROOT, p), "utf8")) : d;
const txt = (p, d) => existsSync(join(ROOT, p)) ? readFileSync(join(ROOT, p), "utf8").trim() : d;
const C = process.stderr.isTTY ? { y: "\x1b[33m", r: "\x1b[31m", g: "\x1b[32m", b: "\x1b[1m", x: "\x1b[0m" } : { y: "", r: "", g: "", b: "", x: "" };
const e = (s = "") => process.stderr.write(s + "\n");

function run(label, rel, args = []) {
  try { execFileSync("node", [join(ROOT, rel), ...args], { cwd: ROOT, stdio: ["ignore", "ignore", "ignore"], maxBuffer: 256 * 1024 * 1024 }); }
  catch (err) { e(`  ${C.y}· ${label} skipped: ${String(err.message).split("\n")[0]}${C.x}`); }
}

e(`${C.b}status-quo${C.x}  running the programmatic chain (free)…`);
run("blast-index", "tooling/blast-radius/build-index.mjs", ["--skip-elixir"]);
run("signals", "tooling/file-importance/build-signals.mjs", ["10"]);
run("ergonomics", "tooling/ergonomics/ergonomics.mjs");
run("risk", "tooling/risk/risk.mjs");
run("consistency", "tooling/consistency/consistency.mjs", ["scan"]);
run("coverage", "tooling/research-coverage/coverage.mjs", ["scan"]);
run("consistency-batches", "tooling/consistency/consistency.mjs", ["batches"]); // computes stale vs cached

// ---- freshness ----
const cov = rd("tooling/research-coverage/coverage-report.json", { pct: 0, stale: 0, new: 0, lastFullResearch: null });
const covPending = (cov.stale || 0) + (cov.new || 0);
const staleGroups = +txt("tooling/consistency/batch-count.txt", "0");
const issuesStale = txt("tooling/consistency/issues-stale.txt", "0") === "1";
const pending = covPending > 0 || staleGroups > 0 || issuesStale;

// ---- always regenerate the comprehensive report from current verdicts ----
run("consistency-merge", "tooling/consistency/consistency.mjs", ["merge"]);
run("combined", "tooling/combined/combine.mjs");
run("quality", "tooling/quality/quality.mjs");
const q = rd("tooling/quality/quality-report.json", { grade: "?", overall: 0, dimensions: [], totalFindings: 0 });

// ---- report ----
e("");
e(`${C.b}═══ STATUS QUO ═══${C.x}`);
e(`  research coverage : ${cov.pct}%  (last full research ${cov.lastFullResearch || "—"})`);
e(`  quality           : ${C.b}${q.grade} (${q.overall}/100)${C.x} · ${q.totalFindings} findings`);
for (const d of q.dimensions) e(`      ${d.name.padEnd(12)} ${String(d.score).padStart(3)}`);
e("");
if (!pending) {
  e(`  ${C.g}✓ FRESH — every axis current, report regenerated from cache. 0 agent tokens.${C.x}`);
  e(`  → open tooling/quality/quality-report.html`);
} else {
  e(`  ${C.y}⟳ PENDING agent work to reach full freshness:${C.x}`);
  if (covPending > 0) e(`     • ${covPending} file(s) need research  → coverage.mjs batches → dispatch → coverage.mjs record`);
  if (staleGroups > 0) e(`     • ${staleGroups} consistency group(s) changed → dispatch consistency/batches/*.json → consistency.mjs record`);
  if (issuesStale) e(`     • layering/dup findings changed → dispatch the 2 issue agents → consistency.mjs record`);
  e(`  ${C.y}(the report above reflects current cached verdicts; re-run status after the agent work for full freshness)${C.x}`);
}
