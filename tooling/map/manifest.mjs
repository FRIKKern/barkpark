#!/usr/bin/env node
// manifest.mjs — the currency guarantee for the codebase map.
//
// The map (blast-radius index, barkpark-sync nodes, risk-report …) is only
// trustworthy if it was built against the tree it's being queried on. This
// script pins a manifest of every tracked file's git blob SHA at build time,
// then later verifies that the CURRENT working tree still matches — flagging
// every file whose content drifted (SHA changed / added / deleted) so a
// consumer (e.g. what-breaks.mjs) can warn "the map is stale, rebuild it".
//
//   manifest.mjs build    → write manifest.json { head, files: {path: blobSha} }
//   manifest.mjs verify   → diff manifest.json vs working tree; exit 0 current / 1 stale
//   manifest.mjs verify --json → machine-readable verdict on stdout
//
// No deps. git ls-files -s already prints the blob SHA in column 2 — we never
// hash anything ourselves. Dirty (uncommitted) files are layered on top via
// git status --porcelain so a modified-but-uncommitted file reads as stale too.

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE })
  .toString()
  .trim();
const MANIFEST = join(HERE, "manifest.json");

const git = (args) =>
  execFileSync("git", args, {
    cwd: ROOT,
    encoding: "utf8",
    maxBuffer: 512 * 1024 * 1024,
  });

// { path -> blobSha } from `git ls-files -s` (col 2 IS the blob SHA — no hashing).
//   <mode> <sha> <stage>\t<path>
function indexBlobs() {
  const out = {};
  for (const line of git(["ls-files", "-s"]).split("\n")) {
    if (!line) continue;
    const tab = line.indexOf("\t");
    if (tab < 0) continue;
    const meta = line.slice(0, tab).split(/\s+/); // [mode, sha, stage]
    const path = line.slice(tab + 1);
    out[path] = meta[1];
  }
  return out;
}

// Files dirty in the working tree (modified, added, deleted, untracked).
// Returns { modified:Set, deleted:Set, untracked:Set } over porcelain.
function dirtyState() {
  const modified = new Set();
  const deleted = new Set();
  const untracked = new Set();
  for (const line of git(["status", "--porcelain"]).split("\n")) {
    if (!line) continue;
    const x = line[0];
    const y = line[1];
    let path = line.slice(3);
    // porcelain renames: "R  old -> new"
    const arrow = path.indexOf(" -> ");
    if (arrow >= 0) path = path.slice(arrow + 4);
    if (x === "?" && y === "?") {
      untracked.add(path);
    } else if (x === "D" || y === "D") {
      deleted.add(path);
    } else {
      modified.add(path);
    }
  }
  return { modified, deleted, untracked };
}

function buildManifest() {
  const head = git(["rev-parse", "HEAD"]).trim();
  const files = indexBlobs();
  const manifest = {
    head,
    builtAt: new Date().toISOString(),
    fileCount: Object.keys(files).length,
    files,
  };
  writeFileSync(MANIFEST, JSON.stringify(manifest, null, 2) + "\n");
  return manifest;
}

// Compare manifest.json against the live tree. Returns a structured verdict.
function verifyManifest() {
  if (!existsSync(MANIFEST)) {
    return {
      ok: false,
      reason: "no-manifest",
      message: "manifest.json not found — run `manifest.mjs build` first.",
      stale: [],
      added: [],
      deleted: [],
      dirty: [],
    };
  }
  const manifest = JSON.parse(readFileSync(MANIFEST, "utf8"));
  const pinned = manifest.files || {};
  const live = indexBlobs(); // committed-tree blobs as of now
  const { modified, deleted: porcelainDeleted, untracked } = dirtyState();

  const stale = []; // committed blob SHA changed since manifest
  const added = []; // tracked now, absent from manifest
  const deleted = []; // in manifest, gone from tree
  const dirty = new Set(); // uncommitted drift (modified/added/deleted in WT)

  // Walk the live index vs the pinned manifest.
  for (const [path, sha] of Object.entries(live)) {
    if (!(path in pinned)) {
      added.push(path);
    } else if (pinned[path] !== sha) {
      stale.push(path);
    }
  }
  for (const path of Object.keys(pinned)) {
    if (!(path in live)) deleted.push(path);
  }
  // Layer working-tree dirtiness — a file can be committed-identical yet edited.
  for (const p of modified) if (p in pinned || p in live) dirty.add(p);
  for (const p of porcelainDeleted) dirty.add(p);
  for (const p of untracked) dirty.add(p);

  const headNow = git(["rev-parse", "HEAD"]).trim();
  const dirtyArr = [...dirty].sort();
  const ok =
    stale.length === 0 &&
    added.length === 0 &&
    deleted.length === 0 &&
    dirtyArr.length === 0;

  return {
    ok,
    reason: ok ? "current" : "stale",
    manifestHead: manifest.head,
    headNow,
    headMoved: manifest.head !== headNow,
    pinnedAt: manifest.builtAt,
    counts: {
      stale: stale.length,
      added: added.length,
      deleted: deleted.length,
      dirty: dirtyArr.length,
    },
    stale: stale.sort(),
    added: added.sort(),
    deleted: deleted.sort(),
    dirty: dirtyArr,
  };
}

function printVerify(v) {
  if (v.reason === "no-manifest") {
    console.error(v.message);
    return;
  }
  if (v.ok) {
    console.log(`✓ map is CURRENT — HEAD ${short(v.headNow)} matches manifest (built ${v.pinnedAt}).`);
    return;
  }
  console.log(`✗ map is STALE — built at ${short(v.manifestHead)}, HEAD now ${short(v.headNow)}${v.headMoved ? " (HEAD moved)" : ""}.`);
  const blocks = [
    ["changed (blob SHA differs)", v.stale],
    ["added (new tracked file)", v.added],
    ["deleted (gone from tree)", v.deleted],
    ["dirty (uncommitted in working tree)", v.dirty],
  ];
  for (const [label, list] of blocks) {
    if (!list.length) continue;
    console.log(`\n  ${list.length} ${label}:`);
    for (const p of list.slice(0, 20)) console.log(`    ${p}`);
    if (list.length > 20) console.log(`    … and ${list.length - 20} more`);
  }
  console.log("\n  → rebuild the map, then `manifest.mjs build` to re-pin.");
}

const short = (s) => (s ? s.slice(0, 8) : "?");

// ---- CLI -------------------------------------------------------------------
// Only run as a command when invoked directly — importers (what-breaks.mjs)
// pull in verifyManifest without triggering the CLI.
function main() {
  const [cmd, ...rest] = process.argv.slice(2);
  const wantJson = rest.includes("--json");
  if (cmd === "build") {
    const m = buildManifest();
    if (wantJson) {
      console.log(JSON.stringify({ ok: true, head: m.head, fileCount: m.fileCount, path: MANIFEST }, null, 2));
    } else {
      console.log(`✓ pinned ${m.fileCount} files @ ${short(m.head)} → ${MANIFEST}`);
    }
  } else if (cmd === "verify") {
    const v = verifyManifest();
    if (wantJson) console.log(JSON.stringify(v, null, 2));
    else printVerify(v);
    process.exit(v.ok ? 0 : 1);
  } else {
    console.error("usage: manifest.mjs <build|verify> [--json]");
    process.exit(2);
  }
}

if (process.argv[1] && process.argv[1] === fileURLToPath(import.meta.url)) {
  main();
}

export { buildManifest, verifyManifest };
