// consensus — the multi-vote verification layer (cqv3-p2).
//
// The agent judgments that drive composites — file CRITICALITY (importance) and
// consistency DRIFT verdicts — were single-vote: one agent's call became the
// score. A plausible-but-wrong verdict survived unchallenged. This module turns
// N independent votes into a consensus + an explicit `contested` flag, so a
// judgment the panel disagrees on is surfaced, not silently averaged.
//
// Vote collection is BACK-COMPATIBLE: a flat results/ dir is one vote; N
// independent passes live in results/vote-1/, results/vote-2/, … The orchestrator
// dispatches the same batch prompt K times into those subdirs (see the
// codebase-quality skill). Zero subdirs → single-vote, exactly as before.
//
// Dependency-free. Pure functions + a fs collector.

import { readFileSync, readdirSync, existsSync, statSync } from "node:fs";
import { join } from "node:path";

// ---- collect votes from a results dir: returns path -> [recordA, recordB, …] ----
// Flat *.json in the dir = vote 0. Each results/vote-*/ subdir = one more vote.
// Each json is an array of records (or {files|results|verdicts:[…]}); `key` pulls
// the id field (e.g. "path" or "file") so votes line up across passes.
export function collectVotes(dir, key = "path") {
  const byKey = {};
  if (!existsSync(dir)) return byKey;
  const push = (rec) => { const k = rec && rec[key]; if (k) (byKey[k] ||= []).push(rec); };
  const ingestFile = (f) => {
    try {
      const raw = JSON.parse(readFileSync(f, "utf8"));
      const arr = Array.isArray(raw) ? raw : raw.files || raw.results || raw.verdicts || [];
      for (const r of arr) push(r);
    } catch { /* malformed vote-file: skip, never crash the merge */ }
  };
  for (const e of readdirSync(dir)) {
    const p = join(dir, e);
    if (e.endsWith(".json")) ingestFile(p);
    else if (e.startsWith("vote-") && statSync(p).isDirectory())
      for (const f of readdirSync(p).filter((x) => x.endsWith(".json"))) ingestFile(join(p, f));
  }
  return byKey;
}

const median = (xs) => { const s = [...xs].sort((a, b) => a - b); const m = s.length >> 1; return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2; };
const mean = (xs) => xs.reduce((a, b) => a + b, 0) / xs.length;

// ---- numeric consensus (e.g. criticality 0–100) ----
// value = median (robust to one outlier vote). agreement = 1 − (stddev / band),
// clamped 0–1. contested when the votes span more than `band` OR agreement < 0.5.
export function numericConsensus(values, { band = 25 } = {}) {
  const xs = values.map(Number).filter(Number.isFinite);
  if (!xs.length) return { value: null, votes: 0, agreement: null, contested: false, spread: null };
  if (xs.length === 1) return { value: xs[0], votes: 1, agreement: 1, contested: false, spread: 0 };
  const mu = mean(xs);
  const sd = Math.sqrt(mean(xs.map((x) => (x - mu) ** 2)));
  const spread = Math.max(...xs) - Math.min(...xs);
  const agreement = Math.max(0, Math.min(1, 1 - sd / band));
  return { value: Math.round(median(xs)), votes: xs.length, agreement: +agreement.toFixed(2), contested: spread > band || agreement < 0.5, spread };
}

// ---- categorical consensus (e.g. drift | intentional | refactor) ----
// value = plurality winner. agreement = winner share. contested when no strict
// majority (winner share ≤ 0.5) and more than one vote.
export function categoricalConsensus(labels) {
  const xs = labels.filter((x) => x != null && x !== "");
  if (!xs.length) return { value: null, votes: 0, agreement: null, contested: false, tally: {} };
  const tally = {};
  for (const x of xs) tally[x] = (tally[x] || 0) + 1;
  const ranked = Object.entries(tally).sort((a, b) => b[1] - a[1]);
  const [winner, n] = ranked[0];
  const share = n / xs.length;
  return { value: winner, votes: xs.length, agreement: +share.toFixed(2), contested: xs.length > 1 && share <= 0.5, tally };
}
