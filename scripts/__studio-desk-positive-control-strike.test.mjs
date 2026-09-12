#!/usr/bin/env node
//
// __studio-desk-positive-control-strike.test.mjs — D176's strike of the shipped
// `--positive-control`, made permanent and SELF-UPDATING.
//
//   THIS HARNESS HAS NO GATE AUTHORITY (charter D81).
//   It is a proof, not a fence. Nothing about the desk may be quoted from it.
//
// MANUAL PROOF — not wired: browser-coupled (two real Chromium launches through
// the same Playwright resolver the desk instrument uses), so it does not belong
// in the dep-free `scripts/node-test-floor.mjs` job that runs the PURE
// studio-desk suites. Run by hand with:
//   node --test scripts/__studio-desk-positive-control-strike.test.mjs
// last run 2026-09-10 — 7 pass / 0 fail (task spd-w13-positive-control-strike-
// permanent). Re-run it after ANY edit to POSITIVE_CONTROL_RULE in
// scripts/studio-desk-measure.mjs or to scripts/fixtures/studio-scrim-threshold.html.
//
// ── WHAT IT PROVES ───────────────────────────────────────────────────────────
// Charter D176 struck the shipped `--positive-control` as a FALSE GREEN and
// D188 recorded the strike as EXECUTED rather than asserted: take the scrim
// fixture, DELETE the fenced 860px generator entirely — no threshold left to
// certify — then inject `studio-desk-measure.mjs`'s own POSITIVE_CONTROL_RULE
// at bucket=wide / panel=1136px, and `::after` content still flips away from
// `none`. The control passes on a fixture that has no generator at all.
//
// THE MECHANISM, which is the part worth guarding: no real suppressor uses
// `!important`. An unconditional `!important` `::after` on the host therefore
// beats every one of them regardless of specificity, source order, container
// query or bucket — with the generator or without it. That is not a bug in the
// flag (its own docstring says it exercises the occlusion HIT-TEST plumbing,
// and at that job it is honest); it is the reason it can never certify the
// 860px threshold, which is what `scripts/studio-scrim-threshold-control.mjs`
// exists for.
//
// ── WHY IT READS THE RULE OUT OF THE SOURCE ──────────────────────────────────
// Until now that proof existed only in a scratchpad script and a transcript, so
// nothing re-ran it. The obvious fix — paste the rule text in here — would
// reproduce the UN-TIED SNAPSHOT failure already filed against the fixture
// itself: change the rule in measure.mjs and a hand copy goes on certifying a
// string that no longer ships. So `extractPositiveControlRule()` reads
// `scripts/studio-desk-measure.mjs` off disk at RUNTIME and lifts the literal
// by its declaration anchor, refusing anything it cannot prove is a plain
// concatenation of string literals. Nothing is imported from measure.mjs and
// nothing is exported out of it: this file is READ-ONLY against it, so the two
// stay file-disjoint.
//
// ── AND WHY IT CAN FAIL ──────────────────────────────────────────────────────
// A test that asserts "content flips" could pass because ANY injected rule
// flips it. THE MUTANT arm derives, mechanically from the extracted text, the
// rule the flag would have to be to test the mechanism instead of overpowering
// it — `!important` stripped and the whole thing wrapped in the generator's own
// `@container panel (max-width: 860px)` — and shows the strike assertion GOING
// RED against it. If that arm ever passes both rules, this file is measuring a
// string rather than a cascade.
//
// Node 22. No dependencies beyond playwright.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '..');
const MEASURE = path.join(HERE, 'studio-desk-measure.mjs');
const FIXTURE = path.join(HERE, 'fixtures', 'studio-scrim-threshold.html');

// The fence the fixture carries for exactly this purpose.
const GEN_BEGIN = 'SCRIM-GENERATOR-BEGIN';
const GEN_END = 'SCRIM-GENERATOR-END';
const GENERATOR_AT_RULE = '@container panel (max-width: 860px)';

// D188's cell. 1136 is a panel width far ABOVE the 860px threshold, and `wide`
// is the bucket whose suppressor (root.html.heex:2067, charter D170) is
// UNCONDITIONAL — so this cell reads `none` with the generator present and with
// it deleted. It is the cell where a flip can only have come from the injection.
const BUCKET = 'wide';
const PANEL_PX = 1136;

// ── the extraction (criterion 1) ─────────────────────────────────────────────

const ANCHOR = 'const POSITIVE_CONTROL_RULE =';

/**
 * Lift the POSITIVE_CONTROL_RULE literal out of measure.mjs's SOURCE TEXT.
 *
 * Deliberately not an import and not an eval: measure.mjs does not export the
 * constant, adding an export would modify a file this task may not touch, and
 * eval on a repo file would run whatever the anchor happened to land on. The
 * declaration must be a plain concatenation of single-quoted string literals —
 * a template literal, a helper call or an identifier is REFUSED rather than
 * half-parsed, because a rule this file could not read in full is a rule it
 * cannot honestly claim to have injected.
 */
function extractPositiveControlRule(src, { where = MEASURE } = {}) {
  const first = src.indexOf(ANCHOR);
  if (first < 0) {
    throw new Error(
      `${where} no longer declares \`${ANCHOR}\`. The constant was renamed or removed, and this ` +
      `file cannot certify a strike against a rule it cannot find. Re-anchor it or retire it.`);
  }
  if (src.indexOf(ANCHOR, first + 1) !== -1) {
    throw new Error(
      `${where} declares \`${ANCHOR}\` more than once — the extraction would pick one arbitrarily.`);
  }
  // Walk the declaration character by character rather than reaching for the
  // first `;`: the rule's own text contains `content: "" !important;`, so a
  // naive scan terminates INSIDE a string literal and lifts a truncated rule
  // that would still inject and still flip — a false green about a false green.
  const tail = src.slice(first + ANCHOR.length);
  const pieces = [];
  let residue = '';
  let i = 0;
  let terminated = false;
  while (i < tail.length) {
    const ch = tail[i];
    if (ch === "'" || ch === '"' || ch === '`') {
      if (ch === '`') {
        throw new Error(
          `${where}: the ${ANCHOR} declaration uses a template literal. Refusing to guess at its ` +
          `value — a template can interpolate, and an interpolated rule is not a rule this file read.`);
      }
      let out = '';
      i += 1;
      for (;;) {
        if (i >= tail.length) throw new Error(`${where}: unterminated string in the ${ANCHOR} declaration.`);
        if (tail[i] === '\\') { out += tail[i + 1]; i += 2; continue; }
        if (tail[i] === ch) { i += 1; break; }
        out += tail[i];
        i += 1;
      }
      pieces.push(out);
      continue;
    }
    if (ch === ';') { terminated = true; i += 1; break; }
    residue += ch;
    i += 1;
  }
  if (!terminated) throw new Error(`${where}: the ${ANCHOR} declaration is unterminated.`);
  if (pieces.length === 0) throw new Error(`${where}: no string literal in the ${ANCHOR} declaration.`);

  // Everything OUTSIDE the string literals must be whitespace or `+`. This is
  // the guard that keeps the refusals above meaningful.
  const stray = residue.replace(/[\s+]/g, '');
  if (stray !== '') {
    throw new Error(
      `${where}: the ${ANCHOR} declaration is no longer a plain concatenation of string ` +
      `literals (unparsed residue ${JSON.stringify(stray)}). Refusing to guess at its value.`);
  }
  return { rule: pieces.join(''), pieces: pieces.length, source_bytes: i };
}

/** The rule the flag WOULD have to be to test the threshold rather than
 *  overpower it — derived from the extracted text, never written out here. */
function containerScopedNonImportantMutant(rule) {
  const stripped = rule.replaceAll(/\s*!important/g, '');
  if (stripped === rule) {
    throw new Error(
      'the extracted rule carries no !important, so the mutation is a no-op and the CAN-FAIL arm ' +
      'would prove nothing. If the shipped rule really has stopped using !important, this whole ' +
      'file is obsolete and D176/D188 need re-deciding — do not weaken the mutation to keep it green.');
  }
  return `${GENERATOR_AT_RULE} { ${stripped} }`;
}

// ── the generator-less twin ──────────────────────────────────────────────────

/** A copy of the fixture with the fenced 860px generator cut out, and the cut
 *  PROVEN: unique CSS-comment markers, the at-rule inside the removed region,
 *  the output strictly shorter, and no second generator surviving in cascade. */
function writeGeneratorDeletedCopy(srcPath, destPath) {
  const src = fs.readFileSync(srcPath, 'utf8');
  const lines = src.split('\n');
  const markerLines = (marker) =>
    lines.reduce((hits, line, i) => {
      if (line.trimStart().startsWith('/*') && line.includes(marker)) hits.push(i);
      return hits;
    }, []);
  const [beginHits, endHits] = [markerLines(GEN_BEGIN), markerLines(GEN_END)];
  for (const [marker, hits] of [[GEN_BEGIN, beginHits], [GEN_END, endHits]]) {
    assert.equal(hits.length, 1,
      `${srcPath} carries ${hits.length} CSS-comment ${marker} markers, expected exactly 1 — ` +
      `a generator that cannot be located unambiguously cannot be deleted.`);
  }
  const [beginLine] = beginHits;
  const [endLine] = endHits;
  assert.ok(endLine > beginLine, `${GEN_END} precedes ${GEN_BEGIN} in ${srcPath}.`);

  const removed = `${lines.slice(beginLine, endLine + 1).join('\n')}\n`;
  const out = [...lines.slice(0, beginLine), ...lines.slice(endLine + 1)].join('\n');
  assert.ok(removed.includes(GENERATOR_AT_RULE),
    `the fenced region does not contain ${GENERATOR_AT_RULE} — deleting it would prove nothing.`);
  assert.ok(out.length < src.length, 'generator deletion removed nothing.');
  // HTML comments are not cascade; the fixture's own header quotes the at-rule.
  assert.ok(!out.replace(/<!--[\s\S]*?-->/g, '').includes(GENERATOR_AT_RULE),
    'a SECOND 860px generator survives the deletion — the fixture drifted and this proof is vacuous.');

  fs.writeFileSync(destPath, out);
  return { removed_bytes: removed.length, src_bytes: src.length, out_bytes: out.length };
}

// ── playwright (the desk instrument's own resolution ladder) ─────────────────

function resolvePlaywright() {
  const tried = [];
  const candidates = [];
  if (process.env.BP_PLAYWRIGHT_FROM) candidates.push(process.env.BP_PLAYWRIGHT_FROM);
  candidates.push(path.join(REPO, 'js', 'package.json'), path.join(REPO, 'package.json'));
  try {
    const common = execFileSync('git', ['rev-parse', '--path-format=absolute', '--git-common-dir'],
      { cwd: REPO, encoding: 'utf8' }).trim();
    const primary = path.dirname(common);
    candidates.push(path.join(primary, 'js', 'package.json'), path.join(primary, 'package.json'));
  } catch { /* not a checkout — the other candidates still apply */ }
  for (const from of candidates) {
    tried.push(from);
    try {
      const require_ = createRequire(from);
      return { pw: require_('playwright'), from };
    } catch { /* next */ }
  }
  // FAIL, never skip: a green that proved nothing is the disease this file treats.
  throw new Error(`playwright could not be resolved. Tried:\n  ${tried.join('\n  ')}`);
}

/** Read `::after` content on the scrim host at BUCKET/PANEL_PX, once with no
 *  injection and once under each supplied rule. One browser, one page. */
async function readCell(fixturePath, rules) {
  const { pw } = resolvePlaywright();
  const browser = await pw.chromium.launch();
  try {
    const page = await browser.newPage();
    await page.goto(pathToFileURL(fixturePath).href);
    const setup = await page.evaluate(({ bucket, panelPx }) => {
      document.documentElement.setAttribute('data-width-bucket', bucket);
      const aside = document.querySelector('aside.bp-doc-sidebar');
      if (!aside) throw new Error('fixture has no aside.bp-doc-sidebar');
      if (!aside.classList.contains('is-open')) throw new Error('sidebar is not .is-open');
      aside.setAttribute('data-user-opened', '');
      const panel = document.querySelector('.editor-panel');
      if (!panel) throw new Error('fixture has no .editor-panel');
      for (const k of ['width', 'minWidth', 'maxWidth']) panel.style[k] = `${panelPx}px`;
      const subject = document.querySelector('.editor-with-preview');
      if (!subject) throw new Error('fixture has no .editor-with-preview');
      void subject.offsetWidth;
      return { container_px: Math.round(panel.getBoundingClientRect().width) };
    }, { bucket: BUCKET, panelPx: PANEL_PX });

    const read = () => page.evaluate(() =>
      getComputedStyle(document.querySelector('.editor-with-preview'), '::after').content);

    const baseline = await read();
    const under = {};
    for (const [label, css] of Object.entries(rules)) {
      const handle = await page.addStyleTag({ content: css });
      under[label] = await read();
      await handle.evaluate((el) => el.remove());
      // The removal must restore the baseline, or the readings are not
      // attributable to the rule that was in the sheet when they were taken.
      under[`${label}__after_removal`] = await read();
    }
    return { ...setup, baseline, ...under };
  } finally {
    await browser.close();
  }
}

/** THE STRIKE ASSERTION, as one function so the CAN-FAIL arm can run the very
 *  same code against the mutant instead of an approximation of it. */
function assertFalseGreen(content, label) {
  assert.notEqual(content, 'none',
    `${label}: ::after content stayed \`none\`, so the injected rule did NOT flip the scrim on a ` +
    `generator-deleted fixture.`);
}

// ── the tests ────────────────────────────────────────────────────────────────

const measureSrc = fs.readFileSync(MEASURE, 'utf8');

test('EXTRACTION — the rule is lifted from measure.mjs SOURCE at runtime, not copied', () => {
  const got = extractPositiveControlRule(measureSrc);
  console.log(`  extracted from ${path.relative(REPO, MEASURE)} (${got.pieces} literal(s), ` +
    `${got.source_bytes} source bytes):\n    ${got.rule}`);
  assert.ok(got.rule.length > 40, 'the extracted rule is implausibly short');
  // The two properties the strike is ABOUT, read off the extracted text — the
  // mechanism, not a remembered string.
  assert.ok(got.rule.includes('!important'), 'the extracted rule no longer uses !important');
  assert.ok(!got.rule.includes('@container'), 'the extracted rule is container-scoped after all');
});

test('EXTRACTION CONTROL — a renamed, duplicated or non-literal declaration is REFUSED', () => {
  assert.throws(() => extractPositiveControlRule('const SOMETHING_ELSE = "x";'), /no longer declares/);
  assert.throws(() => extractPositiveControlRule(`${ANCHOR} 'a';\n${ANCHOR} 'b';`), /more than once/);
  assert.throws(() => extractPositiveControlRule('const POSITIVE_CONTROL_RULE = `a`;'), /template literal/);
  assert.throws(() => extractPositiveControlRule(`${ANCHOR} 'a' + rest;`), /plain concatenation/);
  assert.throws(() => extractPositiveControlRule(`${ANCHOR} 'a'`), /unterminated/);
});

test('MUTATION CONTROL — the mutant is derived from the extracted text and really differs', () => {
  const { rule } = extractPositiveControlRule(measureSrc);
  const mutant = containerScopedNonImportantMutant(rule);
  console.log(`  mutant:\n    ${mutant}`);
  assert.ok(!mutant.includes('!important'), 'the mutation left an !important behind');
  assert.ok(mutant.startsWith(GENERATOR_AT_RULE), 'the mutant is not container-scoped');
  assert.notEqual(mutant, rule);
  assert.throws(() => containerScopedNonImportantMutant('.x::after { content: ""; }'), /no-op/);
});

test('DELETION — the fenced 860px generator can be cut out, provably', (t) => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'pc-strike-'));
  t.after(() => fs.rmSync(tmp, { recursive: true, force: true }));
  const cut = writeGeneratorDeletedCopy(FIXTURE, path.join(tmp, 'no-generator.html'));
  console.log(`  removed ${cut.removed_bytes} bytes, ${cut.src_bytes} -> ${cut.out_bytes}`);
  assert.ok(cut.removed_bytes > 200, 'the removed region is too small to be the generator');
});

test('THE STRIKE — the shipped rule flips ::after on a fixture with NO generator', async (t) => {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'pc-strike-'));
  t.after(() => fs.rmSync(tmp, { recursive: true, force: true }));
  const dead = path.join(tmp, 'no-generator.html');
  writeGeneratorDeletedCopy(FIXTURE, dead);

  const { rule } = extractPositiveControlRule(measureSrc);
  const r = await readCell(dead, { shipped: rule });
  console.log(`  bucket=${BUCKET} panel=${r.container_px}px  baseline=${r.baseline}  ` +
    `under shipped rule=${r.shipped}  after removal=${r.shipped__after_removal}`);

  assert.equal(r.container_px, PANEL_PX, 'the forced panel width did not apply');
  assert.equal(r.baseline, 'none',
    'PRECONDITION FAILED: with the generator deleted the cell must read `none` before any ' +
    'injection, or the flip below is not attributable to the injected rule.');
  assertFalseGreen(r.shipped, 'the shipped POSITIVE_CONTROL_RULE');
  assert.equal(r.shipped__after_removal, 'none', 'removing the style tag did not restore the cell');
});

test('IT CAN FAIL — the same assertion goes RED against a container-scoped, non-important rule',
  async (t) => {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'pc-strike-'));
    t.after(() => fs.rmSync(tmp, { recursive: true, force: true }));
    const dead = path.join(tmp, 'no-generator.html');
    writeGeneratorDeletedCopy(FIXTURE, dead);

    const { rule } = extractPositiveControlRule(measureSrc);
    const r = await readCell(dead, { mutant: containerScopedNonImportantMutant(rule) });
    console.log(`  bucket=${BUCKET} panel=${r.container_px}px  baseline=${r.baseline}  ` +
      `under mutant=${r.mutant}`);

    assert.equal(r.baseline, 'none');
    // The load-bearing arm: the strike assertion, unchanged, refusing the mutant.
    assert.throws(() => assertFalseGreen(r.mutant, 'the container-scoped mutant'),
      /stayed `none`, so the injected rule did NOT flip/,
      'THE MUTANT FLIPPED THE CELL TOO. This file is then matching a string rather than exercising ' +
      'a cascade, and its green says nothing about !important beating the suppressors.');
    console.log('  the strike assertion RED against the mutant, as required.');
  });

test('READ-ONLY — nothing here imports or rewrites studio-desk-measure.mjs', () => {
  const self = fs.readFileSync(fileURLToPath(import.meta.url), 'utf8');
  assert.ok(!/^\s*import[\s\S]*?from\s+'\.\/studio-desk-measure\.mjs'/m.test(self),
    'this file imports measure.mjs — the strike must not depend on an export it would have to add');
  assert.ok(!self.includes(`writeFileSync(${'MEASURE'}`), 'this file writes to measure.mjs');
});
