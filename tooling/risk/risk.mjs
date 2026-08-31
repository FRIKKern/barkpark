#!/usr/bin/env node
// Risk axes — cheap, programmatic signals that turn the worklist from
// "important & broken" into "important, broken, fragile, AND untested":
//   defect-history — git bug-fix/revert mining → where bugs actually land
//   test-coverage  — REAL line/statement coverage where a fast suite exists
//                    (go test -cover, mix test --cover); a presence PROXY elsewhere
//   ownership      — bus-factor: top author's commit share + distinct author count
//
// Coverage is MEASURED, not proxied, for Go and Elixir (v2 Phase 1). Each file's
// testScore carries a `testCoverageSource` flag: "go" | "elixir" | "js" |
// "proxy" | "proxy-unasserted" (a sibling test exists but has zero assertion
// sites — see tooling/risk/test-proxy.mjs).
// Pass --no-coverage to skip the heavy suites and fall back to the proxy everywhere
// (keeps the suite fast/portable on machines without the toolchains).
//
//   risk.mjs               → risk-report.json (per-file) + console summary
//   risk.mjs --no-coverage → proxy-only (no go/mix suites)

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync, readdirSync } from "node:fs";
import { dirname, join, basename } from "node:path";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";
import { FRAGILE_DENSITY, UNTESTED_SCORE } from "../lib/thresholds.mjs";
import { evalFormula } from "../lib/formula.mjs";
import { elixirFnCov, jsFnCov } from "./fn-coverage.mjs";
import { scoreTestProxy } from "./test-proxy.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE }).toString().trim();
// Coverage cache: the suites (go/mix --cover) are slow; only re-run them when
// code/tests change. Signature = git blobs of all source/test files + dirty.
function covSig() {
  try {
    const lines = execFileSync("git", ["ls-files", "-s"], { cwd: ROOT, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 }).split("\n").filter((l) => /\.(go|exs?|tsx?|jsx?|mjs)$/.test(l)).sort();
    const dirty = execFileSync("git", ["status", "--porcelain"], { cwd: ROOT, encoding: "utf8" }).split("\n").filter((l) => /\.(go|exs?|tsx?|jsx?|mjs)$/.test(l)).sort().join("|");
    return createHash("sha256").update(lines.join("\n") + "##" + dirty).digest("hex").slice(0, 16);
  } catch { return ""; }
}
const NO_COVERAGE = process.argv.slice(2).includes("--no-coverage");
const JS_COVERAGE = process.argv.slice(2).includes("--js-coverage");  // opt-in: run vitest (slow); default ingests existing
const git = (a) => execFileSync("git", a, { cwd: ROOT, encoding: "utf8", maxBuffer: 512 * 1024 * 1024 });
const sig = JSON.parse(readFileSync(join(ROOT, "tooling/file-importance/file-signals.json"), "utf8")).signals;
const churn = Object.fromEntries(sig.map(s => [s.path, s.churn]));

// ---- defect history: commits whose subject signals a fix/revert ----
// The defect vocabulary, as an auditable list (was a dense inline regex). Each
// entry is an alternation term — plain word or a small regex for inflections.
// Bindable via tooling/cody (bug_fix_words) so it can be reviewed/tuned through
// a Barkpark paper. Adding a word widens what counts as a bug-fix → defectDensity.
const BUG_WORDS = ["fix(es|ed)?", "bug", "hotfix", "revert", "regression", "broken", "crash", "patch(ed)?", "incorrect", "wrong", "fault", "defect", "oops", "reverts?"];
const BUG = new RegExp("\\b(" + BUG_WORDS.join("|") + ")\\b", "i");
// how defect-density is derived from a file's bug-fixes and churn. A bound
// FORMULA (cody rung ③) — tunable through a paper, evaluated by lib/formula's
// safe evaluator (no eval). Laplace-smoothed: the prior literal `fixes /
// max(1, churn)` gave a lone fix in a 1-commit file a perfect 1.0, flagging
// trivial files (repo.ex, release.ex) as maximally defect-prone — 53% of the
// "fragile" set was such low-evidence noise. The `+ 3` requires real evidence
// before density climbs; it dropped the fragile set 72 → 24, all genuine
// multi-fix files. Threshold re-tuned in lockstep (thresholds.mjs FRAGILE_DENSITY).
const DEFECT_FORMULA = "fixes / (churn + 3)";
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
const read = (f) => { try { return readFileSync(join(ROOT, f), "utf8"); } catch { return ""; } };
// basename -> full path, first match wins (same presence semantics as the old
// testBasenames Set, but keeps a path so the sibling's source can be read for
// assertion-density scoring — see test-proxy.mjs).
const testBasenameToPath = new Map();
for (const tf of testFiles) { const bn = basename(tf); if (!testBasenameToPath.has(bn)) testBasenameToPath.set(bn, tf); }
const testCorpus = testFiles.map(read).join("\n").toLowerCase();

// The sibling test file's path for `f`, or null if none exists.
function siblingTestPath(f) {
  const b = basename(f).replace(/\.[^.]+$/, "");
  for (const suf of ["_test.exs", "_test.go", "_test.ts", ".test.ts", ".test.tsx", ".spec.ts", ".test.js"]) {
    const p = testBasenameToPath.get(b + suf);
    if (p) return p;
  }
  return null;
}
function modToken(f, txt) {
  if (/\.exs?$/.test(f)) { const m = txt.match(/defmodule\s+([\w.]+)/); return m ? m[1] : null; }
  return null;
}

// ---- source (code, non-test) file universe ----
const code = sig.filter(s => s.kind === "code");

// ---- REAL coverage (v2 Phase 1): measured for Go + Elixir, best-effort ----
// realCov: path -> { pct, source }. Per-package (Go) / per-module (Elixir) coverage
// is mapped down onto each source file. Any suite that fails/times out is skipped
// silently — those files keep the presence proxy.
const realCov = {};
// fnCov: path -> [ untested PUBLIC fns (pct < FN_COV_CUTOFF) ]. Sharpens the
// Tested ¬coverage evidence — a 0%-covered public fn a high file-% would mask.
// Kept lean (only fns below the cutoff) so the report doesn't bloat with a full
// fn dump. Persisted + cache-restored exactly like realCov (zero-cost re-run).
const fnCov = {};
const FN_COV_CUTOFF = 50;
let goPct = null, exPct = null, jsPct = null;
function tryRun(cmd, a, opts) {
  // 30-min ceiling: the full `mix test --cover` suite prints its coverage table
  // only at the very end, so a too-short timeout (was 300_000) truncated the run
  // before the table → 0% coverage. Generous so coverage is actually captured.
  try { return execFileSync(cmd, a, { encoding: "utf8", maxBuffer: 256 * 1024 * 1024, timeout: 1_800_000, ...opts }); }
  catch (e) { return (e.stdout || "") + (e.stderr || ""); }  // non-zero exit (e.g. coverage threshold) still yields data
}
const COVSIG = covSig();
const priorRpt = existsSync(join(HERE, "risk-report.json")) ? JSON.parse(readFileSync(join(HERE, "risk-report.json"), "utf8")) : {};
// The cache is only a hit if the prior report actually RAN the heavy suites: a
// --no-coverage run persists JS-only realCov (the free ingest) with a valid sig,
// which must not let the next full run skip go/mix and report null totals.
const covCacheHit = !NO_COVERAGE && COVSIG && priorRpt.coverageSig === COVSIG && priorRpt.realCov && Object.keys(priorRpt.realCov).length
  && (priorRpt.coverageTotals?.go != null || priorRpt.coverageTotals?.elixir != null);
if (covCacheHit) {
  Object.assign(realCov, priorRpt.realCov);
  Object.assign(fnCov, priorRpt.fnCov || {});
  ({ go: goPct = null, elixir: exPct = null, js: jsPct = null } = priorRpt.coverageTotals || {});
  process.stderr.write("[coverage] reused cache — no code/test change (skipped go/mix suites)\n");
}
if (NO_COVERAGE && priorRpt.realCov) {
  // --no-coverage means "skip the heavy suites", not "forget the last real
  // measurement": carry the prior go/elixir coverage forward (JS re-ingests
  // fresh below), so intermediate cheap runs don't degrade Tested to the proxy.
  for (const [p, c] of Object.entries(priorRpt.realCov)) if (c.source !== "js") realCov[p] = c;
  Object.assign(fnCov, priorRpt.fnCov || {});
  ({ go: goPct = null, elixir: exPct = null } = priorRpt.coverageTotals || {});
  if (Object.keys(realCov).length) process.stderr.write("[coverage] --no-coverage: carried forward prior go/elixir measurements\n");
}
if (!NO_COVERAGE && !covCacheHit) {
  // -- Go: `go test -cover ./...` → "ok PKG ... coverage: NN.N% of statements" per package
  if (existsSync(join(ROOT, "go.mod"))) {
    const goOut = tryRun("go", ["test", "-cover", "./..."], { cwd: ROOT });
    const pkgToDir = {};   // import path -> rel dir
    try {
      const idx = JSON.parse(readFileSync(join(ROOT, "tooling/blast-radius/index.json"), "utf8"));
      for (const [d, p] of Object.entries(idx.go?.dirToPkg || {})) pkgToDir[p] = d;
    } catch {}
    let sum = 0, nPkg = 0;
    for (const m of goOut.matchAll(/^(?:ok|---)?\s*(github\.com\/\S+)\s.*coverage:\s*([\d.]+)% of statements/gm)) {
      const dir = pkgToDir[m[1]]; const pct = +m[2];
      sum += pct; nPkg++;
      if (!dir) continue;
      for (const f of code) if (f.path.startsWith(dir + "/") && dirname(f.path) === dir && f.path.endsWith(".go"))
        realCov[f.path] = { pct, source: "go" };
    }
    if (nPkg) goPct = +(sum / nPkg).toFixed(1);
  }
  // -- Elixir: `mix test --cover` → "| NN.NN% | Module |" per module; map module→file
  if (existsSync(join(ROOT, "api/mix.exs"))) {
    const exOut = tryRun("mix", ["test", "--cover"], { cwd: join(ROOT, "api"), env: { ...process.env, MIX_ENV: "test" } });
    const modToFile = {};
    for (const s of code) if (/\.exs?$/.test(s.path)) { const m = read(s.path).match(/defmodule\s+([\w.]+)/); if (m) modToFile[m[1]] = s.path; }
    for (const m of exOut.matchAll(/^\|\s*([\d.]+)%\s*\|\s*([\w.]+)\s*\|/gm)) {
      const f = modToFile[m[2]]; if (f) realCov[f] = { pct: +m[1], source: "elixir" };
    }
    const tot = exOut.match(/^\|\s*([\d.]+)%\s*\|\s*Total\s*\|/m);
    if (tot) exPct = +tot[1];
    // Per-public-fn coverage from the per-module cover HTML `mix test --cover` just
    // wrote (api/cover/Elixir.<Module>.html). FREE (already on disk) — parses the
    // worst-covered public fns so a 0%-fn drags a hot file's Tested finding up.
    for (const [modName, f] of Object.entries(modToFile)) {
      const covHtml = join(ROOT, "api/cover", `Elixir.${modName}.html`);
      if (!existsSync(covHtml)) continue;
      try {
        const fns = elixirFnCov(readFileSync(covHtml, "utf8")).filter(fn => fn.pct < FN_COV_CUTOFF);
        if (fns.length) fnCov[f] = fns;
      } catch {}
    }
  }
}
// -- JS/TS: ingest Istanbul coverage-final.json (vitest --coverage) where present.
//    Reading an existing coverage-final.json is FREE, so it runs even under
//    --no-coverage (which only means "skip the heavy go/mix/vitest suites").
//    --js-coverage additionally RUNS vitest for the core SDK package (slow).
if (!covCacheHit) {
  const covFiles = [];
  const findCov = (dir, depth = 0) => { if (depth > 3) return; let es; try { es = readdirSync(join(ROOT, dir), { withFileTypes: true }); } catch { return; } for (const en of es) { if (en.name === "node_modules" || en.name === "dist" || en.name.startsWith(".")) continue; const rel = join(dir, en.name); if (en.isDirectory()) findCov(rel, depth + 1); else if (en.name === "coverage-final.json") covFiles.push(rel); } };
  for (const r of ["js", "web", "sdk", "packages"]) findCov(r);
  if (!covFiles.length && JS_COVERAGE) { tryRun("pnpm", ["exec", "vitest", "run", "--coverage"], { cwd: join(ROOT, "js/packages/core"), timeout: 120000 }); findCov("js/packages/core"); }
  let jsSum = 0, jsN = 0;
  for (const cf of covFiles) {
    try {
      const cov = JSON.parse(readFileSync(join(ROOT, cf), "utf8"));
      for (const [abs, data] of Object.entries(cov)) {
        const rel = String(abs).replace(ROOT + "/", "").replace(/^\.\//, "");
        const sv = Object.values(data.s || {}); if (!sv.length) continue;
        if (!code.some(f => f.path === rel)) continue;
        const pct = Math.round((sv.filter(c => c > 0).length / sv.length) * 100);
        realCov[rel] = { pct, source: "js" }; jsSum += pct; jsN++;
        // per-public-fn coverage from Istanbul fnMap+f (FREE — same dump) — keep
        // only fns below the cutoff so the report stays lean.
        const fns = jsFnCov(data).filter(fn => fn.pct < FN_COV_CUTOFF);
        if (fns.length) fnCov[rel] = fns;
      }
    } catch {}
  }
  if (jsN) jsPct = +(jsSum / jsN).toFixed(1);
}

// ---- per source (code, non-test) file ----
const out = {};
for (const s of code) {
  const txt = read(s.path);
  const sibPath = siblingTestPath(s.path);
  const has = !!sibPath;
  const mod = modToken(s.path, txt);
  const refs = mod ? Math.max(0, testCorpus.split(mod.toLowerCase()).length - 1) : 0;
  // Gated on the sibling's ACTUAL assertion density, not mere existence —
  // see test-proxy.mjs for the defect this fixes.
  const { score: proxyScore, source: proxySource } = scoreTestProxy(has ? read(sibPath) : null, refs);
  // Prefer REAL coverage when measured; else fall back to the presence proxy.
  const rc = realCov[s.path];
  const testScore = rc ? Math.round(rc.pct) : proxyScore;
  const testCoverageSource = rc ? rc.source : proxySource;
  const fixes = bugFix[s.path] || 0;
  const own = ownership(s.path);
  out[s.path] = { bugFixes: fixes, defectDensity: +(evalFormula(DEFECT_FORMULA, { fixes, churn: churn[s.path] || 1 })).toFixed(2),
    hasTest: has, testRefs: refs, testScore, testCoverageSource,
    realCoverage: rc ? rc.pct : null, proxyScore,
    untestedFns: fnCov[s.path] || [],   // worst public fns (pct < cutoff) — sharpens ¬coverage
    primaryAuthorShare: own.primaryAuthorShare, authorCount: own.authorCount };
}

const report = { at: new Date().toISOString(),
  note: "testScore is REAL coverage (go/elixir) where measured; presence PROXY elsewhere — see testCoverageSource",
  coverageTotals: { go: goPct, elixir: exPct, js: jsPct },
  coverageSig: COVSIG, realCov, fnCov,
  files: out };
writeFileSync(join(HERE, "risk-report.json"), JSON.stringify(report, null, 2));

const vals = Object.values(out);
const untested = vals.filter(v => v.testScore < UNTESTED_SCORE).length;
const fragile = Object.entries(out).filter(([, v]) => v.defectDensity >= FRAGILE_DENSITY).sort((a, b) => b[1].bugFixes - a[1].bugFixes);
const e = (s) => process.stderr.write(s + "\n");
const measured = vals.filter(v => v.testCoverageSource !== "proxy" && v.testCoverageSource !== "proxy-unasserted").length;
e(`risk  ${vals.length} code files`);
e(`  coverage: ${measured} files REAL-measured (go ${goPct ?? "—"}% · elixir ${exPct ?? "—"}% total) · ${vals.length - measured} on presence proxy`);
e(`  test-presence: ${vals.filter(v => v.hasTest).length} have a sibling test · ${untested} score <40 (likely untested)`);
e(`  defect-prone (density ≥${FRAGILE_DENSITY}), top 8:`);
for (const [f, v] of fragile.slice(0, 8)) e(`    ${v.bugFixes} fixes / ${churn[f]} churn = ${v.defectDensity}  ${f}`);
const soloOwned = vals.filter(v => v.authorCount === 1).length;
e(`  ownership: ${soloOwned} file(s) single-author (bus-factor 1)`);
e(`  → risk-report.json`);
