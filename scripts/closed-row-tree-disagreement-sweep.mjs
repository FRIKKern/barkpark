#!/usr/bin/env node
//
// CLOSED-ROW / TREE DISAGREEMENT SWEEP — does a CLOSED row's disposition assert a
// change origin/main does not carry?
// (search vocabulary: closed row sweep, tree-behind-ledger, disposition evidence,
//  stale close, wrong close, false-done, reversed polarity, closed population audit.)
//
// WHY THIS FILE EXISTS. scripts/false-open-sweep.mjs asks the ledger-behind-tree
// question: an OPEN row whose work already merged. That direction is self-correcting —
// a stale open row gets re-verified the moment somebody picks it up. This file asks the
// OTHER direction, the one nothing re-reads:
//
//   A ROW THAT READS STALE GETS RE-VERIFIED. A ROW THAT READS CLOSED GETS NOTHING.
//
// A closed row is invisible to `bp task ready`, invisible to every triage sweep that
// starts from the ready queue, and invisible to the already-fixed check, which only ever
// runs against OPEN rows. If its close_reason asserts a change the tree does not carry,
// the defect it describes is now protected by the record that says it was handled.
// Filed as task-14b17a62a03599a1.
//
// RULE 1, INHERITED FROM THE SIBLING: EVERY EMPTY IS A REFUSAL, NEVER A CLEAN REPORT.
// Zero rows read, an unparseable line, a sample that could not be drawn, a git rev that
// does not resolve — each exits non-zero and says so. There is no path here that prints
// "no disagreements" over a population it never read.
//
// RULE 2: THIS TOOL WRITES NOTHING. No `bp task` write verb, no reopen, no stamp. It
// prints a verdict per row and a human disposes. A DISAGREE is a LEAD, not a ruling:
// a close can be correct for a reason its body does not carry (the change was
// SUPERSEDED, ACCEPTED, or FOLDED into another slice — see the worked example below).
//
// THE POPULATION. A row is CLOSED here when lifecycle_status is done or cancelled, OR
// content.disposition is "closed". Measured 2026-09-12: 7851 of 9509 type:task rows.
//
// THE DETECTOR — three arms over close_reason + disposition_reason, the only two fields
// a closer writes prose into.
//
//   ARM P — FILE PATHS. A repo-relative path with a known extension. The tree is asked
//     `git cat-file -e <rev>:<path>`. Absent => DISAGREE-path: the disposition names a
//     file main does not have.
//
//   ARM S — SYMBOLS. An Elixir MFA (`Barkpark.Tasks.Criteria.merge_gated?/1`) or a
//     backticked identifier. The bare function/identifier name is searched with
//     `git grep -F` at the rev. Absent => DISAGREE-symbol.
//
//   ARM C — COMMIT SHAS. A 7-40 hex token carrying at least one letter AND one digit
//     (a bare digit run is a PR number or a date, not a sha). Resolved with
//     `git rev-parse <sha>^{commit}`, then `git merge-base --is-ancestor <sha> <rev>`.
//     Resolves-but-not-an-ancestor => DISAGREE-sha: the close cites a commit that never
//     reached main (a stacked PR merged into its parent, a branch that was never merged,
//     a squash that rewrote the sha). DOES NOT RESOLVE => UNRESOLVABLE, printed and
//     NOT counted as a finding: a squash-merge destroys the branch sha, so absence of
//     the object is expected and proves nothing.
//
// THE BLIND SPOT, WHICH THE REPORT ALSO PRINTS: a close_reason that names no path, no
// symbol and no sha CANNOT BE CHECKED THIS WAY. It is counted as UNCHECKABLE and is the
// single largest bucket (3007 of 7851 = 38.3% at the 2026-09-12 census). The
// disagreement rate this tool reports is therefore a rate over the CHECKABLE subset,
// and a FLOOR on the true rate, never an estimate of it. Only re-deriving each close
// from source finds the rest.
//
// THE SECOND BLIND SPOT: a named artifact that IS present proves only that the NAME
// survives, not that the asserted BEHAVIOUR did. pds-bl-w47-stamp-tripwire-false-positive
// is the worked example and the positive control: its close_reason names
// `api/lib/barkpark/plugins/tasks.ex` and `Criteria.merge_gated?`, both present, so this
// tool scores it AGREE — and that verdict is CORRECT (the close was a policy ruling, and
// internal/cli/tasks_stamp_cmd.go:711 still carries the unanchored substring test on
// purpose, as a frozen legacy-server fallback). An AGREE here means "nothing this
// instrument can see disagrees", never "the close was right".
//
// SELECTION. Recency-weighted without replacement, deterministic in --seed: a row closed
// today has had the least time to be contradicted, so it is the most likely to disagree.
// Weight = exp(-ageDays / --half-life), drawn by Efraimidis-Spirakis (key = u^(1/w),
// take the top N), so the same --seed + --sample over the same input is byte-reproducible.
//
// USAGE
//   node scripts/closed-row-tree-disagreement-sweep.mjs --selftest
//   bp export --type task > /tmp/tasks.ndjson     # exits 1 with a partial-export
//                                                 # warning; the row count is what
//                                                 # matters, and this tool prints it
//   node scripts/closed-row-tree-disagreement-sweep.mjs \
//       --input /tmp/tasks.ndjson --sample 120 --seed 1 \
//       --include pds-bl-w47-stamp-tripwire-false-positive
//
//   --input <path>     NDJSON of type:task documents (required outside --selftest)
//   --sample <n>       rows to draw (default 100); 0 or "all" sweeps the whole population
//   --seed <n>         PRNG seed (default 1)
//   --half-life <d>    recency weighting half-life in days (default 14)
//   --rev <rev>        git rev to check against (default origin/main)
//   --include <id>     force this doc_id into the sample (repeatable) — the positive
//                      control hook: a sweep that cannot adjudicate a row you KNOW is in
//                      the population is broken, and this is how you make it prove it
//   --repo <path>      repo root for the git calls (default: cwd)
//
// EXIT CODES: 0 clean run (findings or not) · 1 usage · 2 refusal (empty/unparseable
// input, unresolvable rev, empty sample) · 3 selftest failure.

import { readFileSync, existsSync } from "node:fs";
import { execFileSync } from "node:child_process";

const ARGV = process.argv.slice(2);
function flag(name, dflt = null) {
  const i = ARGV.indexOf(`--${name}`);
  if (i === -1) return dflt;
  return ARGV[i + 1] ?? dflt;
}
function flagAll(name) {
  const out = [];
  for (let i = 0; i < ARGV.length; i++) if (ARGV[i] === `--${name}`) out.push(ARGV[i + 1]);
  return out.filter(Boolean);
}
function has(name) { return ARGV.includes(`--${name}`); }

function refuse(msg) {
  console.error(`REFUSED: ${msg}`);
  process.exit(2);
}

// ---------------------------------------------------------------- extraction

const RE_PATH = /\b(?:[A-Za-z0-9_.\-]+\/)+[A-Za-z0-9_.\-]+\.(?:go|ex|exs|heex|sh|mjs|js|ts|tsx|json|yml|yaml|md|sql)\b/g;
const RE_MFA = /\b[A-Z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)*\.([a-z_][A-Za-z0-9_?!]*)\/\d\b/g;
const RE_BACKTICK = /`([A-Za-z_][A-Za-z0-9_.?!]{3,})`/g;
const RE_HEX = /\b[0-9a-f]{7,40}\b/g;

export function looksLikeSha(tok) {
  if (tok.length < 7 || tok.length > 40) return false;
  return /[a-f]/.test(tok) && /[0-9]/.test(tok);
}

export function extractArtifacts(text) {
  const t = text || "";
  const paths = [...new Set((t.match(RE_PATH) || []))];
  const symbols = new Set();
  for (const m of t.matchAll(RE_MFA)) symbols.add(m[1]);
  for (const m of t.matchAll(RE_BACKTICK)) {
    const s = m[1];
    // a backticked path is already ARM P's; a backticked bare word is ARM S's
    if (!s.includes("/") && !/\.(go|ex|exs|sh|mjs|js|ts|json|yml|yaml|md)$/.test(s)) symbols.add(s);
  }
  const shas = [...new Set((t.match(RE_HEX) || []).filter(looksLikeSha))];
  return { paths, symbols: [...symbols], shas };
}

// ---------------------------------------------------------------- sampling

export function mulberry32(a) {
  return function () {
    a |= 0; a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// Efraimidis-Spirakis weighted sampling without replacement: key = u^(1/w).
export function weightedSample(rows, n, seed, weightOf) {
  const rnd = mulberry32(seed);
  const keyed = rows.map((r) => {
    const w = Math.max(weightOf(r), 1e-9);
    const u = Math.max(rnd(), 1e-12);
    return { r, key: Math.pow(u, 1 / w) };
  });
  keyed.sort((a, b) => b.key - a.key);
  return keyed.slice(0, n).map((k) => k.r);
}

// ---------------------------------------------------------------- git

function makeGit(repo, rev) {
  const run = (args) =>
    execFileSync("git", ["-C", repo, ...args], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  let revSha;
  try { revSha = run(["rev-parse", `${rev}^{commit}`]).trim(); }
  catch { refuse(`git rev '${rev}' does not resolve in ${repo} — nothing was checked`); }
  const pathCache = new Map(), symCache = new Map(), shaCache = new Map();
  return {
    revSha,
    hasPath(p) {
      if (pathCache.has(p)) return pathCache.get(p);
      let ok = true;
      try { run(["cat-file", "-e", `${revSha}:${p}`]); } catch { ok = false; }
      pathCache.set(p, ok); return ok;
    },
    hasSymbol(s) {
      if (symCache.has(s)) return symCache.get(s);
      let ok = true;
      try { run(["grep", "-l", "-F", "-e", s, revSha]); } catch { ok = false; }
      symCache.set(s, ok); return ok;
    },
    // "ancestor" | "orphan" | "unresolvable"
    shaState(s) {
      if (shaCache.has(s)) return shaCache.get(s);
      let st;
      try {
        run(["rev-parse", "-q", "--verify", `${s}^{commit}`]);
        try { run(["merge-base", "--is-ancestor", s, revSha]); st = "ancestor"; }
        catch { st = "orphan"; }
      } catch { st = "unresolvable"; }
      shaCache.set(s, st); return st;
    },
  };
}

// ---------------------------------------------------------------- adjudication

export function isClosed(d) {
  return d.lifecycle_status === "done" || d.lifecycle_status === "cancelled" || d.disposition === "closed";
}
export function reasonText(d) {
  return [d.close_reason, d.disposition_reason].filter(Boolean).join("\n");
}
export function closedAt(d) {
  return (d.claim && d.claim.closed_at) || d._updatedAt || d._createdAt || null;
}

function adjudicate(d, git) {
  const text = reasonText(d);
  const { paths, symbols, shas } = extractArtifacts(text);
  if (!paths.length && !symbols.length && !shas.length) {
    return { verdict: "UNCHECKABLE", line: "(close_reason names no path, no symbol and no sha — ARM BLIND)" };
  }
  const missPaths = paths.filter((p) => !git.hasPath(p));
  if (missPaths.length) {
    return { verdict: "DISAGREE-path", line: `names ${missPaths[0]} — absent at ${git.revSha.slice(0, 9)}` };
  }
  const missSyms = symbols.filter((s) => !git.hasSymbol(s));
  if (missSyms.length) {
    return { verdict: "DISAGREE-symbol", line: `names symbol ${missSyms[0]} — no match at ${git.revSha.slice(0, 9)}` };
  }
  const states = shas.map((s) => [s, git.shaState(s)]);
  const orphan = states.find(([, st]) => st === "orphan");
  if (orphan) {
    return { verdict: "DISAGREE-sha", line: `cites ${orphan[0]} — resolves but is NOT an ancestor of ${git.revSha.slice(0, 9)}` };
  }
  const anchor =
    paths[0] ? `path ${paths[0]}` :
    symbols[0] ? `symbol ${symbols[0]}` :
    `sha ${shas[0]} (${states[0][1]})`;
  const unres = states.filter(([, st]) => st === "unresolvable").length;
  return {
    verdict: "AGREE",
    line: `${anchor} present at ${git.revSha.slice(0, 9)}` + (unres ? ` · ${unres} sha(s) UNRESOLVABLE, not counted` : ""),
  };
}

// ---------------------------------------------------------------- selftest

function selftest() {
  let fails = 0;
  const eq = (name, got, want) => {
    const g = JSON.stringify(got), w = JSON.stringify(want);
    if (g !== w) { console.error(`FAIL ${name}\n  got  ${g}\n  want ${w}`); fails++; }
    else console.log(`ok   ${name}`);
  };
  eq("sha: hex with letters+digits", looksLikeSha("70ff34f9fd"), true);
  eq("sha: all digits is a PR/date, not a sha", looksLikeSha("202609011"), false);
  eq("sha: all letters is a word", looksLikeSha("deadbeef".replace(/[0-9]/g, "a")), false);
  eq("sha: too short", looksLikeSha("70ff3"), false);

  const a = extractArtifacts(
    "see api/lib/barkpark/tasks/criteria.ex and Barkpark.Tasks.Criteria.merge_gated?/1, PR #13006 70ff34f9fd"
  );
  eq("path extracted", a.paths, ["api/lib/barkpark/tasks/criteria.ex"]);
  eq("mfa function extracted", a.symbols, ["merge_gated?"]);
  eq("sha extracted, PR number rejected", a.shas, ["70ff34f9fd"]);

  const b = extractArtifacts("closed as duplicate of the earlier row, nothing shipped");
  eq("blind spot: nothing extractable", [b.paths.length, b.symbols.length, b.shas.length], [0, 0, 0]);

  // the sample must be deterministic in the seed and must differ across seeds
  const rows = Array.from({ length: 50 }, (_, i) => ({ _id: `r${i}`, w: (i % 5) + 1 }));
  const s1 = weightedSample(rows, 10, 7, (r) => r.w).map((r) => r._id);
  const s1b = weightedSample(rows, 10, 7, (r) => r.w).map((r) => r._id);
  const s2 = weightedSample(rows, 10, 8, (r) => r.w).map((r) => r._id);
  eq("sample is deterministic in the seed", s1, s1b);
  eq("a different seed draws a different sample", s1.join() !== s2.join(), true);
  // recency weighting must actually bias: weight 5 rows should be over-represented
  const heavy = weightedSample(rows, 10, 3, (r) => Math.pow(4, r.w)).filter((r) => r.w >= 4).length;
  eq("weighting biases toward heavy rows (>=7 of 10)", heavy >= 7, true);

  eq("isClosed: done", isClosed({ lifecycle_status: "done" }), true);
  eq("isClosed: cancelled", isClosed({ lifecycle_status: "cancelled" }), true);
  eq("isClosed: disposition closed on an open row", isClosed({ lifecycle_status: "open", disposition: "closed" }), true);
  eq("isClosed: plain open", isClosed({ lifecycle_status: "open" }), false);

  if (fails) { console.error(`\nSELFTEST FAILED: ${fails} assertion(s)`); process.exit(3); }
  console.log("\nselftest: all assertions passed");
  process.exit(0);
}

// ---------------------------------------------------------------- main

if (has("selftest")) selftest();

const input = flag("input");
if (!input) { console.error("usage: --input <tasks.ndjson>  (or --selftest)"); process.exit(1); }
if (!existsSync(input)) refuse(`--input ${input} does not exist`);

const repo = flag("repo", process.cwd());
const rev = flag("rev", "origin/main");
const seed = Number(flag("seed", "1"));
const halfLife = Number(flag("half-life", "14"));
const sampleArg = String(flag("sample", "100"));
const includes = flagAll("include");
if (!Number.isFinite(seed) || !Number.isFinite(halfLife) || halfLife <= 0) {
  console.error("usage: --seed and --half-life must be numbers, --half-life > 0"); process.exit(1);
}

const raw = readFileSync(input, "utf8").split("\n").filter((l) => l.trim());
if (!raw.length) refuse(`--input ${input} holds ZERO lines — an empty read is not a clean sweep`);

const docs = [];
raw.forEach((line, i) => {
  let d;
  try { d = JSON.parse(line); }
  catch (e) { refuse(`--input ${input} line ${i + 1} is not JSON (${e.message}) — a partially parsed population is not a population`); }
  docs.push(d);
});

const closed = docs.filter(isClosed);
if (!closed.length) refuse(`ZERO closed rows in ${docs.length} documents — refusing to report a clean sweep over an unread population`);

const now = Date.now();
const ageDays = (d) => {
  const t = closedAt(d);
  const ms = t ? Date.parse(t) : NaN;
  return Number.isFinite(ms) ? Math.max((now - ms) / 86400000, 0) : 3650;
};
const weightOf = (d) => Math.exp(-ageDays(d) / halfLife);

const wantAll = sampleArg === "all" || Number(sampleArg) === 0;
const n = wantAll ? closed.length : Number(sampleArg);
if (!wantAll && (!Number.isFinite(n) || n < 1)) { console.error("usage: --sample must be a positive number, 0, or 'all'"); process.exit(1); }

const byId = new Map(closed.map((d) => [d._id, d]));
const pinned = [];
for (const id of includes) {
  const d = byId.get(id) || byId.get(`drafts.${id}`);
  if (!d) refuse(`--include ${id} is NOT in the closed population of ${input} — the positive control could not be placed, so this run proves nothing`);
  pinned.push(d);
}
const pinnedIds = new Set(pinned.map((d) => d._id));
const drawn = weightedSample(closed.filter((d) => !pinnedIds.has(d._id)), Math.max(n - pinned.length, 0), seed, weightOf);
const sample = [...pinned, ...drawn];
if (!sample.length) refuse("the sample is EMPTY — nothing was checked");

const git = makeGit(repo, rev);

console.log(`# closed-row / tree disagreement sweep`);
console.log(`# input        ${input}  (${docs.length} documents read)`);
console.log(`# population   ${closed.length} CLOSED rows (done | cancelled | disposition:closed)`);
console.log(`# sample       ${sample.length}  seed=${seed}  half-life=${halfLife}d  pinned=${pinned.length}`);
console.log(`# rev          ${rev} = ${git.revSha}`);
console.log(`# repo         ${repo}`);
console.log("");

const counts = { AGREE: 0, UNCHECKABLE: 0, "DISAGREE-path": 0, "DISAGREE-symbol": 0, "DISAGREE-sha": 0 };
const findings = [];
for (const d of sample) {
  const { verdict, line } = adjudicate(d, git);
  counts[verdict] = (counts[verdict] || 0) + 1;
  const pin = pinnedIds.has(d._id) ? " [PINNED]" : "";
  const age = ageDays(d).toFixed(0);
  console.log(`${verdict}\t${d._id}\t(closed ${age}d ago)${pin}\t${line}`);
  if (verdict.startsWith("DISAGREE")) findings.push({ id: d._id, verdict, line });
}

const checkable = sample.length - counts.UNCHECKABLE;
const dis = counts["DISAGREE-path"] + counts["DISAGREE-symbol"] + counts["DISAGREE-sha"];
console.log("");
console.log(`# ---- counts`);
console.log(`# sampled        ${sample.length}`);
console.log(`# UNCHECKABLE    ${counts.UNCHECKABLE}   (the named blind spot: no path, no symbol, no sha)`);
console.log(`# checkable      ${checkable}`);
console.log(`# AGREE          ${counts.AGREE}`);
console.log(`# DISAGREE-path  ${counts["DISAGREE-path"]}`);
console.log(`# DISAGREE-sym   ${counts["DISAGREE-symbol"]}`);
console.log(`# DISAGREE-sha   ${counts["DISAGREE-sha"]}`);
console.log(`# rate           ${dis}/${checkable} checkable = ${checkable ? ((100 * dis) / checkable).toFixed(1) : "n/a"}%  (a FLOOR; ${counts.UNCHECKABLE} rows this instrument cannot see)`);
if (findings.length) {
  console.log(`#`);
  console.log(`# ---- leads (a DISAGREE is a LEAD, not a ruling — a close can be right for a reason its body does not carry)`);
  for (const f of findings) console.log(`#   ${f.id}  ${f.verdict}  ${f.line}`);
}
process.exit(0);
