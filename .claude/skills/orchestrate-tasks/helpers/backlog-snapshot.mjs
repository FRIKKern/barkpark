#!/usr/bin/env node
// Snapshot the ready backlog into $ORCH/ready.json and print a carving digest.
import { execFileSync } from "node:child_process";
import { writeFileSync, mkdirSync } from "node:fs";
const ORCH = process.env.ORCH || `${process.env.HOME}/.cache/barkpark-orchestrate`;
mkdirSync(ORCH, { recursive: true });
const env = { ...process.env }; delete env.BARKPARK_TOKEN;
const raw = execFileSync("bp", ["task", "ready", "--all", "-o", "json"], { env, maxBuffer: 1 << 28 }).toString();
writeFileSync(`${ORCH}/ready.json`, raw);
const rows = JSON.parse(raw).docs.filter(r => !String(r.doc_id).startsWith("drafts."));
const pr = {}, par = {};
for (const r of rows) { pr[r.priority ?? "none"] = (pr[r.priority ?? "none"] || 0) + 1; if (r.parent_id) par[r.parent_id] = (par[r.parent_id] || 0) + 1; }
const idx = Object.fromEntries(rows.map(r => [r.doc_id, r]));
console.log(`ready rows: ${rows.length}  by priority: ${JSON.stringify(pr)}`);
console.log("\n# parents with the most ready children");
for (const [id, n] of Object.entries(par).sort((a, b) => b[1] - a[1]).slice(0, 25))
  console.log(`${String(n).padStart(4)}  ${id}  ${(idx[id] || {}).title || "(parent not ready itself)"}`);
console.log("\n# P0/P1 leaves (no children)");
for (const r of rows.filter(r => r.priority <= 1 && !r.child_count).slice(0, 80))
  console.log(`p${r.priority}  ${r.doc_id}  ${r.title.slice(0, 120)}`);
console.log(`\nwrote ${ORCH}/ready.json`);
