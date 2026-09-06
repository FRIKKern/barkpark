// __studio-wide-deletion-diff.test.mjs — the self-test for the rule-deletion diff.
//
// Run: node scripts/__studio-wide-deletion-diff.test.mjs
//      node --test scripts/__studio-wide-deletion-diff.test.mjs   (same assertions)
//
// Modelled on `cloud/priv/static/__app.test.mjs`: zero dependencies beyond what
// the tool itself already resolves, and a regression in the committed artifact
// reds the gate.
//
// ── WHY THIS FILE IS NOT OPTIONAL ────────────────────────────────────────────
// The tool it tests exists because D102's wide-unmoved finding rested on an
// uncommitted harness nobody could re-run. Committing a harness that can only
// ever report success would reproduce that failure with extra steps: IDENTICAL
// is the tool's *default* outcome, and a tool whose default outcome is "all
// clear" has to be shown able to say the other thing. So the load-bearing test
// here is the DIFFERENT one.
//
// ── THE TWO DIRECTIONS ───────────────────────────────────────────────────────
// TIGHT SET   -> IDENTICAL. The six narrow/overlay inspector rules are scoped
//                away from the wide bucket; deleting them all must move zero of
//                eighteen fields at 1280 and 1440.
// TOO-BROAD   -> DIFFERENT. The same set plus a BARE `.bp-doc-sidebar.is-open`,
//                which is what a prefix expansion or a context-blind
//                selectorText match would have produced. That extra entry takes
//                the wide-LIVE `flex: 0 0 300px` dock rule, and the run must
//                come back DIFFERENT with `inspector_flex` moving
//                "0 0 300px" -> "0 1 auto" and the reading column `editor_body`
//                676 -> 873.14 at 1280. If this test ever goes IDENTICAL, the
//                deletion matcher has stopped distinguishing contexts and every
//                IDENTICAL it has ever printed is suspect.
//
//                Until 2026-09-06 the widening was pinned on the SURFACE
//                (676 -> 720). It moved to `editor_body` because the surface's
//                `max-width: 660px` cap now binds on BOTH sides of the
//                deletion, so `surface_border_box` reads 660 either way — see
//                "THE 2026-09-06 RE-FREEZE" in studio-wide-deletion-diff.mjs.
//                The surface's IDENTICAL is now asserted too: it is the fact
//                that the cap, not the dock rule, is what sets the column.
//
// ── CI STATUS — OWNER-RUN, NOT GATED (checked 2026-09-06) ────────────────────
// `grep -rn '__studio-wide-deletion-diff\|studio-wide' .github/workflows`
// returns NOTHING: no workflow runs this file, on any trigger. It is therefore
// an OWNER-RUN check, and the cost below is why — it is BROWSER-COUPLED (three
// real Chromium launches through the tool's own Playwright resolver), so it
// does not belong in the dep-free `scripts/node-test-floor.mjs` job that
// task-b7ed25dac17d6229 is wiring the PURE studio-desk self-tests through.
// Wiring it would mean a job with a browser, which is a different decision.
//
// The price of that is measured, not hypothetical: this file was 19 of 21 for
// the ~25 days between 3968dbc16 (2026-08-12) and 2026-09-06 and nothing said
// so. Re-run it by hand after ANY change to `.bp-paper-surface` sizing in
// api/lib/barkpark_web/layouts/root.html.heex, and re-date this line.
//
// ── COST ─────────────────────────────────────────────────────────────────────
// Three real Chromium launches (~10-20s total), no network and no server: the
// page is built with setContent from a local file read. Playwright 1.59.1 is a
// CommonJS package resolved through the tool's own resolver, so a worktree
// without node_modules still runs (it reaches the primary clone via
// --git-common-dir). If Chromium is genuinely unavailable the browser-coupled
// tests FAIL rather than skip — a green that proved nothing is the disease.

import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  runDiff, liftStyleBlock, diffFields, assertNoChEmission, assertNonVacuous,
  parseArgs, parseDeletionEntry, deskHtml, checkFidelity, __test,
} from './studio-wide-deletion-diff.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const LAYOUT_SOURCE = fs.readFileSync(__test.LAYOUT, 'utf8');

/** The tight set is the tool's own committed default — the test must exercise
 *  what ships, not a convenient copy of it. */
const TIGHT = __test.DEFAULT_DELETION_SET;

/** The mistake, spelled out: the tight set plus the bare top-level rule that a
 *  prefix expansion of `.bp-doc-sidebar*` would have swept in. */
const TOO_BROAD = [...TIGHT, { at: null, selector: '.bp-doc-sidebar.is-open' }];

// ── pure helpers ─────────────────────────────────────────────────────────────

test('liftStyleBlock lifts the sheet and strips the EEx interpolations', () => {
  const lift = liftStyleBlock(LAYOUT_SOURCE);
  assert.ok(lift.bytes > 100_000, `expected a substantial sheet, got ${lift.bytes} bytes`);
  assert.ok(lift.eex_stripped.length > 0, 'expected EEx tags to be found and stripped');
  assert.ok(lift.eex_stripped.some((t) => t.includes('paper_stylesheet')),
    'paper_stylesheet() must be among the stripped tags — it is the ch ban\'s premise');
  assert.ok(!/<%/.test(lift.css), 'no EEx may survive into the CSS handed to the browser');
  assert.ok(lift.css.includes('.bp-doc-sidebar.is-open'), 'the inspector rules must be in the lift');
});

test('liftStyleBlock THROWS if the paper face stops being EEx-interpolated', () => {
  // The tripwire under honesty #1: if someone inlines the reading face into the
  // layout, the ch ban's premise is dead and a human has to re-derive it.
  const withoutFace = LAYOUT_SOURCE.replace(/<%=\s*paper_stylesheet\(\)\s*%>/g, '/* inlined */');
  assert.throws(() => liftStyleBlock(withoutFace), /paper_stylesheet/,
    'a layout that no longer interpolates the face must fail loudly, not inherit the ban silently');
});

test('liftStyleBlock THROWS when there is no <style> block at all', () => {
  assert.throws(() => liftStyleBlock('<html><body>nothing here</body></html>'), /no <style> block/);
});

test('assertNoChEmission refuses ch-shaped VALUES', () => {
  assert.throws(() => assertNoChEmission({ floor: 'calc(55ch + 80px)' }), /ch EMISSION REFUSED/);
  assert.throws(() => assertNoChEmission({ rows: [{ measure: '63.95ch' }] }), /ch EMISSION REFUSED/);
});

test('assertNoChEmission refuses ch-shaped KEYS even when the value is innocent', () => {
  assert.throws(() => assertNoChEmission({ content_ch: 55 }), /ch EMISSION REFUSED/);
  assert.throws(() => assertNoChEmission({ px_per_ch: 8.8125 }), /ch EMISSION REFUSED/);
  assert.throws(() => assertNoChEmission({ nested: { ch: 64 } }), /ch EMISSION REFUSED/);
});

test('assertNoChEmission names the DISPROVEN figure in its reason, not just "banned"', () => {
  assert.throws(() => assertNoChEmission({ ch: 67.6 }), /67\.6ch/,
    'the refusal must carry why, or the next author routes around it');
});

test('assertNoChEmission passes a clean px-only record through unchanged', () => {
  const clean = { panel: 976, surface_border_box: 660, content: 580, note: 'px only' };
  assert.deepEqual(assertNoChEmission(clean), clean);
});

test('--ch / --emit-ch are refused at parse time with the documented reason', () => {
  for (const flag of ['--ch', '--emit-ch', '--with-ch']) {
    assert.throws(() => parseArgs([flag]), /REFUSED/, `${flag} must be refused`);
    assert.throws(() => parseArgs([flag]), /paper_stylesheet/, `${flag} must say WHY`);
  }
});

test('assertNonVacuous THROWS on a deletion set that matched nothing', () => {
  assert.throws(
    () => assertNonVacuous({ deleted: 0, deleted_rules: [], missed: [{ at: null, selector: '.nope' }], hits: [] }),
    /VACUOUS RUN/,
    'zero matches must never be reported as a confident IDENTICAL');
});

test('assertNonVacuous passes when at least one rule was really deleted', () => {
  const d = { deleted: 1, deleted_rules: [{ at: null, selector: '.x' }], missed: [], hits: [] };
  assert.equal(assertNonVacuous(d), d);
});

test('parseDeletionEntry separates top-level from at-rule-scoped entries', () => {
  assert.deepEqual(parseDeletionEntry('.bp-doc-sidebar.is-open'),
    { at: null, selector: '.bp-doc-sidebar.is-open' });
  assert.deepEqual(parseDeletionEntry('@container panel (max-width: 860px) :: .bp-doc-sidebar.is-open'),
    { at: '@container panel (max-width: 860px)', selector: '.bp-doc-sidebar.is-open' });
  // A `::` that is a pseudo-element, not the separator — the spec does not start
  // with `@`, so it stays whole.
  assert.deepEqual(parseDeletionEntry('.editor-with-preview::after'),
    { at: null, selector: '.editor-with-preview::after' });
});

test('there is NO "delete wherever it appears" mode', () => {
  assert.throws(() => parseArgs(['--delete-anywhere', '.x']), /unknown argument/);
  assert.throws(() => parseArgs(['--delete-prefix', '.bp-doc-sidebar']), /unknown argument/);
});

test('diffFields reports per-field verdicts and counts the movers', () => {
  const d = diffFields({ a: 1, b: 'x' }, { a: 1, b: 'y' });
  assert.equal(d.verdict, 'DIFFERENT');
  assert.equal(d.changed_field_count, 1);
  assert.equal(d.fields.a.verdict, 'IDENTICAL');
  assert.equal(d.fields.b.verdict, 'DIFFERENT');
  assert.equal(diffFields({ a: 1 }, { a: 1 }).verdict, 'IDENTICAL');
});

test('checkFidelity fails on a drifted BEFORE row and names the field', () => {
  const ok = checkFidelity(1280, { panel: 976, surface_border_box: 660, content: 580 });
  assert.equal(ok.ok, true);
  // The PRE-660px-cap row is the drift this must catch: it is exactly the row
  // that sat in FIDELITY, silently red, from 3968dbc16 until 2026-09-06.
  const bad = checkFidelity(1280, { panel: 976, surface_border_box: 676, content: 596 });
  assert.equal(bad.ok, false);
  assert.match(bad.mismatches.join(' '), /surface_border_box: expected 660, measured 676/);
});

test('deskHtml builds the components.ex nesting, inspector as a SIBLING', () => {
  const html = deskHtml({ css: '/* x */' });
  for (const cls of ['editor-panel', 'editor-with-preview', 'editor-body editor-panel-main bp-paper-body',
                     'bp-paper-shell bp-paper-surface', 'bp-doc-sidebar is-open']) {
    assert.ok(html.includes(cls), `missing "${cls}" in the built desk`);
  }
  // The sidebar must close AFTER the paper body closes — a sibling, never a child.
  assert.ok(html.indexOf('</main>') < html.indexOf('<aside'), 'inspector must be a sibling of the reading column');
  assert.ok(html.includes('data-width-bucket="wide"'), 'the desk must declare the wide bucket');
  assert.ok(!deskHtml({ css: '' }).includes('data-user-opened'), 'user-opened is opt-in');
  assert.ok(deskHtml({ css: '', userOpened: true }).includes('data-user-opened'));
});

// ── the two directions, in a real browser ────────────────────────────────────

test('DIRECTION 1 — the TIGHT set is IDENTICAL at 1280 and 1440', { timeout: 120_000 }, async () => {
  const run = await runDiff({ deletionSet: TIGHT, source: LAYOUT_SOURCE });

  assert.equal(run.rows.length, 2);
  for (const row of run.rows) {
    // Honesty #2 in the test as well as in the tool: identity is only evidence
    // if something was actually removed.
    assert.ok(row.deleted > 0, `viewport ${row.viewport_width}: nothing was deleted, so IDENTICAL proves nothing`);
    assert.equal(row.missed.length, 0,
      `viewport ${row.viewport_width}: the committed default set must match every entry — missed ` +
      JSON.stringify(row.missed));
    assert.equal(row.diff.verdict, 'IDENTICAL',
      `viewport ${row.viewport_width} moved: ` +
      JSON.stringify(Object.entries(row.diff.fields).filter(([, d]) => d.verdict === 'DIFFERENT')));
  }
  assert.equal(run.verdict, 'IDENTICAL');
  assert.equal(run.rows[0].deleted, 6, 'the committed default set is six rules (D12 + D92)');
});

test('DIRECTION 1b — the TIGHT set reproduces the committed wide rows at tolerance zero',
  { timeout: 120_000 }, async () => {
    const run = await runDiff({ deletionSet: TIGHT, source: LAYOUT_SOURCE });
    for (const row of run.rows) {
      const fid = checkFidelity(row.viewport_width, row.before);
      assert.equal(fid.ok, true,
        `viewport ${row.viewport_width}: THE MODEL IS WRONG, NOT THE DESK — ${fid.mismatches.join('; ')}`);
    }
    // Pinned literally as well as by table, so a drifted FIDELITY constant cannot
    // make this test agree with itself.
    const a = run.rows.find((r) => r.viewport_width === 1280).before;
    const b = run.rows.find((r) => r.viewport_width === 1440).before;
    assert.deepEqual([a.panel, a.surface_border_box, a.content], [976, 660, 580]);
    assert.deepEqual([b.panel, b.surface_border_box, b.content], [1136, 660, 580]);
  });

test('DIRECTION 2 — the TOO-BROAD set is DIFFERENT, because it takes the wide-LIVE dock rule',
  { timeout: 120_000 }, async () => {
    const run = await runDiff({ deletionSet: TOO_BROAD, source: LAYOUT_SOURCE });

    assert.equal(run.verdict, 'DIFFERENT',
      'a set containing the bare top-level `.bp-doc-sidebar.is-open` MUST move the desk. ' +
      'If this is IDENTICAL the matcher has stopped distinguishing rule contexts, and every ' +
      'IDENTICAL this tool has ever printed is suspect.');

    for (const row of run.rows) {
      assert.equal(row.diff.verdict, 'DIFFERENT', `viewport ${row.viewport_width} should have moved`);
      // The specific, documented signature of this mistake (see the tool header).
      assert.equal(row.diff.fields.inspector_flex.before, '0 0 300px');
      assert.equal(row.diff.fields.inspector_flex.after, '0 1 auto');
      assert.equal(row.diff.fields.inspector_flex.verdict, 'DIFFERENT');
    }
    const wide1280 = run.rows.find((r) => r.viewport_width === 1280);
    // The widening lands on the READING COLUMN, not the surface: the surface's
    // 660px cap binds on both sides of the deletion, so `surface_border_box` is
    // IDENTICAL at 660 and asserting a move there would be asserting a fiction.
    assert.equal(wide1280.diff.fields.editor_body.before, 676);
    assert.equal(wide1280.diff.fields.editor_body.verdict, 'DIFFERENT');
    assert.ok(wide1280.diff.fields.editor_body.after > 676,
      `the freed dock width must WIDEN the reading column, got ${wide1280.diff.fields.editor_body.after}`);
    assert.deepEqual(
      [wide1280.diff.fields.surface_border_box.before,
       wide1280.diff.fields.surface_border_box.after,
       wide1280.diff.fields.surface_border_box.verdict],
      [660, 660, 'IDENTICAL'],
      'the 660px cap, not the dock rule, is what sets the reading measure at wide');
    assert.equal(wide1280.deleted, TIGHT.length + 1,
      'exactly one more rule than the tight set — the top-level dock rule');
  });

test('the run record that ships is itself ch-free', { timeout: 120_000 }, async () => {
  // runDiff already calls assertNoChEmission on its way out, so reaching this
  // line at all is the proof; re-asserting pins it against a future refactor
  // that moves the call.
  const run = await runDiff({ deletionSet: TIGHT, source: LAYOUT_SOURCE });
  assert.doesNotThrow(() => assertNoChEmission(run));
  assert.match(JSON.stringify(run.unit_policy), /px only/);
});

// ── contract shape ───────────────────────────────────────────────────────────

test('the tool stays scoped to the wide bucket', () => {
  assert.deepEqual(__test.WIDTHS, [1280, 1440],
    'D105 struck a prior harness\'s sub-wide numbers for freezing a [44,260] rail the live ' +
    'desk collapses to [44]. This tool models that rail, so it may only run where the model is true.');
  assert.deepEqual(__test.RAIL_MODEL, [44, 260]);
});

test('studio-desk-measure.mjs is untouched by this slice', () => {
  assert.ok(fs.existsSync(path.join(HERE, 'studio-desk-measure.mjs')),
    'the sibling instrument must still exist — another slice owns it');
});
