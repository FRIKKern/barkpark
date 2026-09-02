#!/usr/bin/env node
// Status Quo — single entry point for ALL THREE arcs (ASSESS · ENRICH · PUBLISH).
// Runs every PROGRAMMATIC step (free), reports the pending AGENT work per arc
// (the orchestrator dispatches it — a node script can't), and with --publish
// ships the codebase into Barkpark (gated on change). Idempotent; unchanged
// work costs zero tokens.
//
//   node tooling/status/status.mjs            # assess + enrich status, report pending
//   node tooling/status/status.mjs --publish  # also push into Barkpark if changed
//   node tooling/status/status.mjs --publish --force   # republish regardless

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { createHash } from "node:crypto";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { readCoverageReport, coverageMeasured, coverageLabel, coveragePending,
         readQualityReport, qualityMeasured, qualityLabel, findingsLabel, qualityOrEmpty } from "./measured.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE }).toString().trim();
const argv = process.argv.slice(2);
const PUBLISH = argv.includes("--publish"), FORCE = argv.includes("--force");
const rd = (p, d) => existsSync(join(ROOT, p)) ? JSON.parse(readFileSync(join(ROOT, p), "utf8")) : d;
const txt = (p, d) => existsSync(join(ROOT, p)) ? readFileSync(join(ROOT, p), "utf8").trim() : d;
const C = process.stderr.isTTY ? { y: "\x1b[33m", r: "\x1b[31m", g: "\x1b[32m", b: "\x1b[1m", x: "\x1b[0m" } : { y: "", r: "", g: "", b: "", x: "" };
const e = (s = "") => process.stderr.write(s + "\n");
function run(label, rel, args = []) {
  try { execFileSync("node", [join(ROOT, rel), ...args], { cwd: ROOT, stdio: ["ignore", "ignore", "ignore"], maxBuffer: 256 * 1024 * 1024 }); return true; }
  catch (err) { e(`  ${C.y}· ${label} skipped: ${String(err.message).split("\n")[0]}${C.x}`); return false; }
}

// ════════════════ ARC 1 — ASSESS (programmatic chain) ════════════════
e(`${C.b}status-quo${C.x}  running the programmatic chain (free)…`);
// Elixir edges come from `mix xref` (real module→module graph). It compiles (a few min)
// the first time; gated on api/_build existing inside build-index.mjs. Pass --skip-elixir
// to status.mjs to fall back to the regex resolver on machines without the Elixir toolchain.
run("blast-index", "tooling/blast-radius/build-index.mjs", argv.includes("--skip-elixir") ? ["--skip-elixir"] : []);
run("signals", "tooling/file-importance/build-signals.mjs", ["10"]);
run("ergonomics", "tooling/ergonomics/ergonomics.mjs");
run("risk", "tooling/risk/risk.mjs", argv.includes("--no-coverage") ? ["--no-coverage"] : []);
run("deps", "tooling/deps/deps.mjs");
run("consistency", "tooling/consistency/consistency.mjs", ["scan"]);
// aesthetics — the FILEBASE critic (Bloat + Aesthetics dims). Pure-Node,
// dependency-free, graceful bp-fallback → safe in the standard chain. Regenerates
// tooling/aesthetics/aesthetics-report.json so the filebase grade is part of every
// assessment, not a manual local run. (CI guards regressions via aesthetics-guard.yml.)
run("aesthetics", "tooling/aesthetics/aesthetics.mjs");
run("coverage", "tooling/research-coverage/coverage.mjs", ["scan"]);
run("consistency-batches", "tooling/consistency/consistency.mjs", ["batches"]);
// coverage-report.json is DERIVED and gitignored — absent on any clean checkout
// and in CI. Read as report-or-null, never defaulted to a number: the old
// { pct: 0, … } default printed "coverage 0%" as if a scan had produced it, the
// same silent zero coverage.mjs stopped printing (LEDGER_ABSENT, exit 3, #14996).
const cov = readCoverageReport(ROOT);
const covMissing = !coverageMeasured(cov);
const covPending = coveragePending(cov); // number, or null when nothing measured it
const staleGroups = +txt("tooling/consistency/batch-count.txt", "0");
const issuesStale = txt("tooling/consistency/issues-stale.txt", "0") === "1";
run("consistency-merge", "tooling/consistency/consistency.mjs", ["merge"]);
run("combined", "tooling/combined/combine.mjs");
run("quality", "tooling/quality/quality.mjs");
run("report", "tooling/status/report.mjs");
// Same disease, same file family: quality-report.json is derived + gitignored, and
// its old { overall: 0, totalFindings: 0 } default rendered an assessment that never
// ran as "0/100 · 0 findings". Empty collections stay (an empty table is honest);
// the numbers become N/A.
const qRep = readQualityReport(ROOT);
const q = qualityOrEmpty(qRep);

// ════════════════ ARC 2 — ENRICH (programmatic merges + assemble) ════════════════
run("usefulness-merge", "tooling/usefulness/usefulness.mjs", ["merge"]);
run("intentions-merge", "tooling/intentions/intentions.mjs", ["merge"]);
// co-change + 3-edge relationship cross-validation. Reads nodes.json (deps) +
// intentions-report (intent) + git history (co-change); generate re-runs after so
// the graph can carry the co-change edge kind. Best-effort: a skip never breaks the board.
run("cochange", "tooling/cochange/cochange.mjs");
run("generate", "tooling/barkpark-sync/generate.mjs");
const nodes = (rd("tooling/barkpark-sync/nodes.json", { nodes: [] }).nodes || []).filter(n => n.kind !== "intention");
const useFiles = rd("tooling/usefulness/usefulness-report.json", { files: {} }).files;
const intRep = rd("tooling/intentions/intentions-report.json", { files: {}, taxonomy: [] });
// reach is now PURE PROGRAMMATIC (computed by usefulness.mjs merge) — never an agent pass.
// Count files still missing a computed reach only as a freshness signal, not agent work.
const reachMissing = nodes.filter(n => !(n.path in useFiles) || useFiles[n.path].reach == null).length;
const taxonomyN = (intRep.taxonomy || []).length;
const intentPending = taxonomyN === 0 ? nodes.length : nodes.filter(n => !(n.path in intRep.files)).length;

// ════════════════ ARC 3 — PUBLISH (gated on change; --publish to run) ════════════════
const reachable = () => { try { return execFileSync("curl", ["-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "3", "http://localhost:4000/v1/capabilities"], { encoding: "utf8" }).trim().startsWith("2"); } catch { return false; } };
const up = reachable();
const nodesHash = existsSync(join(ROOT, "tooling/barkpark-sync/nodes.json")) ? createHash("sha256").update(readFileSync(join(ROOT, "tooling/barkpark-sync/nodes.json"))).digest("hex").slice(0, 16) : "";
const lastHash = txt("tooling/barkpark-sync/.last-push-hash", "");
const publishNeeded = nodesHash && nodesHash !== lastHash;
let published = false;
let pushFailed = false;
if (PUBLISH && up && (publishNeeded || FORCE)) {
  e(`  ${C.b}publishing to Barkpark (codebase dataset)…${C.x}`);
  // stamp + report success ONLY when push actually succeeded — a failed push must
  // leave the arc red and the hash unstamped so the next run retries it.
  if (run("push", "tooling/barkpark-sync/push.mjs", ["--dataset", "codebase"])) {
    run("graph-view", "tooling/barkpark-sync/graph-view.mjs", ["--dataset", "codebase"]);
    writeFileSync(join(ROOT, "tooling/barkpark-sync/.last-push-hash"), nodesHash);
    published = true;
  } else pushFailed = true;
}

// ════════════════ REPORT BOARD ════════════════
// reach is computed, not agent work → only intentions gate ENRICH freshness.
const enrichPending = intentPending > 0;
e("");
e(`${C.b}═══ STATUS QUO — three arcs (v2: reach·churn·complexity·defects·tests·conventions·ownership·relationships) ═══${C.x}`);
e("");
const cfgSrc = q.composites?.config?.source || "defaults";
e(`${C.b}ASSESS${C.x}   quality ${C.b}${qualityLabel(qRep)}${C.x} · ${findingsLabel(qRep)} · coverage ${coverageLabel(cov)} · composites: ${cfgSrc}`);
for (const d of q.dimensions) e(`         ${d.name.padEnd(12)} ${String(d.score).padStart(3)}${d.root ? `  ${C.y}[${d.root}]${C.x}` : ""}`);
const wl = q.composites?.worklists || {};
const wlTop = (k) => (wl[k] || []).slice(0, 4).map((x) => x.path.split("/").pop() + " " + x.score).join(" · ") || "—";
if (q.dimensions.length) {
  e(`  ${C.b}worklists:${C.x}`);
  e(`     ⭑ priority (reach×sev×defect×untested): ${wlTop("priority")}`);
  e(`     🔥 hotspot map (churn×complexity):       ${wlTop("hotspot")}`);
  e(`     ⚠ critical-untested (reach×¬coverage):  ${wlTop("criticalUntested")}`);
}
if (covMissing || !qualityMeasured(qRep) || covPending || staleGroups || issuesStale) {
  e(`  ${C.y}⟳ pending:${C.x}`);
  if (!qualityMeasured(qRep)) e(`     • quality NOT MEASURED (no quality-report.json) → node tooling/quality/quality.mjs`);
  if (covMissing) e(`     • research coverage NOT MEASURED (no coverage-report.json) → node tooling/research-coverage/coverage.mjs scan`);
  if (covPending) e(`     • ${covPending} file(s) need research → coverage.mjs batches → dispatch → record`);
  if (staleGroups) e(`     • ${staleGroups} consistency group(s) changed → dispatch consistency/batches/* → record`);
  if (issuesStale) e(`     • layering/dup changed → 2 issue agents → consistency.mjs record`);
} else e(`  ${C.g}✓ fresh${C.x}`);
e("");
e(`${C.b}ENRICH${C.x}   ${nodes.length} files · reach + ownership computed (reach ${reachMissing} missing) · ${taxonomyN} intentions`);
if (enrichPending) {
  e(`  ${C.y}⟳ pending:${C.x}`);
  if (intentPending) e(`     • ${intentPending} file(s) need intention tags${taxonomyN ? "" : " (no taxonomy yet — run discovery)"} → intentions.mjs batches → dispatch → merge`);
} else e(`  ${C.g}✓ fresh — reach computed, every file has intentions${C.x}`);
e("");
e(`${C.b}PUBLISH${C.x}  Barkpark ${up ? C.g + "reachable" + C.x : C.r + "not reachable" + C.x} · nodes ${publishNeeded ? C.y + "changed" + C.x : C.g + "in sync" + C.x}`);
if (published) e(`  ${C.g}✓ pushed → /d/codebase/papers/:slug · /v1/graph?dataset=codebase · codebase-graph.html${C.x}`);
else if (pushFailed) e(`  ${C.r}✗ push FAILED — the published dataset is still behind (see the push error above)${C.x}`);
else if (!up) e(`  ${C.y}· start Barkpark (make dev) then re-run with --publish${C.x}`);
else if (publishNeeded) e(`  ${C.y}⟳ ${PUBLISH ? "" : "data changed — "}run with --publish to ship into Barkpark${C.x}`);
else e(`  ${C.g}✓ in sync${C.x}`);
e("");
const allFresh = qualityMeasured(qRep) && !covMissing && !covPending && !staleGroups && !issuesStale && !enrichPending && (!up || !publishNeeded || published);
e(allFresh ? `  ${C.g}${C.b}✓ FRESH across all arcs.${C.x}` : `  ${C.b}→ do the pending agent work, re-run status${C.x}`);
e(`  → tooling/quality/quality-report.html (quality) · codebase-graph.html (graph)`);
e(`  → DELIVERY: node tooling/scope/scope.mjs <intention|task>  (scoped context pack — exploration→lookup; --list)`);
