#!/usr/bin/env node
// Co-change (temporal coupling) + three-layer relationship cross-validation.
//
// ROOT: relationships (the co-change edge). SIGNALS.md owns the rule: measure
// each root once, compose only ACROSS roots. Here the THREE relationship edge
// kinds are cross-validated against each other — they are NOT blended into a
// score, they corroborate (or contradict) one another:
//
//   dependency  (the import graph — from barkpark-sync/nodes.json depPaths)
//   intention   (shared objective hub — from intentions-report.json hubs)
//   co-change   (files that change together in the same commit — computed here)
//
// Per file PAIR:
//   ≥2 of the three edges (or all)  → REAL         (an enacted relationship)
//   intention-only                  → ASPIRATIONAL (intended, not yet enacted)
//   co-change-only                  → ACCIDENTAL    (coupling smell)
//   dependency-only                 → STRUCTURAL    (wired, no shared intent/history yet)
//
// Per FILE: an `accidentalCoupling` flag — the file has co-change partners that
// are neither dependency- nor intention-related (a refactor/seam smell).
//
//   node tooling/cochange/cochange.mjs   → cochange-report.json + crossval-report.json
//
// Dependency-free. Derived outputs gitignored. Reads only committed git history
// + the other passes' reports; never touches api/ source or _build/prod.

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: HERE }).toString().trim();
const rd = (p, d) => existsSync(join(ROOT, p)) ? JSON.parse(readFileSync(join(ROOT, p), "utf8")) : d;
const git = (a) => execFileSync("git", a, { cwd: ROOT, encoding: "utf8", maxBuffer: 512 * 1024 * 1024 });
const e = (s = "") => process.stderr.write(s + "\n");

// ──────────── thresholds (cap noise) ────────────
const MAX_FILES_PER_COMMIT = 25;   // sprawling commits (mass renames, format runs) are not coupling signal
const HISTORY_CAP = 4000;          // most recent N commits — bounds the matrix build
const MIN_SUPPORT = 3;             // a pair must co-change in ≥3 commits to count
const MIN_CONFIDENCE = 0.35;       // P(B changes | A changes) — directional, kept as max of both directions
const MIN_FILE_COMMITS = 3;        // ignore files with almost no history (confidence is unstable)
const MAX_PARTNERS = 8;            // per-file partner cap (keep it airy, like the dep graph MAX_DEPS)

// universe = the graph's code files (so pairs line up with dependency edges)
const nodesDoc = rd("tooling/barkpark-sync/nodes.json", { nodes: [] });
const codeNodes = nodesDoc.nodes.filter(n => n.kind !== "intention");
const universe = new Set(codeNodes.map(n => n.path));
if (universe.size === 0) e("[cochange] WARN: empty universe (run generate.mjs first) — emitting empty report");

// ──────────── one git-log pass → per-commit file sets ────────────
const commitFiles = []; // array of string[] (each a commit's touched files, filtered to universe)
const fileCommits = {}; // path → commitCount
{
  let cur = null;
  const SENTINEL = "\x01";
  for (const line of git(["log", "--no-merges", `-n${HISTORY_CAP}`, "--pretty=format:" + SENTINEL + "%h", "--name-only"]).split("\n")) {
    if (line.startsWith(SENTINEL)) { if (cur && cur.length) commitFiles.push(cur); cur = []; }
    else if (cur && line.trim() && universe.has(line.trim())) cur.push(line.trim());
  }
  if (cur && cur.length) commitFiles.push(cur);
}
for (const fs of commitFiles) { const u = [...new Set(fs)]; for (const f of u) fileCommits[f] = (fileCommits[f] || 0) + 1; }

// ──────────── temporal coupling matrix (sparse, undirected pair → support) ────────────
const pairSupport = {}; // "a\x1fb" (a<b) → co-change count
const pairKey = (a, b) => a < b ? a + "\x1f" + b : b + "\x1f" + a;
let skippedSprawl = 0;
for (const fsRaw of commitFiles) {
  const files = [...new Set(fsRaw)];
  if (files.length < 2) continue;
  if (files.length > MAX_FILES_PER_COMMIT) { skippedSprawl++; continue; }
  for (let i = 0; i < files.length; i++)
    for (let j = i + 1; j < files.length; j++) {
      const k = pairKey(files[i], files[j]);
      pairSupport[k] = (pairSupport[k] || 0) + 1;
    }
}

// ──────────── score pairs: support + confidence, threshold to cut noise ────────────
// confidence(A→B) = support / commits(A); we keep max(both directions) so a small
// helper that ALWAYS rides with a hub still surfaces as coupled.
const cochangePairs = {}; // "a\x1fb" → { support, confidence }
const partners = {};      // path → [{path, support, confidence}]
for (const [k, support] of Object.entries(pairSupport)) {
  if (support < MIN_SUPPORT) continue;
  const [a, b] = k.split("\x1f");
  const ca = fileCommits[a] || 0, cb = fileCommits[b] || 0;
  if (ca < MIN_FILE_COMMITS || cb < MIN_FILE_COMMITS) continue;
  const conf = Math.max(support / ca, support / cb);
  if (conf < MIN_CONFIDENCE) continue;
  cochangePairs[k] = { support, confidence: +conf.toFixed(3) };
  (partners[a] ||= []).push({ path: b, support, confidence: +(support / ca).toFixed(3) });
  (partners[b] ||= []).push({ path: a, support, confidence: +(support / cb).toFixed(3) });
}
// cap per-file partners by support (keep the strongest), then alpha for determinism
for (const p of Object.keys(partners)) {
  partners[p] = partners[p]
    .sort((x, y) => y.support - x.support || y.confidence - x.confidence || x.path.localeCompare(y.path))
    .slice(0, MAX_PARTNERS)
    .sort((x, y) => x.path.localeCompare(y.path));
}

// ──────────── the OTHER two edge kinds, as undirected pair sets ────────────
// dependency pairs (from the import graph; either direction → coupled pair)
const depPairs = new Set();
for (const n of codeNodes) for (const dp of (n.depPaths || [])) if (universe.has(dp)) depPairs.add(pairKey(n.path, dp));

// intention pairs (two files share an objective hub → intention-coupled)
const intents = rd("tooling/intentions/intentions-report.json", { hubs: {} });
const intentPairs = new Set();
for (const members of Object.values(intents.hubs || {})) {
  const m = [...new Set(members)].filter(p => universe.has(p));
  // cap hub size contribution: a 60-file hub would emit ~1800 pairs of noise.
  // We only count co-membership when the hub is reasonably focused.
  if (m.length < 2 || m.length > 20) continue;
  for (let i = 0; i < m.length; i++) for (let j = i + 1; j < m.length; j++) intentPairs.add(pairKey(m[i], m[j]));
}

// ──────────── CROSS-VALIDATE every pair that any edge type touches ────────────
const allPairKeys = new Set([...Object.keys(cochangePairs), ...depPairs, ...intentPairs]);
const classify = (dep, intent, coch) => {
  const n = (dep ? 1 : 0) + (intent ? 1 : 0) + (coch ? 1 : 0);
  if (n >= 2) return "REAL";
  if (intent) return "ASPIRATIONAL";
  if (coch) return "ACCIDENTAL";
  if (dep) return "STRUCTURAL";
  return "NONE";
};
const crossval = []; // {a,b,dep,intent,cochange,verdict,support?,confidence?}
const tally = { REAL: 0, ASPIRATIONAL: 0, ACCIDENTAL: 0, STRUCTURAL: 0 };
for (const k of allPairKeys) {
  const [a, b] = k.split("\x1f");
  const dep = depPairs.has(k), intent = intentPairs.has(k), coch = !!cochangePairs[k];
  const verdict = classify(dep, intent, coch);
  if (verdict === "NONE") continue;
  tally[verdict]++;
  crossval.push({ a, b, dep, intent, cochange: coch, verdict, ...(coch ? cochangePairs[k] : {}) });
}
crossval.sort((x, y) => (y.support || 0) - (x.support || 0) || x.a.localeCompare(y.a) || x.b.localeCompare(y.b));

// ──────────── per-FILE accidental-coupling flag ────────────
// A file is accidentally coupled if it has ≥1 co-change partner that is neither a
// dependency nor an intention partner — temporal coupling with no structural or
// intentional reason. That is the canonical "implicit coupling smell."
const fileFlags = {};
for (const p of universe) {
  const ps = partners[p] || [];
  const accidentalPartners = ps.filter(q => {
    const k = pairKey(p, q.path);
    return !depPairs.has(k) && !intentPairs.has(k);
  }).map(q => q.path);
  fileFlags[p] = {
    cochangePartners: ps.length,
    accidentalCoupling: accidentalPartners.length > 0,
    accidentalPartners,
  };
}

// ──────────── emit ────────────
const at = new Date().toISOString();
const head = (() => { try { return git(["rev-parse", "HEAD"]).trim(); } catch { return ""; } })();

writeFileSync(join(HERE, "cochange-report.json"), JSON.stringify({
  at, head,
  thresholds: { MAX_FILES_PER_COMMIT, HISTORY_CAP, MIN_SUPPORT, MIN_CONFIDENCE, MIN_FILE_COMMITS, MAX_PARTNERS },
  stats: {
    commitsScanned: commitFiles.length, sprawlSkipped: skippedSprawl,
    coupledPairs: Object.keys(cochangePairs).length, filesWithPartners: Object.keys(partners).length,
  },
  partners, files: fileFlags,
}, null, 2));

writeFileSync(join(HERE, "crossval-report.json"), JSON.stringify({
  at, head,
  legend: {
    REAL: "≥2 of {dependency, intention, co-change} agree — an enacted relationship",
    ASPIRATIONAL: "intention-only — intended, not yet enacted in code or history",
    ACCIDENTAL: "co-change-only — implicit coupling smell (no dep, no shared intent)",
    STRUCTURAL: "dependency-only — wired, but no shared intent or change history yet",
  },
  tally,
  pairs: crossval,
}, null, 2));

const accFiles = Object.values(fileFlags).filter(f => f.accidentalCoupling).length;
e(`[cochange] ${commitFiles.length} commits scanned (${skippedSprawl} sprawl-skipped) · ${Object.keys(cochangePairs).length} coupled pairs · ${Object.keys(partners).length} files with partners`);
e(`  cross-validation: REAL ${tally.REAL} · ASPIRATIONAL ${tally.ASPIRATIONAL} · ACCIDENTAL ${tally.ACCIDENTAL} · STRUCTURAL ${tally.STRUCTURAL}`);
e(`  accidental-coupling flagged on ${accFiles} file(s)`);
e(`  → cochange-report.json · crossval-report.json`);
