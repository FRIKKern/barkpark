#!/usr/bin/env node
// Unit proof for the SPOTLIGHT-CLUTTER sub-signal of the Bloat critic.
//
//   node tooling/aesthetics/spotlight-clutter.test.mjs
//
// aesthetics.mjs reads the tree via `git ls-files`, so the deterministic, self-
// contained way to prove the detector + its FALSE-POSITIVE GUARDS is to build a
// throwaway git repo in a temp dir, copy aesthetics.mjs into it, run it, and read
// back its report. No network, no deps — pure Node + git.
//
// What it proves:
//   ✓ a top-level dir holding ONE niche file (proof/onix-sample.xml,
//     secrets/bokbasen.env.example) IS flagged spotlight-clutter
//   GUARDS — these must NOT be flagged:
//   ✗ a real PACKAGE dir (has package.json)            — pkg/
//   ✗ a real PROJECT dir (has a src/ subdir)           — proj/
//   ✗ a conventional INFRA dir (bin/)                  — bin/
//   ✗ a dot-prefixed infra dir (.github/)              — .github/
//   ✗ a populated CONTENT TREE (>2 tracked files)      — docs/
//   ✗ a dir whose lone file is SOURCE (not niche)      — onefilemod/

import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, copyFileSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const tmp = mkdtempSync(join(tmpdir(), "bp-spot-"));
const w = (rel, body = "x\n") => { mkdirSync(dirname(join(tmp, rel)), { recursive: true }); writeFileSync(join(tmp, rel), body); };

// ── the synthetic tree ──────────────────────────────────────────────────────
// a couple of real root files so the repo looks normal
w("README.md", "# fixture\n");
w("go.mod", "module x\n");

// CASE A — spotlight-clutter (the proof/ + secrets/ shape): a top-level dir, one niche file
w("proof/onix-sample.xml", "<onix/>\n");
w("secrets/bokbasen.env.example", "TOKEN=changeme\n");

// GUARD 1a — a real PACKAGE (package.json present) — must NOT be flagged
w("pkg/package.json", "{}\n");
// GUARD 1b — a real PROJECT (a src/ subdir) — must NOT be flagged
w("proj/src/main.ts", "export const x = 1;\n");
// GUARD 2a — a conventional INFRA dir (bin/) — must NOT be flagged
w("bin/run", "#!/bin/sh\n");
// GUARD 2b — a dot-prefixed infra dir (.github/) — must NOT be flagged
w(".github/workflows/ci.yml", "on: push\n");
// GUARD 3 — a populated CONTENT TREE (>2 tracked files) — must NOT be flagged
w("docs/a.md", "a\n"); w("docs/b.md", "b\n"); w("docs/c.md", "c\n");
// GUARD 4 — a top-level dir whose lone file is SOURCE (root-clutter's lens, not this) — NOT flagged
w("onefilemod/thing.go", "package main\n");

// init git + commit so `git ls-files` sees the tree
const git = (...a) => execFileSync("git", a, { cwd: tmp, encoding: "utf8" });
git("init", "-q");
git("config", "user.email", "t@t.t");
git("config", "user.name", "t");
git("add", "-A");
git("commit", "-qm", "fixture");

// copy the REAL analyzer into the fixture repo and run it there
copyFileSync(join(HERE, "aesthetics.mjs"), join(tmp, "aesthetics.mjs"));
execFileSync("node", ["aesthetics.mjs"], { cwd: tmp, stdio: "ignore" });
const rep = JSON.parse(readFileSync(join(tmp, "aesthetics-report.json"), "utf8"));
rmSync(tmp, { recursive: true, force: true });

// ── assertions ──────────────────────────────────────────────────────────────
const flagged = new Set(
  rep.bloat.findings.filter((f) => f.kind === "spotlight-clutter").map((f) => f.path)
);
let fails = 0;
const ok = (cond, msg) => { if (cond) { console.log(`  ✓ ${msg}`); } else { console.log(`  ✗ ${msg}`); fails++; } };

console.log("SPOTLIGHT-CLUTTER detector:");
ok(flagged.has("proof/"), "proof/ (one niche xml) IS flagged");
ok(flagged.has("secrets/"), "secrets/ (one .env.example) IS flagged");
ok(rep.summary.spotlightClutter === 2, `summary.spotlightClutter === 2 (got ${rep.summary.spotlightClutter})`);
ok(rep.penalties.bloat.spotlight === 6, `bloat penalty −6 = 3×2 (got −${rep.penalties.bloat.spotlight})`);

console.log("FALSE-POSITIVE GUARDS (none of these may be flagged):");
ok(!flagged.has("pkg/"), "pkg/ (has package.json) NOT flagged — real package");
ok(!flagged.has("proj/"), "proj/ (has src/) NOT flagged — real project");
ok(!flagged.has("bin/"), "bin/ NOT flagged — conventional infra dir");
ok(!flagged.has(".github/"), ".github/ NOT flagged — dot-prefixed infra dir");
ok(!flagged.has("docs/"), "docs/ NOT flagged — populated content tree (>2 files)");
ok(!flagged.has("onefilemod/"), "onefilemod/ NOT flagged — lone file is SOURCE (root-clutter's lens)");

// the finding shape contract
const proof = rep.bloat.findings.find((f) => f.path === "proof/");
ok(proof && proof.kind === "spotlight-clutter", "finding.kind === 'spotlight-clutter'");
ok(proof && /steals the root index/.test(proof.why), "finding.why carries the 'steals the root index' rationale");
ok(proof && typeof proof.fix === "string" && proof.fix.length > 0, "finding.fix is a non-empty relocation instruction");
ok(proof && typeof proof.severity === "number", "finding.severity is numeric");

console.log(fails === 0 ? "\nPASS — detector + all false-positive guards hold." : `\nFAIL — ${fails} assertion(s) failed.`);
process.exit(fails === 0 ? 0 : 1);
