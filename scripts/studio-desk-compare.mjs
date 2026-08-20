#!/usr/bin/env node
//
// studio-desk-compare.mjs — THE DIFFER.
//
// Compares two `studio-desk-measure.mjs` run artifacts and answers exactly one
// question: **does the candidate run reproduce the baseline, field for field, at
// tolerance ZERO?**
//
//   node scripts/studio-desk-compare.mjs <baseline.json> <candidate.json>
//   node scripts/studio-desk-compare.mjs <baseline.json> <candidate.json> --json
//
//   exit 0  IDENTICAL on the ruling surface
//   exit 1  DIVERGENT on the ruling surface — every differing field printed with both values
//   exit 2  the comparison could not be made (missing/empty/unparseable file, duplicate or
//           unmatched row keys). This is an INSTRUMENT/INPUT failure, never a desk fact.
//
// ── Why this file exists (charter D131, D136, D138) ──────────────────────────
//
// D136 refuses the epic's seal on numbers read out of a committed measurement
// artifact. The one place trust in that artifact was UNEARNED was whether the
// merged instrument still reproduces it. A wave-9 verifier proved it does — in a
// throwaway worktree, committing nothing. That is D131's disease exactly: a proof
// that cannot be retrieved gets re-derived, wrongly, by whoever needs it next.
// This differ is that proof made durable and mechanical: the reproduction claim
// is now re-runnable by anyone with the two files, and its verdict is an exit
// code rather than an agent's sentence.
//
// ── Design rule 1: ROWS ARE KEYED, NEVER INDEXED ─────────────────────────────
//
// Rows are matched on the composite key (viewport_px, inspector_state, face).
// Comparing `baseline.rows[i]` to `candidate.rows[i]` would silently compare
// UNRELATED cells the moment a sweep is reordered — and `--sweep` direction is a
// documented variable of this instrument (`sweep_direction` is recorded in every
// artifact precisely because it can change). A key collision inside ONE file, or
// a key present in one file and absent in the other, HALTS at exit 2 rather than
// being papered over: an unmatched key means the two files do not describe the
// same experiment and no cell-level verdict is meaningful.
//
// ── Design rule 2: TOLERANCE IS ZERO ─────────────────────────────────────────
//
// No epsilon, no rounding, no "close enough". Numbers are compared with
// Object.is (so 0/-0 and NaN are handled explicitly rather than accidentally).
// The justification is specific and it expires if the premise changes: at the
// time of writing, ZERO product code differs between the measured build and
// origin/main, so there is NO honest source of drift. Any difference — including
// 1.2px — must be attributed to a named commit or a named instrument change, or
// it is unexplained and the comparison HALTS. A tolerance would convert exactly
// the signal this epic was twice overturned for missing into noise.
//
// ── Design rule 3: THE VOLATILE LIST IS MINIMAL AND EVERY ENTRY IS ARGUED ────
//
// This list is the dangerous part of the tool and it is a judgment call, not a
// fact. Too NARROW and every run trivially "differs" (the wave-9 verifier
// omitted `measured_at` and got all 54 rows reported as differing, which is
// noise that trains a reader to ignore the tool). Too BROAD and real drift is
// hidden — which is worse, because it is silent. Each entry below therefore
// carries its own reason, and the bar for adding one is: the field is a
// wall-clock reading or a filesystem path of the producing process, and it
// describes the RUN rather than the DESK.
//
// Path syntax: dot-separated, `*` matches one array index or one object key.
const VOLATILE = [
  // ── wall-clock stamps: a second run happens at a different second, by definition
  ['generated_at',                      'wall clock: when the run started'],
  ['rows.*.measured_at',                'wall clock: when this cell was measured'],
  ['provenance.read_at',                'wall clock: the pre-sweep ssh read'],
  ['provenance_post.read_at',           'wall clock: the post-sweep ssh read'],
  ['artifact.written_at',               'wall clock: when the artifact was written'],
  ['artifact.provenance_pre_read_at',   'wall clock: copy of provenance.read_at'],
  ['artifact.provenance_post_read_at',  'wall clock: copy of provenance_post.read_at'],
  ['provenance_bracket.window_ms',      'elapsed wall time between the two ssh reads — a duration, not a desk measure'],
  // ── the ONE per-row timing field. `settle.settled` and `settle.signature` are
  //    NOT exempt and carry the substance: whether the desk reached a stable
  //    layout, and what that layout was. Only the latency to get there is
  //    exempted, and that latency is a network measure.
  ['rows.*.settle.settle_ms',           'network/render latency of the settle poll; settled + signature stay compared'],
  // ── filesystem identity of the PRODUCING process. Two runs from two worktrees
  //    are still two runs of the same instrument; `instrument` and
  //    `playwright_resolved_from` are NOT exempt, so a genuinely different
  //    script or a different Playwright still halts the comparison.
  ['artifact.written_to',               'absolute path of the output file — differs per invocation by construction'],
  ['artifact.invoked_from_cwd',         'absolute path of the producing worktree'],
  ['artifact.instrument_realpath',      'absolute path of the producing worktree'],
  ['artifact.argv',                     'argv of the producing invocation — carries the --out path above'],
];

// ── ADVISORY, not exempt ─────────────────────────────────────────────────────
//
// These subtrees ARE compared and ARE printed, but they do not set exit 1. They
// are not desk geometry: they are frame-sampled or attempt-counted diagnostics
// whose values legitimately move with scheduler timing. Reporting them (rather
// than adding them to VOLATILE) keeps them visible — a reader can see the drift
// and judge it, instead of the tool deciding for them in silence.
const ADVISORY = [
  ['b29_probes',      'requestAnimationFrame sampler: frames_captured and per-frame t_ms move with scheduler timing'],
  ['drill.attempts',  'how many tries it took to open the document — a retry count, not a measurement'],
  ['artifact.drill_attempts', 'copy of drill.attempts'],
];

import fs from 'node:fs';
import path from 'node:path';

const JSON_ONLY = process.argv.includes('--json');

function usage() {
  process.stderr.write(
    'usage: node scripts/studio-desk-compare.mjs <baseline.json> <candidate.json> [--json]\n' +
    '       exit 0 identical · exit 1 divergent · exit 2 comparison impossible\n');
}

/** Load one artifact. A missing, EMPTY, or unparseable file is an INSTRUMENT
 *  FAILURE (exit 2) and says so in those words — never a quiet "no differences".
 *  A zero-byte run is the specific failure mode the merged instrument was fixed
 *  for (#4787), and a differ that shrugged at one would re-open exactly the hole
 *  that fix closed. */
function load(label, file) {
  if (!fs.existsSync(file)) die(`INSTRUMENT/INPUT FAILURE: ${label} artifact does not exist: ${file}`);
  const stat = fs.statSync(file);
  if (stat.size === 0) die(`INSTRUMENT FAILURE: ${label} artifact is ZERO BYTES: ${file}. A run that wrote no bytes measured nothing; this is not a desk fact.`);
  let parsed;
  try {
    parsed = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (err) {
    die(`INSTRUMENT FAILURE: ${label} artifact is not parseable JSON (${stat.size} bytes): ${file}\n  ${err.message}`);
  }
  if (!Array.isArray(parsed?.rows)) die(`INSTRUMENT FAILURE: ${label} artifact has no rows[] array: ${file}`);
  if (parsed.rows.length === 0) die(`INSTRUMENT FAILURE: ${label} artifact has ZERO rows: ${file}`);
  return { file, size: stat.size, run: parsed };
}

function die(msg) {
  process.stderr.write(`\n  ${msg}\n\n`);
  process.exit(2);
}

/** The composite row key. Every component is asserted present: a row missing one
 *  of the three cannot be placed in the matrix at all, and guessing where it
 *  belongs is how index-keyed comparison goes wrong in the first place. */
function rowKey(label, row, i) {
  const { viewport_px, inspector_state, face } = row || {};
  if (viewport_px == null || inspector_state == null || face == null) {
    die(`INSTRUMENT FAILURE: ${label} row ${i} is missing a key component ` +
        `(viewport_px=${viewport_px}, inspector_state=${inspector_state}, face=${face}). Rows cannot be keyed.`);
  }
  return `viewport ${viewport_px} / ${inspector_state} / face ${face}`;
}

function indexRows(label, rows) {
  const map = new Map();
  rows.forEach((row, i) => {
    const key = rowKey(label, row, i);
    if (map.has(key)) {
      die(`INSTRUMENT FAILURE: ${label} contains TWO rows with the same key: ${key} ` +
          `(indices ${map.get(key).i} and ${i}). The matrix is not a function of its key; no cell-level verdict is possible.`);
    }
    map.set(key, { row, i });
  });
  return map;
}

function matchPath(patterns, p) {
  const segs = p.split('.');
  return patterns.some(([pat]) => {
    const ps = pat.split('.');
    if (ps.length > segs.length) return false;
    // prefix match: naming a subtree exempts/advises the whole subtree
    return ps.every((s, i) => s === '*' || s === segs[i]);
  });
}

const isVolatile = (p) => matchPath(VOLATILE, p);
const isAdvisory = (p) => matchPath(ADVISORY, p);

function fmt(v) {
  if (typeof v === 'string') return v.length > 160 ? JSON.stringify(v.slice(0, 157) + '...') : JSON.stringify(v);
  if (v === undefined) return '<absent>';
  const s = JSON.stringify(v);
  return s === undefined ? String(v) : (s.length > 160 ? s.slice(0, 157) + '...' : s);
}

/** Recursive, ZERO-tolerance deep diff. Emits one entry per differing LEAF so a
 *  reader sees the field name and both values, never "objects differ". */
function diff(a, b, prefix, out) {
  if (isVolatile(prefix)) return;
  const bothObj = a && b && typeof a === 'object' && typeof b === 'object' &&
                  Array.isArray(a) === Array.isArray(b);
  if (bothObj) {
    if (Array.isArray(a)) {
      const n = Math.max(a.length, b.length);
      if (a.length !== b.length) out.push({ path: `${prefix}.length`, baseline: a.length, candidate: b.length, advisory: isAdvisory(prefix) });
      for (let i = 0; i < n; i++) diff(a[i], b[i], `${prefix}.${i}`, out);
      return;
    }
    for (const k of new Set([...Object.keys(a), ...Object.keys(b)])) {
      diff(a[k], b[k], prefix ? `${prefix}.${k}` : k, out);
    }
    return;
  }
  // Object.is, not ===: it separates 0 from -0 and makes NaN !== NaN explicit
  // rather than accidental. No epsilon anywhere — see Design rule 2.
  if (!Object.is(a, b)) out.push({ path: prefix, baseline: a, candidate: b, advisory: isAdvisory(prefix) });
}

/** The artifact's own gate fields — the four facts a reader checks before
 *  quoting any cell. Compared explicitly (as well as by the deep diff) so they
 *  are reported even when the deep diff is clean, and so a candidate that fails
 *  them on its OWN terms is called out regardless of the baseline. */
function gateFacts(run) {
  const nv = run.artifact?.non_vacuity_guard ?? {};
  return {
    row_count: run.artifact?.row_count ?? run.rows.length,
    expected_row_count: run.artifact?.expected_row_count ?? null,
    served_sha: run.artifact?.served_sha ?? run.provenance?.served_sha ?? null,
    slot_active: (run.artifact?.slot_active ?? run.provenance?.slot_active ?? []).join(','),
    provenance_bracket_matched: run.provenance_bracket?.matched ?? null,
    guard_applies: nv.applies_in_rows ?? null,
    guard_passed: nv.passed_in_rows ?? null,
    guard_vacuous: nv.vacuous ?? null,
    warning_count: (run.warnings ?? []).length,
    unsettled_rows: run.artifact?.unsettled_rows ?? null,
  };
}

function main() {
  const files = process.argv.slice(2).filter((a) => !a.startsWith('-'));
  if (files.length !== 2) { usage(); process.exit(2); }

  const base = load('baseline', files[0]);
  const cand = load('candidate', files[1]);

  const baseRows = indexRows('baseline', base.run.rows);
  const candRows = indexRows('candidate', cand.run.rows);

  // ── row key set ────────────────────────────────────────────────────────────
  const onlyBase = [...baseRows.keys()].filter((k) => !candRows.has(k));
  const onlyCand = [...candRows.keys()].filter((k) => !baseRows.has(k));
  if (onlyBase.length || onlyCand.length) {
    process.stderr.write('\n  ROW KEY MISMATCH — the two artifacts do not describe the same experiment.\n');
    for (const k of onlyBase) process.stderr.write(`    baseline only : ${k}\n`);
    for (const k of onlyCand) process.stderr.write(`    candidate only: ${k}\n`);
    die(`${onlyBase.length} baseline-only and ${onlyCand.length} candidate-only row keys. No cell-level verdict is possible.`);
  }

  // ── warnings, as SETS (membership, not order) ──────────────────────────────
  const bw = new Set(base.run.warnings ?? []);
  const cw = new Set(cand.run.warnings ?? []);
  const warningsAdded = [...cw].filter((w) => !bw.has(w));
  const warningsRemoved = [...bw].filter((w) => !cw.has(w));

  // ── the ruling surface: every row, keyed ───────────────────────────────────
  const rowDiffs = [];
  for (const key of baseRows.keys()) {
    const out = [];
    diff(baseRows.get(key).row, candRows.get(key).row, 'rows.*', out);
    if (out.length) rowDiffs.push({ key, fields: out });
  }

  // ── everything outside rows[] and outside the warning list ─────────────────
  const stripped = (r) => { const c = { ...r }; delete c.rows; delete c.warnings; return c; };
  const headerDiffs = [];
  diff(stripped(base.run), stripped(cand.run), '', headerDiffs);
  const headerRuling  = headerDiffs.filter((d) => !d.advisory);
  const headerAdvisory = headerDiffs.filter((d) => d.advisory);

  const gb = gateFacts(base.run);
  const gc = gateFacts(cand.run);
  const gateDiffs = Object.keys(gb).filter((k) => !Object.is(gb[k], gc[k]));

  const rowFieldCount = rowDiffs.reduce((n, r) => n + r.fields.length, 0);
  const divergent = rowDiffs.length > 0 || warningsAdded.length > 0 ||
                    warningsRemoved.length > 0 || headerRuling.length > 0 || gateDiffs.length > 0;

  const report = {
    verdict: divergent ? 'DIVERGENT' : 'IDENTICAL',
    tolerance: 'ZERO — no epsilon on any numeric field',
    keyed_by: '(viewport_px, inspector_state, face) — never array index',
    baseline: { file: base.file, bytes: base.size, rows: base.run.rows.length, gate: gb },
    candidate: { file: cand.file, bytes: cand.size, rows: cand.run.rows.length, gate: gc },
    gate_fields_differing: gateDiffs.map((k) => ({ field: k, baseline: gb[k], candidate: gc[k] })),
    rows_compared: baseRows.size,
    rows_differing: rowDiffs.length,
    row_fields_differing: rowFieldCount,
    row_diffs: rowDiffs,
    warnings_added: warningsAdded,
    warnings_removed: warningsRemoved,
    header_fields_differing: headerRuling,
    advisory_fields_differing: [...headerAdvisory],
    volatile_exemptions: VOLATILE.map(([p, why]) => ({ path: p, reason: why })),
    advisory_paths: ADVISORY.map(([p, why]) => ({ path: p, reason: why })),
    determinism_note:
      'This is ONE comparison of ONE candidate against ONE baseline. It is NOT a determinism ' +
      'claim: charter D138 requires determinism to be quoted as a proportion of RUNS ' +
      '(e.g. "4 of 5 completed runs reproduce the committed table at tolerance zero"), never ' +
      'as a row count from a single comparison. A run that wrote zero bytes never reaches this ' +
      'tool at all and is an INSTRUMENT FAILURE, reported as such.',
  };

  if (JSON_ONLY) {
    process.stdout.write(JSON.stringify(report, null, 2) + '\n');
  } else {
    const w = (s) => process.stdout.write(s + '\n');
    w('');
    w('  studio-desk-compare — tolerance ZERO, rows keyed by (viewport_px, inspector_state, face)');
    w('');
    w(`  baseline  ${path.relative(process.cwd(), base.file)}  (${base.size} bytes, ${base.run.rows.length} rows)`);
    w(`  candidate ${path.relative(process.cwd(), cand.file)}  (${cand.size} bytes, ${cand.run.rows.length} rows)`);
    w('');
    w('  gate fields');
    for (const k of Object.keys(gb)) {
      const same = Object.is(gb[k], gc[k]);
      w(`    ${same ? ' ' : '!'} ${k.padEnd(28)} ${fmt(gb[k])}${same ? '' : `   ->   ${fmt(gc[k])}`}`);
    }
    w('');
    if (warningsAdded.length || warningsRemoved.length) {
      w('  warning-set membership');
      for (const x of warningsRemoved) w(`    - ${x}`);
      for (const x of warningsAdded) w(`    + ${x}`);
    } else {
      w(`  warning-set membership  identical (${bw.size} warnings, same set)`);
    }
    w('');
    if (headerRuling.length) {
      w('  header fields differing (ruling surface)');
      for (const d of headerRuling) w(`    ${d.path}\n        baseline  ${fmt(d.baseline)}\n        candidate ${fmt(d.candidate)}`);
      w('');
    }
    if (headerAdvisory.length) {
      w(`  advisory fields differing (${headerAdvisory.length}) — reported, NOT counted toward the verdict`);
      for (const d of headerAdvisory.slice(0, 8)) w(`    ${d.path}: ${fmt(d.baseline)} -> ${fmt(d.candidate)}`);
      if (headerAdvisory.length > 8) w(`    ... and ${headerAdvisory.length - 8} more (use --json for all)`);
      w('');
    }
    if (rowDiffs.length) {
      w(`  ${rowDiffs.length} of ${baseRows.size} rows differ, ${rowFieldCount} fields total`);
      for (const r of rowDiffs) {
        w(`    ${r.key}`);
        for (const d of r.fields) w(`        ${d.path.replace(/^rows\.\*\.?/, '')}\n            baseline  ${fmt(d.baseline)}\n            candidate ${fmt(d.candidate)}`);
      }
    } else {
      w(`  all ${baseRows.size} of ${baseRows.size} rows reproduce, field for field, at tolerance zero`);
    }
    w('');
    w(`  VERDICT: ${report.verdict}`);
    w('');
    w('  NOTE: one comparison is not a determinism claim. D138 requires the proportion of');
    w('        RUNS to be quoted, not a row count from a single comparison.');
    w('');
  }

  process.exit(divergent ? 1 : 0);
}

main();
