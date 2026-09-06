#!/usr/bin/env node
//
// check-prediction.mjs — THE CHECKER.
//
// Reads a FROZEN prediction file and one measurement artefact, and answers one
// question: did the run do what was predicted BEFORE it fired?
//
//   node scripts/measurements/check-prediction.mjs <prediction.json> <artefact.json>
//   node scripts/measurements/check-prediction.mjs <prediction.json> <artefact.json> --json
//
//   exit 0  GREEN        — every applicable predicted field matched, at tolerance ZERO
//   exit 1  MISMATCH     — the prediction was WRONG somewhere, or the artefact contradicts
//                          itself (SELF_INCONSISTENT). Every miss is printed with its basis.
//   exit 2  INPUT FAILURE— the check could not be made: unreadable file, malformed
//                          prediction, un-keyable rows, or a prediction that fails the
//                          banned-scalar hygiene rule. NEVER a desk fact either way.
//   exit 3  UNEVALUATED  — the run produced no evidence for or against (the round trip did
//                          not run). This is DISTINCT from both pass and wrong-prediction.
//   exit 4  STALE-PRIOR  — the ONLY failures are absolute figures registered on a
//                          `prior-observation` basis, in cells whose before[] and after[]
//                          AGREED. The round trip is clean; a registered absolute is not.
//
// ── Design rule 4: A STALE PRIOR IS NOT A FIDELITY FAILURE ───────────────────
//
// Collapsing these into one exit code is a real defect, and it has already
// misled a reader once. `spd-bracketed-deployed-run{1,2}-2026-07-22.json`
// exited 1 with 24 misses, ALL of them the same absolute figure at viewport
// 1280 — while the same run returned 27 of 27 cells unchanged with zero self-
// inconsistencies. A reader seeing only `exit 1` reads "the round trip failed".
// It did not. The prediction's own `this_prediction_can_fail` case (3) already
// names this shape; the checker just could not say it.
//
// So the two are now separated, three ways at once — a labelled verdict line, a
// distinct exit code (4), and a `failure_class` field in `--json`:
//
//   STALE-PRIOR   every miss is kind FIELD, basis `prior-observation`, and sits
//                 in a cell that round-tripped. Nothing here bears on fidelity.
//   FIDELITY-FAIL anything else: a ROUND_TRIP/STRUCTURAL/RULING miss, a self-
//                 inconsistency, a miss on a recomputed/arithmetic/ruling basis,
//                 or a prior-observation miss in a cell that did NOT come back.
//
// STALE-PRIOR means ADJUDICATE, not "the desk moved". It says only that a
// registered absolute and the run disagree while the trip stayed clean — which
// can be desk drift OR the instrument measuring a different state. The 1280
// case above turned out to be the SECOND: see
// `spd-1280-prior-observation-adjudication-2026-09-06.md`. Treating STALE-PRIOR
// as automatic permission to rewrite the baseline would have laundered an
// instrument defect into the record.
//
// D184 gates on `round_trip.ran && returns_bit_identical`, NEVER on this exit
// code — so both are recomputed here and reported in `stats`, to make gating on
// the right thing possible without reading the artefact's own summary scalars.
//
// ── Why this file is SPLIT from the prediction it checks ─────────────────────
//
// The prediction is DATA and is frozen at registration: its whole value is that
// it cannot be moved after a result is seen. This file is LOGIC and stays
// fixable, because logic has bugs — the prototype of this checker had a real
// misattribution bug within minutes of being written. Fusing them would force a
// choice between shipping a known-buggy checker and breaking the freeze, so
// they are two files and only one of them is frozen.
//
// ── Design rule 1: RECOMPUTE, NEVER READ A VERDICT ───────────────────────────
//
// Every verdict this file emits is derived from RAW fields. It never trusts a
// row's own `identical` flag, `diffs` array, or the run's summary counters.
// This is the entire reason the file exists: studio-desk-compare.mjs:216-218
// copies the artefact's guard scalars straight out of the artefact without
// recomputing them, so it structurally cannot catch a row whose stated verdict
// contradicts its own numbers. Here those stated verdicts ARE read — but only
// to be CROSS-EXAMINED against the recomputed answer. A disagreement is reported
// by name as SELF_INCONSISTENT and is a MISMATCH, never a silent pass.
//
// ── Design rule 2: THREE VERDICT STATES, NOT TWO ─────────────────────────────
//
// A binary green/red forces "the run produced no evidence" to be recorded as a
// wrong prediction, which is a lie about what happened. A failing open or
// dismiss leg returns out of the round trip by name, so the run yields either a
// complete set of cells or none — and none is UNEVALUATED (exit 3), reported
// with the skip reason and the viewport it stopped at.
//
// ── Design rule 3: TOLERANCE IS ZERO ─────────────────────────────────────────
//
// Object.is throughout, matching the differ. No epsilon, no "close enough". A
// round trip that returns the column 1px off is a desk that quietly degrades
// every time the reader looks something up, and that is exactly the signal a
// tolerance would convert into noise.

import fs from 'node:fs';

const JSON_ONLY = process.argv.includes('--json');

const EXIT_GREEN = 0;
const EXIT_MISMATCH = 1;
const EXIT_INPUT_FAILURE = 2;
const EXIT_UNEVALUATED = 3;
const EXIT_STALE_PRIOR = 4;

/**
 * THE HYGIENE RULE, and it lives HERE rather than in the prediction on purpose:
 * a frozen data file cannot carry the list of things it is forbidden to say
 * without saying them. Keeping the list in the logic also keeps it fixable.
 *
 * Each entry is a summary scalar the producing instrument writes about ITSELF.
 * A prediction that leans on one is not checkable: on a skipped run the guard
 * scalars read as a clean pass over zero applicable rows, so the pass proves
 * nothing while looking green. The prediction must quote RAW per-row fields and
 * let this checker do the summing.
 */
const BANNED_SCALARS = [
  ['applies_in_rows', 'the guard\'s own applicability count — reads 0 on a skipped run'],
  ['passed_in_rows', 'the guard\'s own pass count — 0 of 0 is a pass that proves nothing'],
  ['vacuous', 'the guard\'s own self-assessment of emptiness'],
  ['row_count', 'the artefact\'s own census of itself'],
  ['returns_bit_identical', 'the round trip\'s own summary verdict'],
  ['identical_cells', 'the round trip\'s own pass count'],
  ['in_floor_px_per_ch', 'unstable per row and carries empty-string values on some rows'],
];

const round2 = (n) => (typeof n === 'number' && Number.isFinite(n) ? Math.round(n * 100) / 100 : null);

function die(msg) {
  process.stderr.write(`\n  ${msg}\n\n`);
  process.exit(EXIT_INPUT_FAILURE);
}

function usage() {
  process.stderr.write(
    'usage: node scripts/measurements/check-prediction.mjs <prediction.json> <artefact.json> [--json]\n' +
    '       exit 0 green · exit 1 fidelity-fail · exit 2 input failure · exit 3 unevaluated · exit 4 stale-prior\n');
}

/** A missing, EMPTY or unparseable file is an INPUT FAILURE and says so in those
 *  words — never a quiet "no differences". A zero-byte run measured nothing. */
function load(label, file) {
  if (!fs.existsSync(file)) die(`INPUT FAILURE: ${label} does not exist: ${file}`);
  const stat = fs.statSync(file);
  if (stat.size === 0) die(`INPUT FAILURE: ${label} is ZERO BYTES: ${file}. A file that holds no bytes states nothing.`);
  const text = fs.readFileSync(file, 'utf8');
  try {
    return { file, text, json: JSON.parse(text) };
  } catch (err) {
    die(`INPUT FAILURE: ${label} is not parseable JSON (${stat.size} bytes): ${file}\n  ${err.message}`);
  }
}

/** Scans the WHOLE prediction text. A banned scalar anywhere — key, value or
 *  prose — is a rejection, because a prediction that even quotes one is arguing
 *  from a number that cannot fail. */
function enforceHygiene(pred) {
  const hits = [];
  for (const [name, why] of BANNED_SCALARS) {
    let idx = pred.text.indexOf(name);
    while (idx !== -1) {
      const line = pred.text.slice(0, idx).split('\n').length;
      hits.push({ scalar: name, line, why });
      idx = pred.text.indexOf(name, idx + name.length);
    }
  }
  if (hits.length === 0) return;
  process.stderr.write('\n  PREDICTION REJECTED — banned scalar quoted.\n');
  process.stderr.write(`  ${pred.file}\n\n`);
  const seen = new Set();
  for (const h of hits) {
    const lines = hits.filter((x) => x.scalar === h.scalar).map((x) => x.line);
    if (seen.has(h.scalar)) continue;
    seen.add(h.scalar);
    process.stderr.write(`    ${h.scalar}  (line${lines.length > 1 ? 's' : ''} ${lines.join(', ')})\n`);
    process.stderr.write(`      ${h.why}\n`);
  }
  process.stderr.write(
    '\n  A prediction must quote RAW per-row fields and let the checker do the summing.\n' +
    '  These scalars are the instrument summarising itself: on a skipped run they read as a\n' +
    '  clean pass over zero applicable rows, so the pass proves nothing while looking green.\n\n');
  process.exit(EXIT_INPUT_FAILURE);
}

/** The composite key — viewport_px, inspector_state, face. Never an index: a
 *  sweep reordering would silently compare unrelated cells. And it keys on
 *  `viewport_px`, NOT `width` — a per-width record names the field
 *  `viewport_px`, so tooling written against `w.width` indexes nothing at all
 *  and reports a clean, empty, entirely fictional pass. */
function cellKey(viewportPx, inspectorState, face) {
  return `viewport ${viewportPx} / ${inspectorState} / face ${face}`;
}

/** Flatten the round trip into keyed cells. Structural problems that make
 *  keying impossible are INPUT FAILURES, not desk facts. */
function indexCells(rt) {
  const cells = new Map();
  const widths = Array.isArray(rt.widths) ? rt.widths : [];
  widths.forEach((w, wi) => {
    if (w?.viewport_px == null) {
      die(`INPUT FAILURE: round_trip.widths[${wi}] has no viewport_px, so its cells cannot be keyed. ` +
          `(A record keyed on \`width\` instead of \`viewport_px\` produces exactly this.)`);
    }
    const faces = Array.isArray(w.faces) ? w.faces : [];
    faces.forEach((f, fi) => {
      if (f?.face == null) {
        die(`INPUT FAILURE: round_trip.widths[${wi}].faces[${fi}] has no face, so it cannot be keyed.`);
      }
      const key = cellKey(w.viewport_px, 'default', f.face);
      if (cells.has(key)) {
        die(`INPUT FAILURE: two cells share the key ${key}. The matrix is not a function of its key; ` +
            `no cell-level verdict is possible.`);
      }
      cells.set(key, { width: w, cell: f });
    });
  });
  return cells;
}

/** Recompute this cell's before/after answer from RAW values only. */
function recomputeCell(cell, fieldNames) {
  const before = cell.before ?? {};
  const after = cell.after ?? {};
  const changed = [];
  for (const name of fieldNames) {
    const b = before[name];
    const a = after[name];
    if (!Object.is(b, a)) changed.push({ field: name, before: b, after: a });
  }
  return { changed, unchanged: changed.length === 0 };
}

/** Derived-field consistency, WITHIN ONE FACE ONLY. content_ch and visible_ch
 *  divide this leg's own box by this leg's own probe span; there is no quotient
 *  anywhere whose numerator and denominator come from different faces. */
function recomputeDerivedCh(leg, legName, key) {
  const out = [];
  const ppc = leg?.px_per_ch;
  if (typeof ppc !== 'number' || !Number.isFinite(ppc) || ppc === 0) {
    out.push({
      key, leg: legName, kind: 'NOT_RECOMPUTABLE', field: 'px_per_ch',
      detail: `px_per_ch is ${JSON.stringify(ppc)}, so no ch figure on this leg can be re-derived. ` +
              `Reported rather than skipped: an unre-derivable leg is not a passing leg.`,
    });
    return out;
  }
  for (const [chField, pxField] of [['content_ch', 'content_px'], ['visible_ch', 'visible_content_px']]) {
    const px = leg[pxField];
    if (typeof px !== 'number' || !Number.isFinite(px)) continue;
    const expected = round2(px / ppc);
    if (!Object.is(expected, leg[chField])) {
      out.push({
        key, leg: legName, kind: 'SELF_INCONSISTENT', field: chField,
        detail: `${pxField}=${px} / px_per_ch=${ppc} recomputes to ${expected}, ` +
                `but the artefact states ${chField}=${JSON.stringify(leg[chField])}. ` +
                `The row contradicts its own raw numbers.`,
      });
    }
  }
  return out;
}

function main() {
  const files = process.argv.slice(2).filter((a) => !a.startsWith('-'));
  if (files.length !== 2) { usage(); process.exit(EXIT_INPUT_FAILURE); }

  const pred = load('prediction', files[0]);
  enforceHygiene(pred);
  const artefact = load('artefact', files[1]);

  const P = pred.json?.round_trip;
  if (!P || typeof P !== 'object' || !P.rows) {
    die(`INPUT FAILURE: ${pred.file} has no round_trip.rows section. This checker has nothing to check.`);
  }
  const run = artefact.json?.run ?? artefact.json;
  const rt = run?.round_trip;

  // ── UNEVALUATED: no evidence either way ────────────────────────────────────
  if (!rt) {
    return report({
      verdict: 'UNEVALUATED',
      exit: EXIT_UNEVALUATED,
      reason: 'the artefact carries no round_trip section at all — this run did not attempt the trip',
      pred, artefact,
    });
  }
  if (rt.ran !== true) {
    return report({
      verdict: 'UNEVALUATED',
      exit: EXIT_UNEVALUATED,
      reason:
        `the round trip did not run: ${rt.skip_reason ?? 'no reason recorded'}` +
        (rt.skipped_at_viewport_px != null ? ` (stopped at viewport ${rt.skipped_at_viewport_px}px)` : ''),
      pred, artefact,
    });
  }

  const misses = [];
  const inconsistencies = [];
  const fieldNames = Array.isArray(P.compared_fields?.predicted) ? P.compared_fields.predicted : [];

  // ── structural claims, each recomputed ─────────────────────────────────────
  const observed = indexCells(rt);
  const reachedWidths = (Array.isArray(rt.widths) ? rt.widths : []).map((w) => w.viewport_px);

  const structural = [
    ['reached_widths', P.reached_widths, reachedWidths],
    ['reached_width_count', P.reached_width_count, reachedWidths.length],
    ['cells_expected', P.cells_expected, observed.size],
    ['field_comparisons_expected', P.field_comparisons_expected, observed.size * fieldNames.length],
    ['compared_fields', P.compared_fields, rt.compared_fields],
  ];
  for (const [name, claim, actual] of structural) {
    if (!claim) continue;
    const a = JSON.stringify(actual);
    const e = JSON.stringify(claim.predicted);
    if (a !== e) {
      misses.push({
        kind: 'STRUCTURAL', key: `round_trip.${name}`, field: name,
        basis: claim.basis ?? 'unstated', predicted: claim.predicted, observed: actual,
        detail: claim.derivation ?? claim.note ?? null,
      });
    }
  }
  // THE DISMISS GRAMMAR IS READ PER WIDTH, AND ITS ABSENCE IS A MISS (D183).
  //
  // This check used to read the run-level `rt.dismiss_control` scalar and skip
  // itself when that scalar was absent. Both halves were wrong once the
  // instrument slice landed. D183 BANS the scalar by name — it was set from
  // `widths[0]` alone and published one 1440px toggle re-click as the grammar of
  // the whole sweep — so `studio-desk-measure.mjs` no longer emits it at all,
  // and this check would have gone permanently, silently vacuous: a guard that
  // cannot fail, on the exact affordance condition D161(ii) turns on.
  //
  // So: check EVERY control the sweep actually used, from the per-width table
  // that D183 makes the citable form, and if a ran trip carries no grammar in
  // any known shape, say so as a MISS. A check with nothing to read has not
  // passed. The legacy scalar is still honoured if present, so this checker
  // reads pre- and post-D183 artefacts alike.
  if (P.dismiss_control_one_of) {
    const allowed = P.dismiss_control_one_of.predicted ?? [];
    const basis = P.dismiss_control_one_of.basis ?? 'ruling';

    // Every shape, most-preferred first; each entry is {control, where}.
    const used =
      Array.isArray(rt.dismiss_controls_used) && rt.dismiss_controls_used.length
        ? rt.dismiss_controls_used.map((u) => ({
            control: u.control,
            where: `widths ${(u.widths_px ?? []).join(', ')}px`,
          }))
        : Array.isArray(rt.dismiss_grammar_by_width) && rt.dismiss_grammar_by_width.length
          ? rt.dismiss_grammar_by_width.map((w) => ({
              control: w.control,
              where: `viewport ${w.viewport_px}px`,
            }))
          : rt.dismiss_control != null
            ? [{ control: rt.dismiss_control, where: 'run-level scalar (pre-D183 artefact)' }]
            : [];

    if (used.length === 0) {
      misses.push({
        kind: 'STRUCTURAL', key: 'round_trip.dismiss_control', field: 'dismiss_control',
        basis, predicted: allowed, observed: null,
        detail:
          'the round trip RAN but records no dismiss grammar in any known shape ' +
          '(dismiss_controls_used, dismiss_grammar_by_width, or the retired run-level scalar). ' +
          'The trip happened through an affordance the artefact does not name, so the ruling ' +
          'cannot be checked — which is a MISS, never a silent skip.',
      });
    }
    for (const u of used) {
      if (!allowed.includes(u.control)) {
        misses.push({
          kind: 'STRUCTURAL', key: 'round_trip.dismiss_control', field: 'dismiss_control',
          basis, predicted: allowed, observed: u.control,
          detail: `the trip happened at ${u.where}, but through an affordance nobody ruled on`,
        });
      }
    }
  }

  // ── key set ────────────────────────────────────────────────────────────────
  const predictedKeys = Object.keys(P.rows);
  for (const key of predictedKeys) {
    if (!observed.has(key)) {
      misses.push({
        kind: 'MISSING_CELL', key, field: null, basis: 'ruling',
        predicted: 'present', observed: 'absent',
        detail: 'predicted cell is not in the artefact — the run did not describe this experiment',
      });
    }
  }
  for (const key of observed.keys()) {
    if (!predictedKeys.includes(key)) {
      misses.push({
        kind: 'UNPREDICTED_CELL', key, field: null, basis: 'ruling',
        predicted: 'absent', observed: 'present',
        detail: 'the artefact carries a cell the prediction never registered',
      });
    }
  }

  // ── per-cell, all recomputed ───────────────────────────────────────────────
  let cellsChecked = 0;
  let cellsUnchanged = 0;
  for (const key of predictedKeys) {
    const found = observed.get(key);
    if (!found) continue;
    const { cell } = found;
    cellsChecked += 1;

    const re = recomputeCell(cell, fieldNames);
    if (re.unchanged) cellsUnchanged += 1;

    // CROSS-EXAMINATION, never trust: the artefact's own stated verdict for this
    // cell is read ONLY to be contradicted by the recomputed answer.
    if (typeof cell.identical === 'boolean' && cell.identical !== re.unchanged) {
      inconsistencies.push({
        kind: 'SELF_INCONSISTENT', key, field: 'identical',
        detail: `the cell states identical=${cell.identical}, but recomputing from its own before[] and ` +
                `after[] gives ${re.unchanged}` +
                (re.changed.length
                  ? ` — ${re.changed.map((c) => `${c.field} ${JSON.stringify(c.before)} -> ${JSON.stringify(c.after)}`).join(', ')}`
                  : ' (every compared field matched)'),
      });
    }
    if (Array.isArray(cell.diffs) && cell.diffs.length !== re.changed.length) {
      inconsistencies.push({
        kind: 'SELF_INCONSISTENT', key, field: 'diffs',
        detail: `the cell lists ${cell.diffs.length} diff(s), but recomputing from its own raw fields ` +
                `finds ${re.changed.length}`,
      });
    }
    inconsistencies.push(...recomputeDerivedCh(cell.before, 'before', key));
    inconsistencies.push(...recomputeDerivedCh(cell.after, 'after', key));

    // the round trip's own claim, recomputed
    const claim = P.rows[key]?.round_trip_returns_unchanged;
    if (claim && claim.predicted !== re.unchanged) {
      misses.push({
        kind: 'ROUND_TRIP', key, field: 'round_trip_returns_unchanged',
        basis: claim.basis ?? 'recomputed', predicted: claim.predicted, observed: re.unchanged,
        detail: re.changed.length
          ? `the reading column did NOT come back: ${re.changed.map((c) => `${c.field} ${JSON.stringify(c.before)} -> ${JSON.stringify(c.after)}`).join(', ')}`
          : 'the column came back unchanged where a change was predicted',
      });
    }

    // absolute figures, both legs
    const fields = P.rows[key]?.fields ?? {};
    for (const [name, spec] of Object.entries(fields)) {
      for (const legName of ['before', 'after']) {
        const got = (cell[legName] ?? {})[name];
        if (!Object.is(got, spec.predicted)) {
          misses.push({
            kind: 'FIELD', key, field: `${name} (${legName})`,
            basis: spec.basis ?? 'unstated', predicted: spec.predicted, observed: got,
            detail: spec.miss_reads_as ?? spec.derivation ?? null,
            // Recomputed, never read: did THIS cell's before[] and after[] agree?
            // A prior-observation miss only reads as staleness when they did.
            legs_agreed: re.unchanged,
            // Kept separately from the display `field` so classification never
            // has to parse a human-readable string back apart.
            field_name: name,
            leg: legName,
          });
        }
      }
    }
  }

  // ── cells_expected_unchanged, recomputed ───────────────────────────────────
  if (P.cells_expected_unchanged && P.cells_expected_unchanged.predicted !== cellsUnchanged) {
    misses.push({
      kind: 'STRUCTURAL', key: 'round_trip.cells_expected_unchanged', field: 'cells_expected_unchanged',
      basis: P.cells_expected_unchanged.basis ?? 'recomputed',
      predicted: P.cells_expected_unchanged.predicted, observed: cellsUnchanged,
      detail: 'recomputed by summing cells whose before[] and after[] agree — never read from the artefact',
    });
  }

  // ── conditional rulings: applicability is REPORTED, never assumed ──────────
  const rulings = [];
  for (const r of pred.json?.conditional_rulings ?? []) {
    const rows = Array.isArray(run?.rows) ? run.rows : [];
    let applied = 0;
    const violations = [];
    if (r.id === 'covered-column-reports-null') {
      for (const row of rows) {
        if (row?.visible_content_px !== 0) continue;
        applied += 1;
        if (row.visible_meets_55ch !== null) {
          violations.push(
            `${cellKey(row.viewport_px, row.inspector_state, row.face)}: ` +
            `visible_meets_55ch=${JSON.stringify(row.visible_meets_55ch)}, expected null`);
        }
      }
    } else {
      rulings.push({ id: r.id, status: 'NO_IMPLEMENTATION', applied: 0, violations: [] });
      continue;
    }
    rulings.push({
      id: r.id,
      status: violations.length ? 'VIOLATED' : applied === 0 ? 'NOT_EXERCISED' : 'HELD',
      applied,
      violations,
    });
    for (const v of violations) {
      misses.push({
        kind: 'RULING', key: r.id, field: r.predicate ?? null, basis: 'ruling',
        predicted: r.predicate, observed: v, detail: r.rationale ?? null,
      });
    }
  }

  const failures = misses.length + inconsistencies.length;

  // D184's two gate inputs, RECOMPUTED — never copied out of the artefact's own
  // summary scalars, which is the whole reason this file exists. A gate may read
  // these; it must not read the exit code.
  const roundTripRan = rt?.ran === true;
  const returnsBitIdentical = roundTripRan && cellsChecked > 0 && cellsUnchanged === cellsChecked;

  // A miss is STALE-PRIOR-shaped only if it is an absolute figure in a cell that
  // CAME BACK, and it is either
  //
  //   (a) registered on a `prior-observation` basis — the registered absolute
  //       itself; or
  //   (b) registered on a `recomputed` basis in the SAME cell and SAME leg as a
  //       prior-observation miss — i.e. an arithmetic CONSEQUENCE of (a), not
  //       independent evidence.
  //
  // (b) is not a loophole, and refusing it would make this verdict unreachable
  // in practice. The prediction derives `content_ch` as `content_px / px_per_ch`
  // and `visible_ch` as `visible_content_px / px_per_ch` within one face, so a
  // stale px absolute drags its ch twin with it every single time: the real 1280
  // case is 12 prior-observation misses and 12 recomputed ones, always paired.
  // The safety rail is that STALE-PRIOR additionally demands ZERO self-
  // inconsistencies, and `recomputeDerivedCh` raises one for exactly the leg
  // whose ch figure does NOT equal its own px divided by its own px_per_ch. So
  // an independently-wrong ch — the case (b) must never swallow — is a
  // SELF_INCONSISTENT and forces FIDELITY-FAIL. `px_per_ch` itself is basis
  // `arithmetic` and is in NEITHER set: real font drift stays a fidelity fail.
  //
  // Every other shape — a ROUND_TRIP/STRUCTURAL/RULING miss, a ruling-basis
  // miss, or a prior-observation miss whose legs DISAGREED — is fidelity.
  const priorObservationLegs = new Set(
    misses
      .filter((m) => m.kind === 'FIELD' && m.basis === 'prior-observation' && m.legs_agreed === true)
      .map((m) => `${m.key}\u0000${m.leg}`));

  const isStalePriorShaped = (m) =>
    m.kind === 'FIELD' &&
    m.legs_agreed === true &&
    (m.basis === 'prior-observation' ||
      (m.basis === 'recomputed' && priorObservationLegs.has(`${m.key}\u0000${m.leg}`)));

  const stalePriorMisses = misses.filter(isStalePriorShaped);
  const allFailuresAreStalePrior =
    failures > 0 &&
    inconsistencies.length === 0 &&
    stalePriorMisses.length === misses.length &&
    returnsBitIdentical;

  const verdict = failures === 0 ? 'GREEN' : allFailuresAreStalePrior ? 'STALE-PRIOR' : 'FIDELITY-FAIL';
  const exit = failures === 0 ? EXIT_GREEN : allFailuresAreStalePrior ? EXIT_STALE_PRIOR : EXIT_MISMATCH;

  return report({
    verdict,
    exit,
    failure_class: failures === 0 ? null : allFailuresAreStalePrior ? 'STALE-PRIOR' : 'FIDELITY-FAIL',
    pred, artefact,
    stats: {
      cells_checked: cellsChecked,
      cells_returned_unchanged: cellsUnchanged,
      reached_widths: reachedWidths.length,
      field_comparisons: cellsChecked * fieldNames.length,
      round_trip_ran: roundTripRan,
      returns_bit_identical: returnsBitIdentical,
      stale_prior_misses: stalePriorMisses.length,
      stale_prior_misses_direct: stalePriorMisses.filter((m) => m.basis === 'prior-observation').length,
      stale_prior_misses_derived: stalePriorMisses.filter((m) => m.basis !== 'prior-observation').length,
    },
    misses, inconsistencies, rulings,
  });
}

function report(r) {
  if (JSON_ONLY) {
    process.stdout.write(JSON.stringify({
      verdict: r.verdict,
      exit: r.exit,
      failure_class: r.failure_class ?? null,
      reason: r.reason ?? null,
      prediction: r.pred.file,
      artefact: r.artefact?.file ?? null,
      stats: r.stats ?? null,
      misses: r.misses ?? [],
      inconsistencies: r.inconsistencies ?? [],
      rulings: r.rulings ?? [],
    }, null, 2) + '\n');
    process.exit(r.exit);
  }

  const out = process.stdout;
  out.write(`\n  prediction : ${r.pred.file}\n`);
  out.write(`  artefact   : ${r.artefact?.file ?? '(none)'}\n\n`);

  if (r.verdict === 'UNEVALUATED') {
    out.write('  VERDICT: UNEVALUATED (exit 3)\n\n');
    out.write(`    ${r.reason}\n\n`);
    out.write('    This is NEITHER a pass NOR a wrong prediction. The run produced no evidence for\n' +
              '    or against the claim, and recording that as either would be a lie about what\n' +
              '    happened. Re-run the measurement; the prediction stands unjudged.\n\n');
    process.exit(r.exit);
  }

  const s = r.stats;
  out.write(`  cells checked            : ${s.cells_checked}\n`);
  out.write(`  cells returned unchanged : ${s.cells_returned_unchanged}   (recomputed from raw before/after)\n`);
  out.write(`  reached widths           : ${s.reached_widths}\n`);
  out.write(`  field comparisons        : ${s.field_comparisons}\n`);
  out.write(`  round_trip.ran           : ${s.round_trip_ran}   (recomputed)\n`);
  out.write(`  returns_bit_identical    : ${s.returns_bit_identical}   (recomputed — D184 gates on THESE TWO, never on the exit code)\n\n`);

  for (const r2 of r.rulings ?? []) {
    const tag = { HELD: 'HELD', VIOLATED: 'VIOLATED', NOT_EXERCISED: 'NOT EXERCISED', NO_IMPLEMENTATION: 'NO IMPLEMENTATION' }[r2.status];
    out.write(`  ruling ${r2.id}: ${tag} (applied in ${r2.applied} row(s))\n`);
    if (r2.status === 'NOT_EXERCISED') {
      out.write('    Zero applicable rows. NOT counted as a pass — a guard that reports success from\n' +
                '    an empty set is exactly the defect this checker exists to refuse.\n');
    }
    for (const v of r2.violations) out.write(`    ${v}\n`);
  }
  if ((r.rulings ?? []).length) out.write('\n');

  if (r.inconsistencies.length) {
    out.write(`  SELF_INCONSISTENT — ${r.inconsistencies.length} row(s) contradict their own raw numbers:\n\n`);
    for (const i of r.inconsistencies) {
      out.write(`    ${i.key}  [${i.field}]\n      ${i.detail}\n`);
    }
    out.write('\n    These are caught by RECOMPUTING, never by reading the row\'s stated verdict.\n' +
              '    A checker that copied the verdict out would have passed every one of them.\n\n');
  }

  if (r.misses.length) {
    out.write(`  MISMATCH — ${r.misses.length} predicted value(s) did not hold:\n\n`);
    for (const m of r.misses) {
      out.write(`    ${m.key}${m.field ? `  [${m.field}]` : ''}\n`);
      out.write(`      basis     : ${m.basis}\n`);
      out.write(`      predicted : ${JSON.stringify(m.predicted)}\n`);
      out.write(`      observed  : ${JSON.stringify(m.observed)}\n`);
      if (m.legs_agreed !== undefined) {
        out.write(`      legs      : before/after ${m.legs_agreed ? 'AGREED (this cell round-tripped)' : 'DISAGREED'}\n`);
      }
      if (m.detail) out.write(`      reads as  : ${m.detail}\n`);
      out.write('\n');
    }
  }

  if (r.verdict === 'GREEN') {
    out.write('  VERDICT: GREEN (exit 0) — the prediction held at tolerance zero.\n\n');
  } else if (r.verdict === 'STALE-PRIOR') {
    out.write(`  VERDICT: STALE-PRIOR (exit 4) — ${r.misses.length} miss(es), ALL of them absolute figures\n` +
              `           in cells that CAME BACK: ${r.stats.stale_prior_misses_direct} registered on a\n` +
              `           \`prior-observation\` basis, ${r.stats.stale_prior_misses_derived} recomputed FROM one in the same leg.\n\n` +
              '    THIS IS NOT A FIDELITY FAILURE. The round trip ran and every checked cell returned\n' +
              '    bit-identical (see returns_bit_identical above, recomputed). What disagrees is a\n' +
              '    REGISTERED ABSOLUTE and the run — the prediction\'s own this_prediction_can_fail\n' +
              '    case (3). The frozen prediction must NOT be edited to agree with the run.\n\n' +
              '    STALE-PRIOR means ADJUDICATE, not "the desk moved". Two causes produce this exact\n' +
              '    shape and only evidence tells them apart: the desk genuinely changed since the\n' +
              '    prior observation, OR the instrument measured a DIFFERENT STATE than the one the\n' +
              '    prior observation describes. Worked example of the second:\n' +
              '    scripts/measurements/spd-1280-prior-observation-adjudication-2026-09-06.md\n\n');
  } else {
    out.write(`  VERDICT: FIDELITY-FAIL (exit 1) — ${r.misses.length} miss(es), ` +
              `${r.inconsistencies.length} self-inconsistency(ies).\n\n` +
              '    At least one failure is NOT a clean prior-observation divergence: a round-trip,\n' +
              '    structural or ruling miss, a self-inconsistency, a miss on a recomputed/arithmetic\n' +
              '    basis, or a prior-observation miss in a cell whose legs DISAGREED. The reading\n' +
              '    column did not simply drift underneath a stale absolute.\n\n');
  }
  process.exit(r.exit);
}

main();
