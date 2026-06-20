#!/usr/bin/env node
// Intentions axis — a SECOND edge type. The dependency graph links files that
// import each other; intentions link files that serve the same OBJECTIVE, even
// with no code relation ("Improve navigation menu", "Reach peak DX"). Each
// intention is a hub node; files reference the intentions they advance.
// Multi-scale: epic (system-wide) + small (feature-level).
//
//   intentions.mjs digest   → taxonomy-input.txt (corpus for taxonomy derivation) [free]
//   intentions.mjs batches   → per-file tagging tasks (read taxonomy + file ctx)   [free]
//   intentions.mjs merge     → intentions-report.json {taxonomy, files, hubs}      [free]

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync, readdirSync, mkdirSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE }).toString().trim();
const cmd = process.argv[2] || "digest";
const BATCH = 10;

const nodes = JSON.parse(readFileSync(join(ROOT, "tooling/barkpark-sync/nodes.json"), "utf8")).nodes;
const rows = nodes.map(n => ({ path: n.path, stack: n.fields.stack, role: n.fields.role, why: (n.fields.whyUseful || n.fields.description || "").slice(0, 160), importance: n.fields.importance, usefulness: n.fields.usefulness }));

if (cmd === "digest") {
  // condensed corpus the taxonomy agent reads to discover the objectives the codebase serves
  const lines = rows.map(r => `${r.path} [${r.stack}] — ${r.role}${r.why ? " — " + r.why : ""}`);
  writeFileSync(join(HERE, "taxonomy-input.txt"), lines.join("\n"));
  process.stderr.write(`[intentions] digest: ${lines.length} files → taxonomy-input.txt (feed to the taxonomy agent)\n`);
}

if (cmd === "batches") {
  if (!existsSync(join(HERE, "taxonomy.json"))) { process.stderr.write("[intentions] taxonomy.json missing — derive it first (taxonomy agent)\n"); process.exit(1); }
  const BDIR = join(HERE, "batches"); rmSync(BDIR, { recursive: true, force: true }); mkdirSync(BDIR, { recursive: true });
  if (!existsSync(join(HERE, "results"))) mkdirSync(join(HERE, "results"));
  const pad = (i) => String(i).padStart(3, "0");
  let b = 0; for (let i = 0; i < rows.length; i += BATCH) { writeFileSync(join(BDIR, `batch-${pad(b)}.json`), JSON.stringify({ batch: b, files: rows.slice(i, i + BATCH) }, null, 2)); b++; }
  writeFileSync(join(HERE, "batch-count.txt"), String(b));
  process.stderr.write(`[intentions] ${rows.length} files → ${b} tagging batches\n`);
}

if (cmd === "merge") {
  const taxonomy = JSON.parse(readFileSync(join(HERE, "taxonomy.json"), "utf8"));
  const taxIds = new Set(taxonomy.map(t => t.id));
  const RDIR = join(HERE, "results");
  const fileIntents = {};
  for (const f of (existsSync(RDIR) ? readdirSync(RDIR) : []).filter(f => f.endsWith(".json"))) {
    try { for (const r of JSON.parse(readFileSync(join(RDIR, f), "utf8"))) if (r?.path) fileIntents[r.path] = (r.intentions || []).filter(id => taxIds.has(id)); } catch {}
  }
  const hubs = {}; for (const t of taxonomy) hubs[t.id] = [];
  for (const [path, ints] of Object.entries(fileIntents)) for (const id of ints) hubs[id]?.push(path);
  const report = { at: new Date().toISOString(), taxonomy, files: fileIntents, hubs };
  writeFileSync(join(HERE, "intentions-report.json"), JSON.stringify(report, null, 2));
  const tagged = Object.values(fileIntents).filter(a => a.length).length;
  process.stderr.write(`[intentions] ${taxonomy.length} intentions · ${tagged}/${nodes.length} files tagged\n`);
  for (const t of [...taxonomy].sort((a, b) => (hubs[b.id]?.length || 0) - (hubs[a.id]?.length || 0)).slice(0, 10))
    process.stderr.write(`  ${String((hubs[t.id] || []).length).padStart(3)} files · [${t.scale}] ${t.title}\n`);
}
