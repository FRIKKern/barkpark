#!/usr/bin/env node
// Rebuild every committed derived file in dependency order (the map lives in
// scripts/derived-files.mjs). task-e04a2c419fdd3621.
//
//   node scripts/regen.mjs                    rebuild every step
//   node scripts/regen.mjs --base origin/main rebuild only the steps the diff reaches
//   node scripts/regen.mjs --only golden-pack rebuild one step (repeatable)
//   node scripts/regen.mjs --check            exit 1 when anything is stale
//
// --check needs a clean tree: it rebuilds, lists what moved, then puts every
// moved file back, so the tree ends as it started, Ctrl-C included (exit 130).

import { execSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync, rmSync } from "node:fs";
import { STEPS, ordered, reached, step } from "./derived-files.mjs";
import { changedPaths } from "./reach.mjs";

const root = execSync("git rev-parse --show-toplevel", { encoding: "utf8" }).trim();
const git = (args) => execSync(`git ${args}`, { cwd: root, encoding: "utf8", maxBuffer: 1 << 30 });

function treeState() {
  const hash = createHash("sha256").update(git("diff HEAD --binary"));
  for (const f of untracked()) hash.update(f).update(readFileSync(`${root}/${f}`));
  return hash.digest("hex");
}

const untracked = () => git("ls-files --others --exclude-standard").split("\n").filter(Boolean);
const moved = () => [...git("diff HEAD --name-only").split("\n").filter(Boolean), ...untracked()];

// A Ctrl-C reaches the running step and this process alike; the step dies, and
// the listeners below keep this process alive long enough to stop and restore.
let interrupted = null;
for (const sig of ["SIGINT", "SIGTERM"]) process.on(sig, () => {});

function sh(cmd) {
  const res = spawnSync("bash", ["-c", cmd], { cwd: root, stdio: "inherit" });
  if (res.signal) interrupted = res.signal;
  return res.status === 0;
}

function parseArgs(argv) {
  const opts = { check: false, base: null, only: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--check") opts.check = true;
    else if (a === "--base") opts.base = argv[++i];
    else if (a === "--only") opts.only.push(argv[++i]);
    else throw new Error(`unknown argument ${a}`);
  }
  return opts;
}

function selected(opts) {
  if (opts.only.length) return ordered(opts.only.map(step));
  if (opts.base) return reached(changedPaths(opts.base));
  return ordered(STEPS);
}

function run(steps) {
  const changed = new Set();
  const failed = [];
  for (const s of steps) {
    if (interrupted) break;
    const upstream = s.after.some((d) => changed.has(d));
    if (s.check && !upstream) {
      console.log(`\n== ${s.name}: check\n$ ${s.check}`);
      if (sh(s.check) || interrupted) continue;
    }
    console.log(`\n== ${s.name}: write\n$ ${s.write}`);
    const before = treeState();
    if (!sh(s.write)) failed.push(s.name);
    if (treeState() !== before) changed.add(s.name);
  }
  return { changed: [...changed], failed };
}

const opts = parseArgs(process.argv.slice(2));
if (opts.check && moved().length) {
  console.error("regen --check needs a clean tree; commit or stash first:\n" + moved().join("\n"));
  process.exit(2);
}

const steps = selected(opts);
console.log(`regen: ${steps.map((s) => s.name).join(", ") || "nothing reached"}`);
const { changed, failed } = run(steps);
const files = moved();

console.log(`\nregen: changed ${changed.join(", ") || "nothing"}${failed.length ? `; FAILED ${failed.join(", ")}` : ""}${interrupted ? `; stopped by ${interrupted}` : ""}`);
if (opts.check) {
  if (files.length) {
    console.log(`stale:\n${files.join("\n")}`);
    const fresh = new Set(untracked());
    const tracked = files.filter((f) => !fresh.has(f));
    if (tracked.length) git(`checkout -- ${tracked.map((f) => `'${f}'`).join(" ")}`);
    fresh.forEach((f) => rmSync(`${root}/${f}`));
  }
  process.exit(interrupted ? 130 : files.length || failed.length ? 1 : 0);
}
process.exit(interrupted ? 130 : failed.length ? 1 : 0);
