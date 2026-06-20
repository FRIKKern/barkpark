#!/usr/bin/env node
// Subsystem review — partition the codebase into coherent subsystems so agents
// can READ the real code (not a digest) and surface the intentions each area
// actually reveals. Bottom-up, grounded discovery → a comprehensive taxonomy.
//
//   review.mjs subsystems  → per-subsystem review tasks (file lists + key files)  [free]
//   review.mjs merge        → (handled by intentions.mjs after canonicalize)

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync, mkdirSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE }).toString().trim();
const nodes = JSON.parse(readFileSync(join(ROOT, "tooling/barkpark-sync/nodes.json"), "utf8")).nodes.filter(n => n.kind !== "intention");

// group by dirname, then merge small dirs up into their parent until each
// subsystem has >= MIN files (coherent areas, not one-file fragments)
const MIN = 4;
let groups = {};
for (const n of nodes) (groups[dirname(n.path)] ||= []).push(n);
let changed = true;
while (changed) {
  changed = false;
  for (const [dir, fs] of Object.entries(groups)) {
    if (fs.length >= MIN || dir === "." || !dir.includes("/")) continue;
    const parent = dirname(dir);
    (groups[parent] ||= []).push(...fs); delete groups[dir]; changed = true; break;
  }
}

const subs = Object.entries(groups).map(([dir, fs]) => ({
  subsystem: dir, count: fs.length,
  files: fs.sort((a, b) => (b.fields.importance + b.fields.usefulness) - (a.fields.importance + a.fields.usefulness))
    .map(n => ({ path: n.path, role: n.fields.role, importance: n.fields.importance, usefulness: n.fields.usefulness })),
})).sort((a, b) => b.count - a.count);

const BDIR = join(HERE, "review-batches"); rmSync(BDIR, { recursive: true, force: true }); mkdirSync(BDIR, { recursive: true });
if (!existsSync(join(HERE, "review-results"))) mkdirSync(join(HERE, "review-results"));
const pad = (i) => String(i).padStart(3, "0");
subs.forEach((s, i) => writeFileSync(join(BDIR, `sub-${pad(i)}.json`), JSON.stringify(s, null, 2)));
writeFileSync(join(HERE, "review-count.txt"), String(subs.length));

const e = (s) => process.stderr.write(s + "\n");
e(`[review] ${nodes.length} files → ${subs.length} subsystems (≥${MIN} files each)`);
for (const s of subs.slice(0, 14)) e(`  ${String(s.count).padStart(3)} files  ${s.subsystem}`);
e(`  …`);
