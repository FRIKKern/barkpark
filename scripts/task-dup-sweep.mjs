#!/usr/bin/env node
// task-dup-sweep — measure duplicate FILINGS on the Barkpark task ledger, and say
// plainly where the measurement stops being a rate.
//
// WHY THIS EXISTS. The create-path dedup wall (api/lib/barkpark/tasks/similarity.ex)
// scores 0.7*Jaccard(title+description tokens) + 0.3*Jaccard(labels). Measured
// 2026-09-13 against the two HUMAN-CONFIRMED duplicate pairs, Jaccard over title
// tokens scores them 0.192 and 0.056 — far below any usable threshold. An
// instrument that scores its own known positives near zero cannot measure the rate
// it is asked about (task-9e7825bd4c8895bf c1; this is task-a8eec40f9ae36364).
//
// WHAT CHANGED. Three things, none of them a threshold tweak:
//   1. TEXT: description + every acceptance criterion, NOT the title. The two known
//      pairs describe the same defect in different title vocabulary.
//   2. WEIGHTING: IDF-weighted cosine, not Jaccard. Jaccard divides by the UNION, so
//      a long row and a short row describing the same defect are punished for their
//      length difference, and a shared rare term ("epoch", "landed") counts exactly
//      as much as a shared filler term. Cosine over tf-idf does neither.
//   3. NORMALISATION: light suffix stemming plus hex/numeric-id stripping, so
//      "stamps"/"stamping"/"stamped" are one term and doc ids are not terms at all.
//
// WHAT IT MEASURES, AND WHAT IT REFUSES TO CLAIM (run 2026-09-13, 9,210 rows).
// FLOOR: at least 208 duplicate-shaped pairs in 126 groups among 9,184 comparable
// rows (1.37%) at the tight operating point. NOT A RATE: the operating point
// calibrated to SEE the two known pairs reports 26,595 pairs — 2.9 per row —
// whose transitive closure swallows 7,666 of 9,184 rows. So the honest verdict is
// that at the recall this ledger needs, text similarity yields a CANDIDATE POOL
// and only a reader can turn it into a count. What the script DOES buy is the
// pool size for that recall: the lexical wall needs the top 1,065 neighbours of a
// row to contain its known twin; this needs the top 15.
//
// NO NETWORK, NO DEPENDENCIES. The similarity is computed here, from the corpus you
// hand it. "Semantic" in the row's sense means "not keyed on the name" — it is not
// an embedding service, and it deliberately is not, because this runs in CI.
//
// USAGE
//   bp task ls --all -o json > /tmp/ledger.json
//   node scripts/task-dup-sweep.mjs --corpus /tmp/ledger.json
//   node scripts/task-dup-sweep.mjs --selftest      # calibration + vacuity, offline
//
// EXIT CODES: 0 ok · 2 usage/IO · 3 VACUITY REFUSAL · 4 selftest failure.

import fs from 'node:fs';
import path from 'node:path';
import url from 'node:url';

const HERE = path.dirname(url.fileURLToPath(import.meta.url));

// ── normalisation ───────────────────────────────────────────────────────────
const STOP = new Set(`a an the of to for and or in on at by with from is are be this that these
those it its as into per via not no yes we our you your they their can will should must would
could may might do does did done has have had was were been being he she him her them us me my
if then than also each any all one two three both only same onto over under out off up down but
so such there here what which who whom whose why how when where while after before because about
above below between during through against within without across upon whether either neither
task tasks row rows add fix update use make build run new open close closed thing things work
works working case cases need needs needed want wants just like more most less least very much
many few other others another something anything nothing everything way ways time times`
  .split(/\s+/).filter(Boolean));

const HEXID = /^[0-9a-f]{8,}$/;

function stem(w) {
  for (const suf of ['ingly', 'edly', 'ing', 'ies', 'ied', 'ed', 'es', 'ly', 's']) {
    if (w.endsWith(suf) && w.length - suf.length >= 4) {
      let base = w.slice(0, -suf.length);
      if (suf === 'ies' || suf === 'ied') base += 'y';
      return base;
    }
  }
  return w;
}

export function tokenize(text) {
  const out = [];
  for (const raw of String(text || '').toLowerCase().match(/[a-z0-9]+/g) || []) {
    if (raw.length < 3) continue;
    if (/^[0-9]+$/.test(raw)) continue;   // bare numbers: run ids, PR numbers, dates
    if (HEXID.test(raw)) continue;        // doc-id suffixes: 259bada0f2e65815
    if (STOP.has(raw)) continue;
    const s = stem(raw);
    if (s.length < 3 || STOP.has(s)) continue;
    out.push(s);
  }
  return out;
}

// The row's text is description + criteria. NOT the title — the whole finding
// behind this script is that the two known pairs share almost no title words.
export function docText(doc) {
  const c = doc.content || {};
  const crits = (c.acceptance_criteria || []).map((x) => x.criterion || '').join('\n');
  return `${c.description || ''}\n${crits}`;
}

// ── tf-idf cosine ───────────────────────────────────────────────────────────
// `frozenIdf` pins the term weights to a dated full-ledger read. The selftest
// passes it, so the fixture scores the known pairs at the SAME numbers a live
// 9,210-row run scores them — without it a 240-row fixture invents its own IDF
// and the calibration measures the fixture, not the instrument.
function buildVectors(docs, frozenIdf) {
  const df = new Map();
  const counts = docs.map((d) => {
    const m = new Map();
    for (const t of tokenize(docText(d))) m.set(t, (m.get(t) || 0) + 1);
    for (const t of m.keys()) df.set(t, (df.get(t) || 0) + 1);
    return m;
  });
  const N = docs.length;
  const idf = new Map();
  const unseen = Math.log(N + 1) + 1;
  for (const [t, d] of df) {
    idf.set(t, frozenIdf ? (frozenIdf[t] ?? unseen) : Math.log((N + 1) / (d + 1)) + 1);
  }

  const vecs = counts.map((m) => {
    const v = new Map();
    let norm = 0;
    for (const [t, n] of m) {
      const w = (1 + Math.log(n)) * idf.get(t);
      v.set(t, w);
      norm += w * w;
    }
    norm = Math.sqrt(norm);
    if (norm > 0) for (const [t, w] of v) v.set(t, w / norm);
    return v;
  });
  return { vecs, df, idf, N };
}

export function cosine(a, b) {
  const [small, big] = a.size <= b.size ? [a, b] : [b, a];
  let s = 0;
  for (const [t, w] of small) {
    const o = big.get(t);
    if (o !== undefined) s += w * o;
  }
  return s;
}

// ── candidate pairs ─────────────────────────────────────────────────────────
// Full O(N^2) is 42M pairs at 9k rows. Instead: index each row under its
// TOP_TERMS highest-weight terms, skipping terms so common they index half the
// ledger. Two rows are compared iff they share one such term. This is the
// instrument's main blind spot and it is printed in the limitations block.
const TOP_TERMS = 30;
const MAX_POSTING = 600;
const EXHAUSTIVE_UNDER = 2000;

function candidatePairs(vecs, maxDf, df) {
  // Under EXHAUSTIVE_UNDER rows, compare every pair: the blocking index exists
  // only because 9k rows is 42M pairs. On a small corpus the index's own
  // top-term cut is the sampling error, so skip it.
  if (vecs.length <= EXHAUSTIVE_UNDER) {
    const all = new Set();
    for (let a = 0; a < vecs.length; a++) {
      for (let b = a + 1; b < vecs.length; b++) all.add(a * 1e7 + b);
    }
    return { pairs: all, skippedTerms: 0 };
  }
  const index = new Map();
  vecs.forEach((v, i) => {
    const terms = [...v.entries()]
      .filter(([t]) => (df.get(t) || 0) <= maxDf)
      .sort((x, y) => y[1] - x[1])
      .slice(0, TOP_TERMS);
    for (const [t] of terms) {
      if (!index.has(t)) index.set(t, []);
      index.get(t).push(i);
    }
  });
  const pairs = new Set();
  let skippedTerms = 0;
  for (const [, posting] of index) {
    if (posting.length > MAX_POSTING) { skippedTerms += 1; continue; }
    for (let a = 0; a < posting.length; a++) {
      for (let b = a + 1; b < posting.length; b++) {
        pairs.add(posting[a] * 1e7 + posting[b]);
      }
    }
  }
  return { pairs, skippedTerms };
}

// ── the sweep ───────────────────────────────────────────────────────────────
// THE PREDICATE IS MUTUAL NEAREST-NEIGHBOURHOOD, NOT A GLOBAL THRESHOLD.
//
// Measured 2026-09-13 on a 9,210-row export: a global cut that is low enough to
// admit both known pairs (they score 0.274 and 0.225) also admits ~0.3% of all
// random pairs — over 100,000 of them. A global threshold on this corpus is a
// pool, not a verdict. RANK is the quantity that separates: the known partner is
// the 2nd/3rd and 4th/11th nearest neighbour of its twin out of 9,184 rows, so a
// pair is reported only when EACH row is within the other's top-K AND the score
// clears a floor. The same rank measurement on the lexical wall's own score
// (0.7*Jaccard(title+desc) + 0.3*Jaccard(labels)) puts those partners at rank
// 9/955 and 14/1065 — a pool 97x larger for the same recall. That ratio, not a
// threshold tweak, is what this script buys.
// TWO OPERATING POINTS, both printed by every run. They answer different
// questions and neither answers the other's.
//   RECALL — the point calibrated to SEE the two known duplicate pairs. It is a
//            candidate pool a reader adjudicates, NOT a verdict: measured
//            2026-09-13 it reports 26,595 pairs over 9,184 comparable rows.
//   TIGHT  — near-identical rows only. Its count is the reportable FLOOR on
//            duplicate-shaped pairs; it does NOT see either known pair.
export const RECALL = { topK: 15, floor: 0.20 };
export const TIGHT = { topK: 3, floor: 0.60 };
export const TOP_K = RECALL.topK;
export const FLOOR = RECALL.floor;

export function sweep(docs, opts = {}) {
  const floor = opts.floor ?? FLOOR;
  const topK = opts.topK ?? TOP_K;
  const total = docs.length;

  // UNCHECKABLE: a row with no description and no criteria has no text to
  // compare. It is not "not a duplicate" — it is unmeasured, which is why the
  // headline number is reported as a FLOOR.
  const comparable = [];
  let uncheckable = 0;
  for (const d of docs) {
    if (tokenize(docText(d)).length >= 5) comparable.push(d);
    else uncheckable += 1;
  }

  // ── VACUITY FLOOR ──
  // A sweep that compares nothing reports a beautiful zero and is
  // indistinguishable from a clean ledger. Refuse instead.
  if (total === 0) return { refused: 'corpus read returned 0 rows' };
  if (comparable.length < 2) {
    return { refused: `only ${comparable.length} of ${total} rows carry comparable text (need >= 2)` };
  }

  const { vecs, df } = buildVectors(comparable, opts.idf);
  const maxDf = Math.max(2, Math.floor(comparable.length * 0.05));
  const { pairs, skippedTerms } = (opts.pairsHook || candidatePairs)(vecs, maxDf, df);

  if (pairs.size === 0) return { refused: 'zero pairs were compared' };

  // Score every candidate pair once, keeping each row's top-K neighbours.
  const nbrs = comparable.map(() => []);
  let excludedSiblings = 0;
  let scored = 0;
  const simOf = new Map();
  for (const key of pairs) {
    const i = Math.floor(key / 1e7);
    const j = key % 1e7;
    const A = comparable[i];
    const B = comparable[j];
    if (A.parent_id && B.parent_id && A.parent_id === B.parent_id) { excludedSiblings += 1; continue; }
    const sim = cosine(vecs[i], vecs[j]);
    scored += 1;
    if (sim < floor) continue;
    simOf.set(key, sim);
    push(nbrs[i], j, sim, topK);
    push(nbrs[j], i, sim, topK);
  }

  if (scored === 0) return { refused: 'zero pairs survived exclusion — nothing was compared' };

  const inTop = nbrs.map((l) => {
    l.sort((a, b) => b.sim - a.sim);
    return new Set(l.slice(0, topK).map((e) => e.j));
  });
  const hits = [];
  for (const [key, sim] of simOf) {
    const i = Math.floor(key / 1e7);
    const j = key % 1e7;
    if (inTop[i].has(j) && inTop[j].has(i)) hits.push({ a: comparable[i], b: comparable[j], sim });
  }
  hits.sort((x, y) => y.sim - x.sim);

  const gaps = hits.map((h) => Math.abs(
    (Date.parse(h.a.inserted_at) - Date.parse(h.b.inserted_at)) / 86400000)).sort((x, y) => x - y);
  const median = gaps.length
    ? (gaps.length % 2 ? gaps[(gaps.length - 1) / 2] : (gaps[gaps.length / 2 - 1] + gaps[gaps.length / 2]) / 2)
    : null;

  // Transitive closure. A family of 14 machine-generated rows is ONE group, not
  // 91 pairs; and a closure that swallows most of the ledger is itself the
  // verdict that the operating point is too loose to count anything.
  const parent = new Map();
  const find = (x) => { while (parent.get(x) !== x) { parent.set(x, parent.get(parent.get(x))); x = parent.get(x); } return x; };
  for (const h of hits) {
    for (const id of [h.a.doc_id, h.b.doc_id]) if (!parent.has(id)) parent.set(id, id);
    const ra = find(h.a.doc_id); const rb = find(h.b.doc_id);
    if (ra !== rb) parent.set(ra, rb);
  }
  const sizes = new Map();
  for (const id of parent.keys()) { const r = find(id); sizes.set(r, (sizes.get(r) || 0) + 1); }
  const groups = sizes.size;
  const largestGroup = sizes.size ? Math.max(...sizes.values()) : 0;

  const at = (id) => comparable.findIndex((d) => d.doc_id === id);
  return {
    floor, topK, total, comparable: comparable.length, uncheckable,
    pairsCompared: scored, excludedSiblings, skippedTerms, maxDf,
    hits, medianGapDays: median, groups, largestGroup,
    // Score and mutual-rank accessors — the selftest asserts on these, so the
    // calibration measures the SAME numbers a real run reports.
    scoreOf: (x, y) => {
      const i = at(x); const j = at(y);
      return i < 0 || j < 0 ? null : cosine(vecs[i], vecs[j]);
    },
    reported: (x, y) => hits.some((h) =>
      (h.a.doc_id === x && h.b.doc_id === y) || (h.a.doc_id === y && h.b.doc_id === x)),
    rankOf: (x, y) => {
      const i = at(x); const j = at(y);
      if (i < 0 || j < 0) return null;
      const s = cosine(vecs[i], vecs[j]);
      let better = 0;
      for (let k = 0; k < comparable.length; k++) {
        if (k === i) continue;
        const A = comparable[i]; const B = comparable[k];
        if (A.parent_id && B.parent_id && A.parent_id === B.parent_id) continue;
        if (cosine(vecs[i], vecs[k]) > s) better += 1;
      }
      return better + 1;
    },
  };
}

function push(list, j, sim, topK) {
  list.push({ j, sim });
  if (list.length > topK * 4) {
    list.sort((a, b) => b.sim - a.sim);
    list.length = topK;
  }
}

// ── reporting ───────────────────────────────────────────────────────────────
function fmt(n, d = 3) { return Number(n).toFixed(d); }

function block(res, label, note) {
  const L = [];
  L.push(`${label}  (top-K ${res.topK}, floor ${fmt(res.floor)})  — ${note}`);
  L.push(`  pairs reported            ${res.hits.length}`);
  L.push(`  groups (transitive)       ${res.groups}`);
  L.push(`  largest group             ${res.largestGroup} rows`);
  L.push(`  median filing gap         ${res.medianGapDays === null ? 'n/a' : `${fmt(res.medianGapDays, 1)} days`}`);
  return L;
}

function report(recall, tight, meta) {
  const L = [];
  L.push(`MEASUREMENT task-dup-sweep · run ${new Date().toISOString()} · corpus ${meta.corpus}`);
  L.push('DERIVATION: tf-idf cosine over (description + acceptance criteria) — stemmed,');
  L.push(`  stopworded, doc-id and bare-number tokens stripped; candidates from the top-${TOP_TERMS}`);
  L.push(`  rarest terms per row (df <= ${recall.maxDf}); same-parent pairs excluded as siblings; a pair`);
  L.push("  is reported only when each row is inside the other's top-K AND clears the floor.");
  L.push('');
  L.push('DENOMINATOR');
  L.push(`  rows in corpus            ${recall.total}`);
  L.push(`  comparable rows           ${recall.comparable}   <- the denominator`);
  L.push(`  UNCHECKABLE rows          ${recall.uncheckable}  (no description and no criteria text)`);
  L.push(`  pairs scored              ${recall.pairsCompared}`);
  L.push(`  excluded as siblings      ${recall.excludedSiblings}  (same parent_id — epic decomposition, not duplication)`);
  L.push('');
  L.push(...block(recall, 'RECALL POINT', 'calibrated to SEE the two known duplicate pairs'));
  L.push('');
  L.push(...block(tight, 'TIGHT POINT ', 'near-identical rows only; sees NEITHER known pair'));
  L.push('');
  L.push('THE MEASUREMENT, STATED HONESTLY');
  L.push(`  FLOOR: at least ${tight.hits.length} duplicate-shaped pairs in ${tight.groups} groups exist among`);
  L.push(`  ${recall.comparable} comparable rows (${fmt(100 * tight.groups / recall.comparable, 2)}% of rows sit in such a group).`);
  L.push('  NOT A RATE: the operating point that sees the two HUMAN-CONFIRMED pairs reports');
  L.push(`  ${recall.hits.length} pairs — ${fmt(recall.hits.length / recall.comparable, 1)} per comparable row — whose transitive closure`);
  L.push(`  swallows ${recall.largestGroup} of ${recall.comparable} rows. At the recall this ledger needs, text similarity`);
  L.push('  produces a CANDIDATE POOL, not a duplicate count. Anyone quoting a duplicate');
  L.push('  RATE off this script is quoting the pool.');
  L.push('');
  L.push(`TOP PAIRS AT THE TIGHT POINT (${Math.min(tight.hits.length, meta.top)} of ${tight.hits.length})`);
  for (const h of tight.hits.slice(0, meta.top)) {
    const gap = Math.abs((Date.parse(h.a.inserted_at) - Date.parse(h.b.inserted_at)) / 86400000);
    L.push(`  ${fmt(h.sim)}  ${h.a.doc_id} [${h.a.lifecycle_status}] / ${h.b.doc_id} [${h.b.lifecycle_status}]  gap ${fmt(gap, 1)}d`);
    L.push(`         A: ${String(h.a.title || '').slice(0, 110)}`);
    L.push(`         B: ${String(h.b.title || '').slice(0, 110)}`);
  }
  L.push('');
  L.push('WHAT THIS CANNOT CATCH');
  L.push(`  · a duplicate outside its twin's top-${recall.topK} neighbours. Measured 2026-09-13 the harder`);
  L.push('    known pair sits at rank 11 — four rows of margin — so a third pair further out');
  L.push("    is invisible, and that margin is this instrument's live risk.");
  L.push('  · a pair sharing NO rare term: two rows describing one defect entirely in each');
  L.push("    other's synonyms. This is lexical-with-weighting, NOT an embedding. No network.");
  L.push('  · a duplicate filed under the same parent — excluded by design as epic slicing.');
  L.push('  · a row with no description and no criteria (the UNCHECKABLE count above).');
  L.push('  · intent. Every reported pair is a candidate; only a reader can call it a duplicate.');
  L.push('  · a duplicate of work that was never filed as a task at all.');
  return L.join('\n');
}

// ── selftest ────────────────────────────────────────────────────────────────
const FIXTURE = path.join(HERE, 'fixtures', 'task-dup-sweep-selftest.json');

function selftest() {
  const fx = JSON.parse(fs.readFileSync(FIXTURE, 'utf8'));
  const base = fx.corpus;
  const fails = [];
  const say = (ok, name, detail) => {
    console.log(`  ${ok ? 'PASS' : 'FAIL'}  ${name}  ${detail}`);
    if (!ok) fails.push(name);
  };

  console.log(`task-dup-sweep --selftest  (fixture frozen ${fx.frozen_at}, ${base.length} rows)`);
  console.log(`RECALL topK=${RECALL.topK} floor=${fmt(RECALL.floor)} · TIGHT topK=${TIGHT.topK} floor=${fmt(TIGHT.floor)}`);
  console.log(`term weights pinned to the frozen ledger IDF (${Object.keys(fx.idf).length} terms) — fixture scores == live scores`);
  console.log('');

  // ARM 1 — VACUITY: an empty corpus must REFUSE, not report a clean zero.
  console.log('ARM vacuity/empty-corpus');
  {
    const r = sweep([]);
    say(!!r.refused, 'vacuity/empty-corpus', r.refused ? `refused: ${r.refused}` : 'RETURNED A RESULT for 0 rows');
  }

  // ARM 2 — VACUITY: pair generation that yields nothing must REFUSE.
  console.log('ARM vacuity/zero-pairs');
  {
    const r = sweep(base, { ...RECALL, idf: fx.idf, pairsHook: () => ({ pairs: new Set(), skippedTerms: 0 }) });
    say(!!r.refused, 'vacuity/zero-pairs', r.refused ? `refused: ${r.refused}` : 'RETURNED A RESULT having compared 0 pairs');
  }

  const rec = sweep(base, { ...RECALL, idf: fx.idf });
  const tig = sweep(base, { ...TIGHT, idf: fx.idf });
  if (rec.refused || tig.refused) {
    console.log(`  FAIL  fixture/sweep  refused on the fixture: ${rec.refused || tig.refused}`);
    console.log('\nSELFTEST FAILED: the fixture corpus is unusable.');
    return 4;
  }

  // ARM 3 — KNOWN POSITIVES at the recall point. This arm is the whole reason
  // the script exists: the create-path lexical wall scores these two pairs 0.109
  // and 0.077 against its own 0.55 refuse threshold, and ranks the partner 955th
  // and 1065th of 9,209. Here they must be REPORTED.
  console.log('ARM calibration/known-positives @ RECALL');
  for (const [x, y] of fx.known_positives) {
    const s = rec.scoreOf(x, y);
    const rk = rec.rankOf(x, y);
    const rk2 = rec.rankOf(y, x);
    say(s !== null && rec.reported(x, y), `positive ${x}/${y}`,
      `score ${s === null ? 'MISSING' : fmt(s)}, ranks ${rk}/${rk2} of ${rec.comparable}, reported=${s === null ? 'n/a' : rec.reported(x, y)}`);
  }

  // ARM 4 — KNOWN NEGATIVES, read by hand and judged DISTINCT. They must stay
  // out of the TIGHT point. A threshold set after seeing only positives is a
  // prediction, not a calibration — so this arm also PRINTS whether each
  // negative is reported at the RECALL point, which is exactly why the recall
  // point is documented as a candidate pool rather than a duplicate count.
  console.log('ARM calibration/known-negatives @ TIGHT');
  for (const [x, y] of fx.known_negatives) {
    const s = tig.scoreOf(x, y);
    say(s !== null && !tig.reported(x, y) && s < TIGHT.floor, `negative ${x}/${y}`,
      `score ${s === null ? 'MISSING' : fmt(s)} vs tight floor ${fmt(TIGHT.floor)} (must be under); reported@tight=${s === null ? 'n/a' : tig.reported(x, y)} (must be false), reported@recall=${rec.reported(x, y)}`);
  }

  // ARM 5 — PLANTED DUPLICATE: a row restating an existing row's defect in
  // different phrasing and a different title. Present => caught; absent => never
  // reported. This is the arm that proves the sweep can fail.
  console.log('ARM planted-duplicate');
  {
    const planted = sweep([...base, fx.plant.row], { ...RECALL, idf: fx.idf });
    const caught = !planted.refused && planted.reported(fx.plant.row.doc_id, fx.plant.duplicates);
    const s = planted.refused ? null : planted.scoreOf(fx.plant.row.doc_id, fx.plant.duplicates);
    say(caught, 'planted-duplicate/caught',
      `plant vs ${fx.plant.duplicates}: score ${s === null ? 'MISSING' : fmt(s)}, reported=${caught}`);
    const gone = !rec.hits.some((h) => h.a.doc_id === fx.plant.row.doc_id || h.b.doc_id === fx.plant.row.doc_id);
    say(gone, 'planted-duplicate/removed', 'plant removed from the corpus is absent from the hits');
  }

  console.log('');
  if (fails.length) {
    console.log(`SELFTEST FAILED: ${fails.length} arm(s) red — ${fails.join(', ')}`);
    return 4;
  }
  console.log(`SELFTEST PASSED: all arms green (${base.length}-row fixture).`);
  return 0;
}

// ── main ────────────────────────────────────────────────────────────────────
function main(argv) {
  const args = new Map();
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const k = a.slice(2);
      const v = argv[i + 1] && !argv[i + 1].startsWith('--') ? argv[++i] : 'true';
      args.set(k, v);
    }
  }
  if (args.has('selftest')) return selftest();

  const corpus = args.get('corpus');
  if (!corpus) {
    console.error('usage: task-dup-sweep.mjs --corpus <bp task ls --all -o json output> [--top N]');
    console.error('       task-dup-sweep.mjs --selftest');
    return 2;
  }
  let docs;
  try {
    const parsed = JSON.parse(fs.readFileSync(corpus, 'utf8'));
    docs = Array.isArray(parsed) ? parsed : parsed.docs || [];
  } catch (e) {
    console.error(`could not read corpus ${corpus}: ${e.message}`);
    return 2;
  }
  const rec = sweep(docs, RECALL);
  const tig = sweep(docs, TIGHT);
  const refused = rec.refused || tig.refused;
  if (refused) {
    console.error(`VACUITY REFUSAL: ${refused}`);
    console.error('A sweep that compares nothing reports a clean zero. Refusing to report one.');
    return 3;
  }
  console.log(report(rec, tig, { corpus, top: Number(args.get('top') ?? 20) }));
  return 0;
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(url.fileURLToPath(import.meta.url))) {
  process.exit(main(process.argv.slice(2)));
}
