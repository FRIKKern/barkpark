#!/usr/bin/env node
//
// studio-desk-scrollbar-bound.mjs — WHAT A CLASSIC SCROLLBAR WOULD DO TO THE
// PUBLISHED MATRIX, derived from a committed matrix rather than asserted.
//
// spd-b30-instrument-coverage-one-document-one-path, criterion 1.
//
// ── WHY THIS IS AN ANALYTIC BOUND AND NOT A MEASUREMENT ──────────────────────
//
// `scripts/studio-desk-measure.mjs` runs on macOS, where scrollbars are
// OVERLAY: `scrollbar_width_px` is 0 in every one of the 54 rows of every
// committed matrix. Windows and most Linux desktops paint a CLASSIC scrollbar
// — ~15px of layout width taken away from the page at every viewport. Nobody
// in this epic has a classic-scrollbar host, and the honest answers are a
// measurement there or a bound here. This is the bound.
//
// ── THE MODEL, AND THE CONTROL THAT MAKES IT PUBLISHABLE ─────────────────────
//
// A classic scrollbar changes ONE input: the layout viewport, and with it the
// reading column's own content box, shrink by the scrollbar width. Everything
// downstream is the served CSS:
//
//     gate_open = column_content_box >= 720px        @container content (min-width: 720px)
//     surface   = gate_open ? max(min(column, 660px), min-inline-size)
//                           : min(column, 660px)
//     content   = surface - gutter_total
//     ch        = content / probe_px_per_ch           (the row's OWN probe — D31/D38/D83)
//
// That model is a guess until it reproduces the thing it claims to extend. So
// `applyScrollbarBound` REFUSES to publish unless, at `scrollbar = 0`, it
// reproduces every row's measured `surface_border_box_px` and `content_px`.
// Sixty percent of this repo's overturns are a confident number derived by a
// formula nobody ran backwards; this one is run backwards on every invocation
// and names the rows it misses.
//
// A control that can never fire is not a control, so
// `scripts/studio-desk-scrollbar-bound.test.mjs` also runs a DELIBERATELY
// WRONG model (the container gate ignored) through the same guard and asserts
// that the guard reds. Both directions, on every `node --test`.
//
// ── WHAT THIS BOUND DOES *NOT* COVER, stated where the numbers are ───────────
//
//   - The @media gutter bands. `--paper-gutter` switches at 767px and 479px of
//     LAYOUT viewport, so a classic scrollbar moves those edges to 782px and
//     494px of CSS viewport. None of the nine swept widths lands in either
//     15px window, so this bound holds the gutter fixed — correct at these
//     nine widths, and silent about the two 15px windows nobody has sampled.
//   - The width-bucket stamp. `bucket(window.innerWidth)` in root.html.heex
//     reads innerWidth, which INCLUDES a classic scrollbar; `@media` and
//     `@container` read the layout viewport, which does not. On a classic
//     platform those two disagree by the scrollbar width near every edge
//     (640/1024/1280 for the bucket, 767/479 for the gutter). This bound
//     models the CSS side only and holds the stamped bucket fixed.
//   - Any scrollbar width other than the one passed in. 15px is Chromium's
//     classic default on Windows and on Linux/GTK; a themed GTK bar can be
//     narrower, and a coarse-pointer platform may have none at all.
//
// ── USAGE ────────────────────────────────────────────────────────────────────
//
//     node scripts/studio-desk-scrollbar-bound.mjs <matrix.json>
//     node scripts/studio-desk-scrollbar-bound.mjs <matrix.json> --scrollbar=15
//     node scripts/studio-desk-scrollbar-bound.mjs <matrix.json> --json --out <path>
//
// Exit 0 with a table, or non-zero naming the rows the control missed. It is
// not a gate and has no opinion about whether the desk should pass 55ch.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

/** Chromium's classic scrollbar on Windows and on Linux/GTK defaults. */
export const CLASSIC_SCROLLBAR_PX = 15;

/** Tolerances. `surface_border_box_px` is a raw float; `content_px` is ROUNDED
 *  in the artifact (607.632 is stored as 608), so it gets a half-pixel. */
export const SURFACE_TOL_PX = 0.01;
export const CONTENT_TOL_PX = 0.5;

/**
 * The served CSS, as arithmetic. PURE — plain numbers in, plain numbers out,
 * so it is checkable without a browser and without a host.
 *
 * `minInlineSizePx` is the row's MEASURED resolved floor. It is a function of
 * the face's ch and the gutter, NOT of the column width, so a narrower column
 * does not move it — it only decides whether the gate that admits it is open.
 */
export function surfaceModel({ columnContentBoxPx, gateMinPx, maxWidthPx, minInlineSizePx, gutterTotalPx }) {
  const gateOpen = columnContentBoxPx >= gateMinPx;
  const available = Math.min(columnContentBoxPx, maxWidthPx);
  const surface = gateOpen ? Math.max(available, minInlineSizePx) : available;
  return { gate_open: gateOpen, surface_border_box_px: surface, content_px: surface - gutterTotalPx };
}

/** Pull the model's inputs out of one committed matrix row. */
export function rowInputs(row) {
  return {
    columnContentBoxPx: row.floor.container_content_box_px,
    gateMinPx: row.floor.container_gate_min_px,
    maxWidthPx: row.surface_max_width_px,
    minInlineSizePx: row.floor.min_inline_size_px,
    gutterTotalPx: row.gutter.total_px,
  };
}

/**
 * THE CONTROL. Re-derive every row at the scrollbar width the run ACTUALLY had
 * (0 on macOS) and compare against what the browser measured. Returns the list
 * of misses; empty means the model reproduces its own input.
 */
export function controlMisses(rows, model = surfaceModel) {
  const misses = [];
  for (const row of rows) {
    const got = model(rowInputs(row));
    if (Math.abs(got.surface_border_box_px - row.surface_border_box_px) > SURFACE_TOL_PX) {
      misses.push({ where: whereOf(row), field: 'surface_border_box_px',
        modelled: got.surface_border_box_px, measured: row.surface_border_box_px });
    }
    if (Math.abs(got.content_px - row.content_px) > CONTENT_TOL_PX) {
      misses.push({ where: whereOf(row), field: 'content_px',
        modelled: got.content_px, measured: row.content_px });
    }
    if (got.gate_open !== row.floor.container_gate_open) {
      misses.push({ where: whereOf(row), field: 'container_gate_open',
        modelled: got.gate_open, measured: row.floor.container_gate_open });
    }
  }
  return misses;
}

export function whereOf(row) {
  return `${row.viewport_px}/${row.inspector_state}/${row.face}`;
}

/**
 * The bound itself. THROWS if the control misses — a model that cannot
 * reproduce the matrix it was handed publishes nothing about a platform
 * nobody measured.
 */
export function applyScrollbarBound(run, scrollbarPx = CLASSIC_SCROLLBAR_PX, model = surfaceModel) {
  const rows = run.rows || [];
  if (!rows.length) throw new Error('the matrix carries no rows — nothing to bound');

  const observed = new Set(rows.map((r) => r.scrollbar_width_px));
  if (observed.size !== 1) {
    throw new Error(`the matrix mixes scrollbar widths [${[...observed].join(', ')}] — this bound ` +
      `assumes one platform per matrix and cannot tell which rows to shift`);
  }
  const base = [...observed][0];

  const misses = controlMisses(rows, model);
  if (misses.length) {
    throw new Error(
      `CONTROL FAILED — the model does not reproduce the matrix it was given, at its OWN ` +
      `scrollbar width (${base}px), in ${misses.length} check(s). No bound is published from a ` +
      `model that cannot run backwards.\n` +
      misses.map((m) => `  ${m.where} ${m.field}: modelled ${m.modelled}, measured ${m.measured}`).join('\n'));
  }

  const delta = scrollbarPx - base;
  const bounded = rows.map((row) => {
    const inputs = rowInputs(row);
    const at0 = model(inputs);
    const at1 = model({ ...inputs, columnContentBoxPx: inputs.columnContentBoxPx - delta });
    const probe = row.ch.probe_px_per_ch;
    const criterion = row.criterion_ch;
    const ch0 = at0.content_px / probe;
    const ch1 = at1.content_px / probe;
    return {
      where: whereOf(row),
      viewport_px: row.viewport_px,
      inspector_state: row.inspector_state,
      face: row.face,
      probe_px_per_ch: probe,
      criterion_ch: criterion,
      column_content_box_px: { measured: inputs.columnContentBoxPx, bounded: inputs.columnContentBoxPx - delta },
      container_gate_open: { measured: at0.gate_open, bounded: at1.gate_open },
      // The floor is a ch quantity, not a column quantity: it moves only when
      // the gate that admits it opens or closes.
      floor_binds: { measured: at0.gate_open && at0.surface_border_box_px === inputs.minInlineSizePx,
                     bounded: at1.gate_open && at1.surface_border_box_px === inputs.minInlineSizePx },
      surface_border_box_px: { measured: at0.surface_border_box_px, bounded: at1.surface_border_box_px },
      content_px: { measured: at0.content_px, bounded: at1.content_px,
                    delta: round3(at1.content_px - at0.content_px) },
      content_ch: { measured: round3(ch0), bounded: round3(ch1), delta: round3(ch1 - ch0) },
      content_meets_criterion: { measured: ch0 >= criterion, bounded: ch1 >= criterion },
    };
  });

  return {
    generated_at: new Date().toISOString(),
    tool: 'scripts/studio-desk-scrollbar-bound.mjs',
    kind: 'analytic bound — NOT a measurement on a classic-scrollbar platform',
    source_matrix: run.artifact?.path ?? run.instrument ?? '(unnamed run)',
    source_served_sha: run.provenance?.served_sha ?? null,
    source_platform: run.platform ?? null,
    source_browser: `${run.browser_policy ?? '?'} ${run.browser_version ?? ''}`.trim(),
    measured_scrollbar_px: base,
    bounded_scrollbar_px: scrollbarPx,
    control: {
      ran: true,
      misses: 0,
      what: `every row re-derived at the matrix's own ${base}px scrollbar and compared against the ` +
            `browser's measurement; surface +/-${SURFACE_TOL_PX}px, content +/-${CONTENT_TOL_PX}px ` +
            `(content_px is rounded in the artifact), gate exact`,
    },
    not_covered: [
      'the @media gutter bands: a classic bar moves the 767px/479px edges to 782px/494px of CSS ' +
      'viewport, and no swept width lands in either 15px window — the gutter is held fixed here',
      'the width-bucket stamp: bucket(window.innerWidth) reads a scrollbar-INCLUSIVE width while ' +
      '@media/@container read a scrollbar-EXCLUSIVE one, so the two disagree by the scrollbar width ' +
      'near every edge on a classic platform; only the CSS side is modelled',
      'scrollbar widths other than the one passed in',
      'anything a classic platform changes that is not the layout viewport (font stack, DPI rounding)',
    ],
    rows: bounded,
    summary: summarise(bounded, delta),
  };
}

function round3(n) { return Math.round(n * 1000) / 1000; }

export function summarise(bounded, delta) {
  const flips = bounded.filter((r) => r.content_meets_criterion.measured !== r.content_meets_criterion.bounded);
  const gateFlips = bounded.filter((r) => r.container_gate_open.measured !== r.container_gate_open.bounded);
  const bindsBefore = bounded.filter((r) => r.floor_binds.measured);
  const bindsAfter = bounded.filter((r) => r.floor_binds.bounded);
  const byDelta = new Map();
  for (const r of bounded) {
    const k = r.content_px.delta;
    byDelta.set(k, (byDelta.get(k) ?? 0) + 1);
  }
  return {
    rows: bounded.length,
    layout_viewport_shift_px: -delta,
    content_px_delta_histogram: [...byDelta.entries()]
      .sort((a, b) => b[0] - a[0]).map(([px, n]) => ({ delta_px: px, rows: n })),
    criterion_verdict_flips: flips.map((r) => ({
      where: r.where, from: r.content_meets_criterion.measured, to: r.content_meets_criterion.bounded,
      content_ch: `${r.content_ch.measured} -> ${r.content_ch.bounded}`,
    })),
    container_gate_flips: gateFlips.map((r) => ({
      where: r.where,
      column: `${r.column_content_box_px.measured} -> ${r.column_content_box_px.bounded}`,
      from: r.container_gate_open.measured, to: r.container_gate_open.bounded,
    })),
    floor_binding_rows: {
      measured: bindsBefore.map((r) => r.where),
      bounded: bindsAfter.map((r) => r.where),
      changed: bindsBefore.length !== bindsAfter.length
        || bindsBefore.some((r, i) => r.where !== bindsAfter[i]?.where),
    },
  };
}

/**
 * THE REACHABILITY SHIFT, derived rather than quoted.
 *
 * Within one width bucket the reading column tracks the layout viewport 1:1 —
 * provable from the matrix itself, which is what `columnSlope` checks. So the
 * narrowest CSS viewport at which the container gate opens moves by exactly the
 * scrollbar width.
 */
export function reachability(run, state, scrollbarPx = CLASSIC_SCROLLBAR_PX) {
  const rows = run.rows.filter((r) => r.inspector_state === state);
  const byViewport = new Map();
  for (const r of rows) byViewport.set(r.viewport_px, r.floor);
  const widths = [...byViewport.keys()].sort((a, b) => a - b);
  const gateMin = byViewport.get(widths[0]).container_gate_min_px;
  const open = widths.filter((w) => byViewport.get(w).container_content_box_px >= gateMin);
  if (!open.length) return null;
  const lowest = Math.min(...open);
  const f = byViewport.get(lowest);
  return {
    inspector_state: state,
    gate_min_px: gateMin,
    lowest_swept_viewport_with_gate_open: lowest,
    its_column_content_box_px: f.container_content_box_px,
    headroom_px: f.container_content_box_px - gateMin,
    // Only exact when the swept width sits ON the gate; otherwise it is a bound.
    bounded_viewport_px: lowest + scrollbarPx,
    exact: f.container_content_box_px === gateMin,
    note: f.container_content_box_px === gateMin
      ? `this swept width sits EXACTLY on the gate (${gateMin}.0px), so the shift is exact: ` +
        `${lowest}px of CSS viewport becomes ${lowest + scrollbarPx}px on a ${scrollbarPx}px classic bar`
      : `this swept width clears the gate by ${f.container_content_box_px - gateMin}px, so ` +
        `${lowest + scrollbarPx}px is an UPPER bound on where the gate first opens, not the edge itself`,
  };
}

// ── CLI ──────────────────────────────────────────────────────────────────────

function table(bound) {
  const L = [];
  L.push(`ANALYTIC BOUND — a ${bound.bounded_scrollbar_px}px classic scrollbar against a matrix measured at ${bound.measured_scrollbar_px}px`);
  L.push(`  source        ${bound.source_matrix} @ ${String(bound.source_served_sha).slice(0, 9)} (${bound.source_platform}, ${bound.source_browser})`);
  L.push(`  control       ${bound.control.misses} miss(es) — ${bound.control.what}`);
  L.push('');
  L.push('  viewport state        face            column      gate     surface      content px        ch          55ch?');
  for (const r of bound.rows) {
    const mark = r.content_meets_criterion.measured !== r.content_meets_criterion.bounded ? ' <- FLIPS' : '';
    L.push(
      `  ${String(r.viewport_px).padStart(8)} ${r.inspector_state.padEnd(12)} ${r.face.padEnd(15)} ` +
      `${`${r.column_content_box_px.measured}->${r.column_content_box_px.bounded}`.padEnd(11)} ` +
      `${`${r.container_gate_open.measured ? 'Y' : 'n'}->${r.container_gate_open.bounded ? 'Y' : 'n'}`.padEnd(8)} ` +
      `${`${fmt(r.surface_border_box_px.measured)}->${fmt(r.surface_border_box_px.bounded)}`.padEnd(12)} ` +
      `${`${fmt(r.content_px.measured)}->${fmt(r.content_px.bounded)}`.padEnd(17)} ` +
      `${`${r.content_ch.measured}->${r.content_ch.bounded}`.padEnd(11)} ` +
      `${r.content_meets_criterion.measured ? 'Y' : 'n'}->${r.content_meets_criterion.bounded ? 'Y' : 'n'}${mark}`);
  }
  L.push('');
  const s = bound.summary;
  L.push(`  per-row content delta: ` +
    s.content_px_delta_histogram.map((h) => `${h.delta_px}px x${h.rows}`).join(', '));
  L.push(`  container gate flips:  ${s.container_gate_flips.length ? s.container_gate_flips.map((g) => `${g.where} (${g.column})`).join(', ') : 'none'}`);
  L.push(`  floor-binding rows:    ${s.floor_binding_rows.measured.length} -> ${s.floor_binding_rows.bounded.length}` +
    (s.floor_binding_rows.changed ? '  CHANGED' : '  unchanged'));
  if (s.floor_binding_rows.changed) {
    const gone = s.floor_binding_rows.measured.filter((w) => !s.floor_binding_rows.bounded.includes(w));
    const came = s.floor_binding_rows.bounded.filter((w) => !s.floor_binding_rows.measured.includes(w));
    if (gone.length) L.push(`    stops binding:       ${gone.join(', ')}`);
    if (came.length) L.push(`    starts binding:      ${came.join(', ')}`);
  }
  L.push(`  55ch verdict flips:    ${s.criterion_verdict_flips.length ? '' : 'none'}`);
  for (const f of s.criterion_verdict_flips) L.push(`    ${f.where}: ${f.from} -> ${f.to}  (${f.content_ch} ch)`);
  L.push('');
  for (const r of bound.reachability || []) L.push(`  reachability (${r.inspector_state}): ${r.note}`);
  L.push('');
  L.push('  NOT COVERED by this bound:');
  for (const n of bound.not_covered) L.push(`    - ${n}`);
  return L.join('\n');
}

function fmt(n) { return Number.isInteger(n) ? String(n) : n.toFixed(2); }

const IS_ENTRY = !!process.argv[1]
  && fs.realpathSync(process.argv[1]) === fs.realpathSync(fileURLToPath(import.meta.url));

if (IS_ENTRY) {
  const args = process.argv.slice(2);
  const file = args.find((a) => !a.startsWith('-'));
  if (!file || args.includes('--help')) {
    process.stdout.write(
      'usage: node scripts/studio-desk-scrollbar-bound.mjs <matrix.json> [--scrollbar=15] [--json] [--out <path>]\n');
    process.exit(file ? 0 : 2);
  }
  const sbArg = args.find((a) => a.startsWith('--scrollbar='));
  const scrollbar = sbArg ? Number(sbArg.split('=')[1]) : CLASSIC_SCROLLBAR_PX;
  if (!Number.isFinite(scrollbar) || scrollbar < 0) {
    process.stderr.write(`--scrollbar must be a non-negative number (got ${sbArg})\n`);
    process.exit(2);
  }
  let run;
  try { run = JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch (e) { process.stderr.write(`could not read ${file}: ${e.message}\n`); process.exit(2); }

  let bound;
  try { bound = applyScrollbarBound(run, scrollbar); }
  catch (e) { process.stderr.write(`\nNO BOUND PUBLISHED.\n\n${e.message}\n\n`); process.exit(1); }

  bound.reachability = [...new Set(run.rows.map((r) => r.inspector_state))]
    .map((s) => reachability(run, s, scrollbar)).filter(Boolean);

  const outArg = args.indexOf('--out');
  if (outArg >= 0 && args[outArg + 1]) {
    fs.mkdirSync(path.dirname(args[outArg + 1]), { recursive: true });
    fs.writeFileSync(args[outArg + 1], JSON.stringify(bound, null, 2) + '\n');
    process.stderr.write(`wrote ${args[outArg + 1]}\n`);
  }
  process.stdout.write(args.includes('--json') ? JSON.stringify(bound, null, 2) + '\n' : table(bound) + '\n');
}
