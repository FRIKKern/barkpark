#!/usr/bin/env node
//
// studio-scrim-threshold-control.mjs — THE FORCED-CONTAINER POSITIVE CONTROL.
//
// Charter D176. Forces `.editor-panel` to 861px and then 860px against a
// committed static fixture and reads `getComputedStyle(el, '::after').content`
// on `.editor-with-preview`, across all four width buckets x
// user-opened/server-defaulted. It answers exactly one question:
//
//     IS THE 860px SCRIM GENERATOR LIVE CODE, OR A RULE THE SUPPRESSORS
//     QUIETLY KILLED EVERYWHERE?
//
//   node scripts/studio-scrim-threshold-control.mjs              # the matrix
//   node scripts/studio-scrim-threshold-control.mjs --self-test  # + prove it can fail
//   node scripts/studio-scrim-threshold-control.mjs --json
//   node scripts/studio-scrim-threshold-control.mjs --help
//
// It runs FULLY OFFLINE: a `file://` fixture, the repo's own playwright, no
// deployed build, no ssh, no network. That is not a convenience, it is the
// reason this file exists rather than a flag on the measure script — see
// WHY NOT IN studio-desk-measure.mjs, below.
//
// ── WHAT WAS ACTUALLY THERE BEFORE THIS FILE ─────────────────────────────────
// Charter D170 states this control "was executed on the deployed build":
// 861px -> `none`, 860px -> `""`, "verified at both 1280 and 1440". No such
// code existed. `grep -c 861 scripts/studio-desk-measure.mjs` returned 0. The
// claim lived as charter prose, a code comment, and an ExUnit cascade model
// whose own moduledoc concedes ExUnit has no CSS engine. This script is that
// claim, paid.
//
// ── VIEWPORT IS IRRELEVANT TO THIS CONTROL ───────────────────────────────────
// Deliberately, and against the charter's own framing. Nothing in the cascade
// under test reads the viewport: the three suppressors key on the
// `data-width-bucket` attribute the server stamps on <html>, and the generator
// keys on `@container panel (max-width: 860px)` — the FORCED width of
// `.editor-panel`. Every row this script prints therefore runs at one viewport,
// varying only the stamped attribute, `data-user-opened`, and the forced
// container width.
//
// D170's "verified at both 1280 and 1440" is worse than redundant, it is
// IMPOSSIBLE AS STATED. 1280 and 1440 are WIDE viewports, and D170's own new
// suppressor (root.html.heex:2067, reproduced in the fixture as SUPPRESSOR B)
// is UNCONDITIONAL at wide — no `[data-user-opened]` qualifier. So at wide the
// readings are byte-identical with the generator present and with it deleted:
//
//     WITH GENERATOR:    wide  user_opened  861 -> none   860 -> none
//     GENERATOR DELETED: wide  user_opened  861 -> none   860 -> none
//
// At the two viewports the charter names, the control cannot tell a live
// generator from a deleted one. It discriminates at exactly one cell, and that
// cell is `standard` + `data-user-opened` — which is why this script pins the
// bucket explicitly instead of inferring it from a window size.
//
// ── THE SHIPPED --positive-control IS A DIFFERENT MECHANISM ──────────────────
// `POSITIVE_CONTROL_RULE` in scripts/studio-desk-measure.mjs (:2028-2032)
// injects `.editor-with-preview::after { content:"" !important; ... }`: no
// container query, no `:has()`, no bucket key, `!important` throughout.
// Injected into a fixture with the generator DELETED, at bucket=wide and
// panel=1136px, it still flips `::after` from `none` to `""` — it PASSES on a
// fixture that has no generator at all. That is not a bug: its own docstring
// says it checks the occlusion HIT-TEST machinery, and at that job it is
// honest. It is simply structurally incapable of certifying the 860px
// threshold. THIS SCRIPT DOES NOT REPLACE IT. Two instruments, two questions;
// deleting either one leaves a real hole.
//
// ── THE FALSE-GREEN TRAP (proven, not theorised) ─────────────────────────────
// Omit `data-width-bucket` from <html> entirely and the probe reads
// `none` -> `""` — a green IDENTICAL to the truthful `standard` cell.
// SUPPRESSOR A matches any non-wide document but additionally requires
// `:not([data-user-opened])` on the sidebar, and B and C are bucket-keyed, so
// with the attribute absent and `data-user-opened` stamped, nothing suppresses.
// A builder who forgets the attribute gets a passing control that certifies a
// configuration the server never ships. `assertShippedBucket()` refuses those
// readings, and `--self-test` demonstrates the trap once, labelled REJECTED,
// so the refusal is visible rather than merely asserted.
//
// ── WHY NOT IN studio-desk-measure.mjs ───────────────────────────────────────
// `readProvenance()` runs at :2210 and `die()`s on ssh failure BEFORE
// `chromium.launch()` at :2213, so anything added inside its `main()` inherits
// a hard ssh + deployed-box gate and can never run in CI or on a laptop. That
// file is also owned by a sibling slice this round and is NOT touched here.
//
// Node 22. No dependencies beyond playwright.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '..');
const FIXTURE = path.join(HERE, 'fixtures', 'studio-scrim-threshold.html');

// The fenced region the self-test removes. Both markers must be present, or
// "delete the generator" would silently delete nothing and the ability to fail
// would be fake.
const GEN_BEGIN = 'SCRIM-GENERATOR-BEGIN';
const GEN_END = 'SCRIM-GENERATOR-END';

// The buckets the server actually stamps. Anything outside this set is a state
// production cannot be in, so a reading taken there certifies nothing.
const SHIPPED_BUCKETS = ['wide', 'standard', 'narrow', 'phone'];

// 861 is one pixel OUTSIDE `@container panel (max-width: 860px)`, 860 is the
// first pixel inside it. The threshold is the whole subject of this file.
const ABOVE = 861;
const BELOW = 860;

// The one cell that can distinguish a live generator from a deleted one.
const TRUTHFUL_CELL = { bucket: 'standard', userOpened: true };

class ControlError extends Error {}
const die = (msg) => { throw new ControlError(msg); };

// ── playwright ───────────────────────────────────────────────────────────────
// Same resolution ladder studio-desk-measure.mjs uses: a worktree has no
// node_modules, but --git-common-dir points at the primary clone that does.

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
  } catch { /* not a git checkout — the other candidates still apply */ }

  for (const from of candidates) {
    tried.push(from);
    try {
      const require_ = createRequire(from);
      const pw = require_('playwright');
      let version = 'unknown';
      try { version = require_('playwright/package.json').version; } catch { /* keep unknown */ }
      return { pw, resolvedFrom: from, version };
    } catch { /* next */ }
  }
  die(`playwright could not be resolved. Tried, in order:\n  ${tried.join('\n  ')}\n` +
      `Set BP_PLAYWRIGHT_FROM=<path to a package.json that can require("playwright")>.`);
}

// ── the generator-less twin ──────────────────────────────────────────────────

// Writes a copy of the fixture with the fenced generator block removed, and
// PROVES the removal: markers present, region non-trivial, output strictly
// shorter, and the generator's own selector gone. A self-test whose "deleted"
// copy is byte-identical to the original would pass for the emptiest reason
// there is.
function writeGeneratorDeletedCopy(srcPath, destPath) {
  const src = fs.readFileSync(srcPath, 'utf8');

  // A marker counts ONLY on a line that is itself a CSS comment. The fixture's
  // prose header names both markers while explaining the fence, and a bare
  // indexOf would latch onto that mention and cut the document from the middle
  // of its own header — a "deletion" that removes the wrong 3KB and then makes
  // every downstream guard argue about the wreckage.
  const lines = src.split('\n');
  const markerLines = (marker) => {
    const hits = [];
    lines.forEach((line, i) => {
      if (line.trimStart().startsWith('/*') && line.includes(marker)) hits.push(i);
    });
    return hits;
  };
  const beginHits = markerLines(GEN_BEGIN);
  const endHits = markerLines(GEN_END);
  for (const [marker, hits] of [[GEN_BEGIN, beginHits], [GEN_END, endHits]]) {
    if (hits.length !== 1) {
      die(`fixture ${srcPath} carries ${hits.length} CSS-comment ${marker} markers, ` +
          `expected exactly 1 — the self-test cannot delete a generator it cannot ` +
          `locate unambiguously.`);
    }
  }
  const [beginLine] = beginHits;
  const [endLine] = endHits;
  if (endLine <= beginLine) die(`fixture ${srcPath}: ${GEN_END} precedes ${GEN_BEGIN}.`);

  // Cut whole lines, from the one carrying BEGIN through the one carrying END,
  // so the fenced comment and its @container rule go together.
  const removed = lines.slice(beginLine, endLine + 1).join('\n') + '\n';
  const out = [...lines.slice(0, beginLine), ...lines.slice(endLine + 1)].join('\n');

  if (!removed.includes('@container panel (max-width: 860px)')) {
    die(`the fenced region does not contain the @container generator — ` +
        `deleting it would prove nothing. Removed ${removed.length} bytes.`);
  }
  if (out.length >= src.length) die('generator deletion removed nothing.');
  // HTML comments (including this fixture's own header, which quotes the
  // at-rule) are not cascade, so they must not count as a surviving generator.
  const outCss = out.replace(/<!--[\s\S]*?-->/g, '');
  if (outCss.includes('@container panel (max-width: 860px)')) {
    die('a SECOND @container panel (max-width: 860px) block survives the ' +
        'deletion — the fixture has drifted and the self-test would be vacuous.');
  }

  fs.writeFileSync(destPath, out);
  return { removedBytes: removed.length, srcBytes: src.length, outBytes: out.length };
}

// ── the probe ────────────────────────────────────────────────────────────────

function assertShippedBucket(bucket) {
  if (!SHIPPED_BUCKETS.includes(bucket)) {
    die(`refusing to report a reading at data-width-bucket=${JSON.stringify(bucket)}: ` +
        `not one of ${SHIPPED_BUCKETS.join('/')}. The server always stamps a bucket, ` +
        `so an unstamped document is a state production is never in — and with ` +
        `data-user-opened stamped it reads none -> "" exactly like the truthful ` +
        `standard cell. That is the FALSE-GREEN TRAP; see the header.`);
  }
}

// One reading. `bucket: null` means "leave the attribute off" — reachable ONLY
// through the trap demonstration, which never calls assertShippedBucket.
async function readCell(page, { bucket, userOpened, width }) {
  return page.evaluate(({ bucket, userOpened, width }) => {
    const html = document.documentElement;
    if (bucket === null) html.removeAttribute('data-width-bucket');
    else html.setAttribute('data-width-bucket', bucket);

    const aside = document.querySelector('aside.bp-doc-sidebar');
    if (!aside) throw new Error('fixture has no aside.bp-doc-sidebar');
    if (userOpened) aside.setAttribute('data-user-opened', '');
    else aside.removeAttribute('data-user-opened');
    if (!aside.classList.contains('is-open')) throw new Error('sidebar is not .is-open');

    const panel = document.querySelector('.editor-panel');
    if (!panel) throw new Error('fixture has no .editor-panel');
    panel.style.width = `${width}px`;
    panel.style.minWidth = `${width}px`;
    panel.style.maxWidth = `${width}px`;

    const subject = document.querySelector('.editor-with-preview');
    if (!subject) throw new Error('fixture has no .editor-with-preview');

    // The reading, plus the container width the generator actually resolved
    // against — a forced width that silently failed to apply would otherwise
    // look like a suppressed scrim.
    void subject.offsetWidth; // force layout before the computed read
    return {
      content: getComputedStyle(subject, '::after').content,
      containerWidth: panel.getBoundingClientRect().width,
    };
  }, { bucket, userOpened, width });
}

// `none` means no box is generated at all. Anything else — Chromium serialises
// `content: ""` as a two-character `""` — means a scrim painted.
const scrimPainted = (content) => content !== 'none' && content !== 'normal';

async function probeCell(page, { bucket, userOpened }) {
  assertShippedBucket(bucket);
  const above = await readCell(page, { bucket, userOpened, width: ABOVE });
  const below = await readCell(page, { bucket, userOpened, width: BELOW });
  for (const [label, r] of [[`${ABOVE}px`, above], [`${BELOW}px`, below]]) {
    const want = label === `${ABOVE}px` ? ABOVE : BELOW;
    if (Math.round(r.containerWidth) !== want) {
      die(`forced container width did not apply: asked ${want}px, ` +
          `.editor-panel measured ${r.containerWidth}px (bucket=${bucket}, ` +
          `user_opened=${userOpened}). Every reading in this run is untrustworthy.`);
    }
  }
  return {
    bucket,
    user_opened: userOpened,
    above: above.content,
    below: below.content,
    discriminates: !scrimPainted(above.content) && scrimPainted(below.content),
  };
}

async function runMatrix(pw, fixturePath) {
  const browser = await pw.chromium.launch();
  try {
    const page = await browser.newPage();
    await page.goto(pathToFileURL(fixturePath).href);
    const rows = [];
    for (const bucket of SHIPPED_BUCKETS) {
      for (const userOpened of [false, true]) {
        rows.push(await probeCell(page, { bucket, userOpened }));
      }
    }
    return rows;
  } finally {
    await browser.close();
  }
}

// The trap, demonstrated rather than merely asserted: read the same cell with
// NO data-width-bucket, unguarded, and show it is indistinguishable from the
// truthful one. Then show the guard refusing it.
async function demonstrateTrap(pw, fixturePath) {
  const browser = await pw.chromium.launch();
  try {
    const page = await browser.newPage();
    await page.goto(pathToFileURL(fixturePath).href);
    const above = await readCell(page, { bucket: null, userOpened: true, width: ABOVE });
    const below = await readCell(page, { bucket: null, userOpened: true, width: BELOW });
    let refusal = null;
    try { assertShippedBucket(null); } catch (err) { refusal = err.message; }
    if (!refusal) die('assertShippedBucket() accepted a missing bucket — the guard is dead.');
    return { above: above.content, below: below.content, refusal };
  } finally {
    await browser.close();
  }
}

// ── output ───────────────────────────────────────────────────────────────────

// Printed exactly as Chromium serialises it: `none` for "no box generated",
// and `""` (two quote characters) for the generator's `content: ""`.
const cell = (s) => s;

function printMatrix(title, rows) {
  console.log(`\n${title}`);
  console.log(`  ${'bucket'.padEnd(9)} ${'user_opened'.padEnd(12)} ${`${ABOVE}px`.padEnd(10)} ${`${BELOW}px`.padEnd(10)} discriminates`);
  console.log(`  ${'-'.repeat(9)} ${'-'.repeat(12)} ${'-'.repeat(10)} ${'-'.repeat(10)} -------------`);
  for (const r of rows) {
    console.log(`  ${r.bucket.padEnd(9)} ${String(r.user_opened).padEnd(12)} ` +
      `${cell(r.above).padEnd(10)} ${cell(r.below).padEnd(10)} ${r.discriminates ? 'YES' : '.'}`);
  }
}

const findCell = (rows, { bucket, userOpened }) =>
  rows.find((r) => r.bucket === bucket && r.user_opened === userOpened);

// ── the assertions ───────────────────────────────────────────────────────────

function assertLiveGenerator(rows) {
  const t = findCell(rows, TRUTHFUL_CELL);
  if (!t) die(`the ${TRUTHFUL_CELL.bucket}/user_opened cell is missing from the matrix.`);
  if (scrimPainted(t.above)) {
    die(`THE THRESHOLD IS WRONG ABOVE IT: ${TRUTHFUL_CELL.bucket}/user_opened at ` +
        `${ABOVE}px read ${JSON.stringify(t.above)}, expected none. A scrim one pixel ` +
        `outside @container panel (max-width: 860px) means the generator is not ` +
        `container-scoped at all.`);
  }
  if (!scrimPainted(t.below)) {
    die(`THE GENERATOR IS DEAD: ${TRUTHFUL_CELL.bucket}/user_opened at ${BELOW}px read ` +
        `${JSON.stringify(t.below)}, expected "". Either the 860px generator was deleted ` +
        `or a suppressor has grown to cover the one state that still wants a scrim.`);
  }
  const others = rows.filter((r) => r !== t && r.discriminates);
  if (others.length) {
    die(`unexpected extra discriminating cells: ${others.map((r) => `${r.bucket}/${r.user_opened}`).join(', ')}. ` +
        `Only ${TRUTHFUL_CELL.bucket}/user_opened should cross the threshold; a second one ` +
        `means a suppressor was removed or narrowed.`);
  }
}

function assertGeneratorDeletedGoesDark(rows) {
  const t = findCell(rows, TRUTHFUL_CELL);
  if (!t) die(`the ${TRUTHFUL_CELL.bucket}/user_opened cell is missing from the deleted-generator matrix.`);
  if (scrimPainted(t.below)) {
    die(`THIS CONTROL CANNOT FAIL, so it certifies nothing: with the 860px generator ` +
        `DELETED, ${TRUTHFUL_CELL.bucket}/user_opened at ${BELOW}px still read ` +
        `${JSON.stringify(t.below)}. Something other than the fenced rule is painting a ` +
        `scrim, and every green this script has ever printed is suspect.`);
  }
  if (rows.some((r) => r.discriminates)) {
    die(`with the generator deleted, ${rows.filter((r) => r.discriminates).length} cell(s) ` +
        `still cross the 860px threshold. The fixture has a second generator.`);
  }
}

// ── main ─────────────────────────────────────────────────────────────────────

const HELP = `studio-scrim-threshold-control.mjs — forced-container positive control (charter D176)

  --self-test   also run the matrix against a copy of the fixture with the
                860px generator DELETED, and require the truthful cell to go
                dark. Exits non-zero if the control cannot fail.
  --json        emit the run as JSON as well as the table
  --help

Runs offline against ${path.relative(REPO, FIXTURE)}. No deployed build, no ssh,
no network. Viewport is irrelevant — see the header of this file.`;

async function main() {
  const argv = process.argv.slice(2);
  if (argv.includes('--help') || argv.includes('-h')) { console.log(HELP); return; }
  const selfTest = argv.includes('--self-test');
  const asJson = argv.includes('--json');

  if (!fs.existsSync(FIXTURE)) die(`fixture not found: ${FIXTURE}`);

  const { pw, resolvedFrom, version } = resolvePlaywright();
  console.log(`playwright ${version} (resolved from ${resolvedFrom})`);
  console.log(`fixture     ${path.relative(REPO, FIXTURE)}  [file:// — offline, no ssh]`);
  console.log(`threshold   @container panel (max-width: 860px) — probing ${ABOVE}px and ${BELOW}px`);

  const live = await runMatrix(pw, FIXTURE);
  printMatrix('WITH GENERATOR (the fixture as committed):', live);
  assertLiveGenerator(live);
  console.log(`\n  OK  the 860px generator is LIVE: ${TRUTHFUL_CELL.bucket}/user_opened is ` +
    `none at ${ABOVE}px and "" at ${BELOW}px, and it is the ONLY cell that crosses.`);

  const out = { fixture: FIXTURE, playwright: version, live };

  if (selfTest) {
    const trap = await demonstrateTrap(pw, FIXTURE);
    console.log(`\nFALSE-GREEN TRAP (no data-width-bucket attribute at all):`);
    console.log(`  ${'(unset)'.padEnd(9)} ${'true'.padEnd(12)} ${cell(trap.above).padEnd(10)} ${cell(trap.below).padEnd(10)} looks identical to ${TRUTHFUL_CELL.bucket}`);
    console.log(`  REJECTED: ${trap.refusal.split('\n')[0]}`);
    out.trap = trap;

    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'scrim-control-'));
    const deletedPath = path.join(tmp, 'studio-scrim-threshold.no-generator.html');
    try {
      const cut = writeGeneratorDeletedCopy(FIXTURE, deletedPath);
      console.log(`\nSELF-TEST: deleted the fenced generator ` +
        `(${cut.removedBytes} bytes, ${cut.srcBytes} -> ${cut.outBytes}) and re-ran the matrix.`);
      const dead = await runMatrix(pw, deletedPath);
      printMatrix('GENERATOR DELETED:', dead);
      assertGeneratorDeletedGoesDark(dead);
      const t = findCell(live, TRUTHFUL_CELL);
      const d = findCell(dead, TRUTHFUL_CELL);
      console.log(`\n  OK  THE CONTROL CAN FAIL. ${TRUTHFUL_CELL.bucket}/user_opened at ${BELOW}px: ` +
        `${cell(t.below)} with the generator, ${cell(d.below)} without it.`);
      out.deleted = dead;
      out.deletion = cut;
    } finally {
      fs.rmSync(tmp, { recursive: true, force: true });
    }
  } else {
    console.log(`\n  note: this run did NOT prove the control can fail. Use --self-test.`);
  }

  if (asJson) console.log(`\n${JSON.stringify(out, null, 2)}`);
}

main().catch((err) => {
  if (err instanceof ControlError) console.error(`\nFAIL: ${err.message}`);
  else console.error(`\nFAIL (unexpected): ${err && err.stack ? err.stack : err}`);
  process.exit(1);
});
