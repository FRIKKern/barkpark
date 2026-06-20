#!/usr/bin/env node
// Risk axes — two cheap, programmatic signals that turn the worklist from
// "important & broken" into "important, broken, fragile, AND untested":
//   defect-history — git bug-fix/revert mining → where bugs actually land
//   test-presence  — proxy for test coverage (sibling test + module refs in tests)
//   ownership      — bus-factor: top author's commit share + distinct author count
// Proxy, not line coverage: real coverage (go test -cover / mix --cover / vitest)
// can be ingested later; this needs nothing to run.
//
//   risk.mjs   → risk-report.json (per-file) + console summary   [free]

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join, basename } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE }).toString().trim();
const git = (a) => execFileSync("git", a, { cwd: ROOT, encoding: "utf8", maxBuffer: 512 * 1024 * 1024 });
const sig = JSON.parse(readFileSync(join(ROOT, "tooling/file-importance/file-signals.json"), "utf8")).signals;
const churn = Object.fromEntries(sig.map(s => [s.path, s.churn]));

// ---- defect history: commits whose subject signals a fix/revert ----
const BUG = /\b(fix(es|ed)?|bug|hotfix|revert|regression|broken|crash|patch(ed)?|incorrect|wrong|fault|defect|oops|reverts?)\b/i;
const bugFix = {};
{
  let isBug = false;
  for (const line of git(["log", "--all", "--pretty=format:\x01%s", "--name-only"]).split("\n")) {
    if (line.startsWith("\x01")) isBug = BUG.test(line.slice(1));
    else if (line.trim() && isBug) bugFix[line.trim()] = (bugFix[line.trim()] || 0) + 1;
  }
}

// ---- ownership: per-file author commit counts (bus-factor) ----
// One log pass: attribute each touched file to the commit's author.
const authorCounts = {};   // path -> { author -> commits }
{
  let author = null;
  for (const line of git(["log", "--all", "--no-merges", "--pretty=format:\x01%an", "--name-only"]).split("\n")) {
    if (line.startsWith("\x01")) author = line.slice(1).trim();
    else if (line.trim() && author) { (authorCounts[line.trim()] ||= {})[author] = (authorCounts[line.trim()][author] || 0) + 1; }
  }
}
function ownership(path) {
  const counts = authorCounts[path] || {};
  const total = Object.values(counts).reduce((a, b) => a + b, 0);
  const authorCount = Object.keys(counts).length;
  const top = Object.values(counts).reduce((m, c) => Math.max(m, c), 0);
  const primaryAuthorShare = total ? Math.round((top / total) * 100) : 0;
  return { primaryAuthorShare, authorCount };
}

// ---- test files + corpus ----
const all = git(["ls-files"]).split("\n").filter(Boolean);
const isTest = (f) => /(_test\.(go|exs)|\.test\.[tj]sx?|\.spec\.[tj]sx?)$/.test(f) || /(^|\/)test\//.test(f);
const testFiles = all.filter(isTest);
const testBasenames = new Set(testFiles.map(f => basename(f)));
const read = (f) => { try { return readFileSync(join(ROOT, f), "utf8"); } catch { return ""; } };
const testCorpus = testFiles.map(read).join("\n").toLowerCase();

function siblingTest(f) {
  const b = basename(f).replace(/\.[^.]+$/, "");
  return ["_test.exs", "_test.go", "_test.ts", ".test.ts", ".test.tsx", ".spec.ts", ".test.js"]
    .some(suf => testBasenames.has(b + suf));
}
function modToken(f, txt) {
  if (/\.exs?$/.test(f)) { const m = txt.match(/defmodule\s+([\w.]+)/); return m ? m[1] : null; }
  return null;
}

// ---- per source (code, non-test) file ----
const code = sig.filter(s => s.kind === "code");
const out = {};
for (const s of code) {
  const txt = read(s.path);
  const has = siblingTest(s.path);
  const mod = modToken(s.path, txt);
  const refs = mod ? Math.max(0, testCorpus.split(mod.toLowerCase()).length - 1) : 0;
  const testScore = Math.min(100, (has ? 60 : 0) + Math.min(40, refs * 8));
  const fixes = bugFix[s.path] || 0;
  const own = ownership(s.path);
  out[s.path] = { bugFixes: fixes, defectDensity: +(fixes / Math.max(1, churn[s.path] || 1)).toFixed(2),
    hasTest: has, testRefs: refs, testScore,
    primaryAuthorShare: own.primaryAuthorShare, authorCount: own.authorCount };
}

const report = { at: new Date().toISOString(), note: "test-presence is a PROXY, not line coverage", files: out };
writeFileSync(join(HERE, "risk-report.json"), JSON.stringify(report, null, 2));

const vals = Object.values(out);
const untested = vals.filter(v => v.testScore < 40).length;
const fragile = Object.entries(out).filter(([, v]) => v.defectDensity >= 0.4).sort((a, b) => b[1].bugFixes - a[1].bugFixes);
const e = (s) => process.stderr.write(s + "\n");
e(`risk  ${vals.length} code files`);
e(`  test-presence: ${vals.filter(v => v.hasTest).length} have a sibling test · ${untested} score <40 (likely untested)`);
e(`  defect-prone (density ≥0.4), top 8:`);
for (const [f, v] of fragile.slice(0, 8)) e(`    ${v.bugFixes} fixes / ${churn[f]} churn = ${v.defectDensity}  ${f}`);
const soloOwned = vals.filter(v => v.authorCount === 1).length;
e(`  ownership: ${soloOwned} file(s) single-author (bus-factor 1)`);
e(`  → risk-report.json`);
