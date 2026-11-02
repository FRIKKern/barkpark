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
// moved file back, so the tree ends as it started.

import { execFileSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync, rmSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { STEPS, ordered, reached, step } from "./derived-files.mjs";
import { changedPaths } from "./reach.mjs";

const root = execFileSync("git", ["rev-parse", "--show-toplevel"], { encoding: "utf8" }).trim();
const git = (args) => execFileSync("git", args, { cwd: root, encoding: "utf8", maxBuffer: 1 << 30, env: { ...process.env, GIT_LITERAL_PATHSPECS: "1" } });

function treeState() {
  const hash = createHash("sha256").update(git(["diff", "HEAD", "--binary"]));
  for (const f of untracked()) hash.update(f).update(readFileSync(`${root}/${f}`));
  return hash.digest("hex");
}

const untracked = () => git(["ls-files", "--others", "--exclude-standard", "-z"]).split("\0").filter(Boolean);
const moved = () => [...git(["diff", "HEAD", "--name-only", "-z"]).split("\0").filter(Boolean), ...untracked()];

function sh(cmd) {
  return spawnSync("bash", ["-c", cmd], { cwd: root, stdio: "inherit" }).status === 0;
}

export function parseArgs(argv) {
  const opts = { check: false, base: null, only: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--check") opts.check = true;
    else if (a === "--base" || a === "--only") {
      const value = argv[++i];
      if (!value || value.startsWith("-")) throw new Error(`${a} needs a value`);
      if (a === "--base") {
        if (opts.base !== null) throw new Error("--base may only be given once");
        opts.base = value;
      } else opts.only.push(value);
    }
    else throw new Error(`unknown argument ${a}`);
  }
  if (opts.base !== null && opts.only.length) throw new Error("use either --base or --only");
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
    const upstream = s.after.some((d) => changed.has(d));
    if (s.check && !upstream) {
      console.log(`\n== ${s.name}: check\n$ ${s.check}`);
      if (sh(s.check)) continue;
    }
    console.log(`\n== ${s.name}: write\n$ ${s.write}`);
    const before = treeState();
    if (!sh(s.write)) {
      failed.push(s.name);
      break;
    }
    if (treeState() !== before) changed.add(s.name);
  }
  return { changed: [...changed], failed };
}

function restore() {
  const fresh = new Set(untracked());
  const tracked = moved().filter((f) => !fresh.has(f));
  if (tracked.length) git(["restore", "--source=HEAD", "--worktree", "--", ...tracked]);
  for (const f of fresh) rmSync(`${root}/${f}`, { force: true });
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  let opts;
  let steps;
  try {
    opts = parseArgs(process.argv.slice(2));
    steps = selected(opts);
    if (opts.check && moved().length) throw new Error("--check needs a clean tree; commit or stash first:\n" + moved().join("\n"));
  } catch (error) {
    console.error(`regen: ${error.message}`);
    process.exit(2);
  }
  if (opts.check) {
    for (const [signal, code] of [["SIGINT", 130], ["SIGTERM", 143]]) {
      process.once(signal, () => { restore(); process.exit(code); });
    }
  }
  try {
    console.log(`regen: ${steps.map((s) => s.name).join(", ") || "nothing reached"}`);
    const { changed, failed } = run(steps);
    const files = moved();
    console.log(`\nregen: changed ${changed.join(", ") || "nothing"}${failed.length ? `; FAILED ${failed.join(", ")}` : ""}`);
    if (opts.check && files.length) console.log(`stale:\n${files.join("\n")}`);
    process.exitCode = failed.length || (opts.check && files.length) ? 1 : 0;
  } finally {
    if (opts.check) restore();
  }
}
