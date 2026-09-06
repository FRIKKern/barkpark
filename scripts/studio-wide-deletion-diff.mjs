#!/usr/bin/env node
//
// studio-wide-deletion-diff.mjs — THE RULE-DELETION DIFF.
//
// Answers exactly one question, by experiment rather than by reading CSS:
//
//   "Does deleting THIS rule set move the wide desk?"
//
// It lifts the shipped inline <style> block out of
// `api/lib/barkpark_web/layouts/root.html.heex`, builds the desk DOM in a real
// Chromium, measures every geometry field at viewports 1280 and 1440, deletes a
// CALLER-NAMED rule set through the CSSOM, re-measures, and prints
// IDENTICAL/DIFFERENT per field.
//
//   node scripts/studio-wide-deletion-diff.mjs                # default set, human table + JSON
//   node scripts/studio-wide-deletion-diff.mjs --json         # JSON only
//   node scripts/studio-wide-deletion-diff.mjs --delete '<sel>' [--delete ...]
//   node scripts/studio-wide-deletion-diff.mjs --out <path>   # ALSO save the run JSON
//   node scripts/studio-wide-deletion-diff.mjs --help
//
// WHY THIS FILE EXISTS (charter D156). D102 records that wide is unmoved,
// "measured by deleting the rules from every stylesheet at runtime and diffing
// every field". That tooling was never committed — `rg 'deleteRule('` returned
// ZERO repo-wide, and the static harness it ran on is not in the history
// either. The finding rested on an ephemeral artefact belonging to an agent who
// evaporated, which is the exact disease `scripts/studio-desk-measure.mjs` says
// in its own header it was written to cure. This converts the technique into
// tooling the epic can re-run and, more importantly, DISAGREE with.
//
// CONTRACT — the only one it claims: **it prints a diff, or it exits non-zero
// naming the thing that failed.** It is NOT a CI gate and has no pass/fail
// opinion about the numbers (charter D81). Its self-test IS gated; this script
// is not.
//
// ── SCOPED TO WIDE, ON PURPOSE ───────────────────────────────────────────────
// 1280 and 1440 only. D105 struck a prior harness's SUB-WIDE numbers because it
// froze a [44, 260] rail that the live desk collapses to [44] below the wide
// bucket. That strike does not reach wide, where the live rail IS [44, 260] —
// which is precisely why this tool models that rail and refuses to run anywhere
// the model is known to be false. Sub-wide questions belong to
// `scripts/studio-desk-measure.mjs`, which drives the DEPLOYED desk in an
// authenticated browser and needs no rail model at all. Do not extend this file
// downward; extend that one.
//
// ── THE THREE THINGS THAT MAKE IT HONEST ─────────────────────────────────────
// Each was learned by getting it wrong first.
//
//   1. IT REFUSES TO EMIT ch. The paper reading face is NOT in the lifted
//      sheet: `.bp-paper-surface`'s face arrives through `<%= paper_stylesheet() %>`
//      -> `Barkpark.PortableDoc.Render.Stylesheet.css()`, which is EEx and
//      cannot be statically lifted. A harness allowed to compute ch here
//      resolves the FALLBACK face's ~8.8125 px/ch and reproduces the charter's
//      own DISPROVEN 67.6ch. So `assertNoChEmission()` HARD THROWS on any
//      ch-shaped key or value in the emitted record, and `--ch` / `--emit-ch`
//      are refused at parse time with the reason spelled out. A comment would
//      not have been enough: the next agent quotes numbers, not comments.
//
//      The corollary, stated so nobody has to rediscover it: `ch` still
//      RESOLVES inside the page (the `@container content (min-width: 720px)`
//      floor is `calc(55ch + 2 * var(--paper-gutter))`), and it resolves
//      against the wrong face. At 1280 that floor never applies — the `content`
//      container is 676px, under the 720px query — and the tool measures
//      `surface_min_inline_size: 0px` there. At 1440 it DOES apply and resolves
//      to 508.24px, far under the 660px `max-width` that actually binds. That
//      508.24px is NOT a desk fact: it is this harness's fallback face, and the
//      deployed face would resolve it elsewhere. It is reported only to show
//      the floor is INERT at both widths — which is why the px numbers are
//      trustworthy here and nowhere else, and why a face-sensitive question
//      belongs to studio-desk-measure.mjs. That inertness is a measured
//      property of these two widths, not a general one.
//
//   2. IT ASSERTS `deleted > 0` BEFORE TRUSTING IDENTITY. A deletion set that
//      matches nothing produces a serenely confident IDENTICAL that proves
//      exactly nothing — the same vacuous-pass shape that produced D31 and
//      D39. Zero matches exits non-zero and names every selector that missed.
//
//   3. THE DELETION SET IS CONTEXT-QUALIFIED, NEVER A SELECTOR PREFIX. This is
//      the whole ballgame, and it is subtle enough to deserve the space:
//
//        .bp-doc-sidebar.is-open { flex: 0 0 300px }          <- TOP LEVEL. This
//            is the rule that gives the docked inspector its column. It is LIVE
//            at 1280 and 1440. Deleting it is not a probe, it is a change.
//
//        @container panel (max-width: 860px) {
//          .bp-doc-sidebar.is-open { position: absolute; ... }  <- the overlay
//            promotion. Inert at wide. This is a probe target.
//        }
//
//      Identical `selectorText`. Different rules. A deletion set built by
//      prefix — "delete everything starting `.bp-doc-sidebar`" — or by bare
//      selectorText match takes BOTH, and the run comes back DIFFERENT with
//      `inspector_flex: "0 0 300px" -> "0 1 auto"` and the reading column
//      `editor_body` 676 -> 873.14 at 1280. (Before the 2026-09-06 re-freeze
//      that signature was quoted as "surface 676 -> 720"; since the 660px cap
//      binds on BOTH sides of the deletion, `surface_border_box` now stays 660
//      and `editor_body` is the field that shows the widening.) That
//      is a real measurement of a rule nobody meant to delete, reported as
//      evidence about a rule that was never tested. So every entry in a
//      deletion set names its enclosing at-rule condition (or `null` for top
//      level) and both must match. `__studio-wide-deletion-diff.test.mjs` pins
//      both directions: the too-broad set MUST come back DIFFERENT, the tight
//      set MUST come back IDENTICAL. A tool that can only report success has
//      not been shown able to fail.
//
// ── FIDELITY ─────────────────────────────────────────────────────────────────
// The BEFORE numbers, at tolerance zero:
//
//   1280 -> panel 976  / surface_border_box 660 / content 580
//   1440 -> panel 1136 / surface_border_box 660 / content 580
//
// `--check-fidelity` asserts them. If they do not reproduce, THE MODEL IS
// WRONG, not the desk — fix the DOM here before believing any diff it prints.
//
// ── THE 2026-09-06 RE-FREEZE ─────────────────────────────────────────────────
// The rows above are NOT the rows this file shipped with. The original freeze
// came from `scripts/measurements/spd-visible-table-2026-07-20.json` (charter
// D156) and read:
//
//   1280 -> panel 976  / surface_border_box 676 / content 596
//   1440 -> panel 1136 / surface_border_box 720 / content 640
//
// THE DESK MOVED, DELIBERATELY; THE MODEL WAS NOT WRONG WHEN IT WAS FROZEN.
// Commit 3968dbc16 — `feat(paper): the reader reads its own type token, and the
// roles keep their ratio` (#11626, pe-w1-reader-editorial-typography,
// 2026-08-12) — changed `.bp-paper-surface { max-width: 720px }` to `660px`,
// because the 640px measure was sized for 16px prose and ran ~87 characters per
// line at the 18px the type token had always specified. The gutter token did
// not move: `--paper-gutter: 40px` a side, so content = cap - 80.
//
// The arithmetic of which rows that binds — the cap binds wherever the reading
// column (`editor_body`, the `.editor-panel-main.bp-paper-body` box) exceeds
// the cap, and clips it to cap/cap-80:
//
//   width  editor_body   old cap 720            new cap 660
//   1280   676           676 < 720 -> uncapped  676 > 660 -> 660 / 580
//   1440   836           836 > 720 -> 720 / 640 836 > 660 -> 660 / 580
//
// So BOTH wide rows move, for two different reasons: 1280 was uncapped and is
// now capped (676 -> 660, a 16px shift); 1440 was already capped and follows
// the cap down (720 -> 660). `panel` is unmoved at both widths — the rail model
// is untouched, which is the tell that this was a reading-column change and not
// a chrome change.
//
// STANDING LAW observed here: every ch figure names its face, font-size and
// probe-derived px/ch (so this file emits none at all); `viewport 640` and
// `content 640` never appear bare — the 1440 row's `content 640` above is a
// CONTENT-box figure and says so; navigate this file by marker, never by line
// number.

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '..');
const LAYOUT = path.join(REPO, 'api', 'lib', 'barkpark_web', 'layouts', 'root.html.heex');

/** Wide only. See "SCOPED TO WIDE, ON PURPOSE" above. */
const WIDTHS = [1280, 1440];

/** The live wide rail, as MEASURED (D105): a 44px icon rail and a 260px pane
 *  column. Modelled as two fixed boxes rather than lifted, because the rail is
 *  rendered by LiveView components with their own stylesheet — so this is the
 *  one part of the page that is a model and not a lift, and `--check-fidelity`
 *  is what keeps the model honest. 1280 - 304 = 976; 1440 - 304 = 1136. */
const RAIL_MODEL = [44, 260];

/** The committed wide rows, for `--check-fidelity`. Re-frozen 2026-09-06 on the
 *  660px cap (see "THE 2026-09-06 RE-FREEZE" in the header). The pre-cap
 *  freeze (D156 / `spd-visible-table-2026-07-20.json`) read 1280 -> 676/596 and
 *  1440 -> 720/640; both rows now clip to the same 660/580 reading column. */
const FIDELITY = {
  1280: { panel: 976, surface_border_box: 660, content: 580 },
  1440: { panel: 1136, surface_border_box: 660, content: 580 },
};

/** Asserted present in the built DOM before any number is trusted. */
const REQUIRED_SELECTORS = [
  '.editor-panel',
  '.editor-with-preview',
  '.editor-body.bp-paper-body',
  '.bp-paper-surface',
  '.bp-doc-sidebar',
];

/** The DEFAULT deletion set: every rule the narrow/overlay-inspector work added
 *  (charter D12 + D92). All six are scoped away from the wide bucket, either by
 *  `html:not([data-width-bucket="wide"])` or by the `@container panel
 *  (max-width: 860px)` gate, so the CLAIM under test is that deleting them all
 *  moves nothing at 1280/1440.
 *
 *  Note the third entry: `.bp-doc-sidebar.is-open` qualified BY its container
 *  condition. The top-level rule of the same name is deliberately absent, and
 *  adding it is the mistake documented under honesty #3. */
const DEFAULT_DELETION_SET = [
  { at: null, selector: 'html:not([data-width-bucket="wide"]) .bp-doc-sidebar.is-open:not([data-user-opened])' },
  { at: null, selector: 'html:not([data-width-bucket="wide"]) .bp-doc-sidebar.is-open:not([data-user-opened]) .bp-doc-sidebar__title, html:not([data-width-bucket="wide"]) .bp-doc-sidebar.is-open:not([data-user-opened]) .bp-doc-sidebar__body' },
  { at: null, selector: 'html:not([data-width-bucket="wide"]) .editor-with-preview:has(.bp-doc-sidebar.is-open:not([data-user-opened]))::after' },
  { at: '@container panel (max-width: 860px)', selector: '.bp-doc-sidebar.is-open' },
  { at: '@container panel (max-width: 860px)', selector: '.editor-with-preview:has(.bp-doc-sidebar.is-open)::after' },
  { at: '@container panel (max-width: 860px)', selector: '.bp-doc-field' },
];

class DiffError extends Error {}
const die = (msg) => { throw new DiffError(msg); };

// ── the ch ban ───────────────────────────────────────────────────────────────
// Honesty #1. Structural, not advisory.

const CH_BAN_REASON =
  'This harness may not emit ch. `.bp-paper-surface`\'s reading face arrives via\n' +
  '`<%= paper_stylesheet() %>` -> Barkpark.PortableDoc.Render.Stylesheet.css(), which is\n' +
  'EEx and is NOT part of the lifted <style> block. Any ch computed here divides by the\n' +
  'FALLBACK face and reproduces the charter\'s DISPROVEN 67.6ch. Measure ch with\n' +
  '`scripts/studio-desk-measure.mjs`, which forces a real face against the DEPLOYED desk\n' +
  'and converts through a 1ch probe span. Cross-face division is BANNED (standing law).';

const CH_KEY = /(^|_)ch(_|$)|_ch$|^ch$|perch|_per_ch$/i;
const CH_VALUE = /(?:^|[\s(,])[0-9]+(?:\.[0-9]+)?\s*ch\b/i;

/** HARD THROW on any ch-shaped key or value anywhere in an emitted record.
 *  Exported so the self-test can prove it bites rather than assuming it. */
export function assertNoChEmission(node, trail = '$') {
  if (node === null || node === undefined) return node;
  if (typeof node === 'string') {
    if (CH_VALUE.test(node)) die(`ch EMISSION REFUSED at ${trail}: ${JSON.stringify(node)}\n\n${CH_BAN_REASON}`);
    return node;
  }
  if (typeof node !== 'object') return node;
  if (Array.isArray(node)) {
    node.forEach((v, i) => assertNoChEmission(v, `${trail}[${i}]`));
    return node;
  }
  for (const [k, v] of Object.entries(node)) {
    if (CH_KEY.test(k)) die(`ch EMISSION REFUSED at ${trail}.${k} (key names a ch figure)\n\n${CH_BAN_REASON}`);
    assertNoChEmission(v, `${trail}.${k}`);
  }
  return node;
}

// ── the lift ─────────────────────────────────────────────────────────────────

/** Pull the shipped inline <style> block out of root.html.heex VERBATIM, then
 *  strip the EEx interpolations it contains (they are server-side calls, not
 *  CSS) and report which ones were dropped.
 *
 *  The `paper_stylesheet` assertion is a TRIPWIRE, not decoration: it is the
 *  premise the ch ban rests on. If someone inlines the paper face into this
 *  layout, the premise dies and this throws, forcing a human to re-derive the
 *  ban instead of silently inheriting it. */
export function liftStyleBlock(source) {
  const open = source.indexOf('<style>');
  if (open === -1) die(`no <style> block found in ${LAYOUT} — the layout changed shape; re-derive the lift.`);
  const start = open + '<style>'.length;
  const close = source.indexOf('</style>', start);
  if (close === -1) die(`unterminated <style> block in ${LAYOUT}.`);

  const raw = source.slice(start, close);

  const eex = [];
  const css = raw.replace(/<%[=%]?[\s\S]*?%>/g, (tag) => {
    eex.push(tag.trim());
    // The tag is RECORDED but never echoed into the CSS. Echoing it inside a
    // comment leaves literal `<%` in the sheet handed to the browser, which is
    // harmless today and exactly the kind of residue a later `no EEx survived`
    // check would trip over. The index ties the placeholder back to
    // `eex_stripped[i]` without carrying the syntax along.
    return `/* EEx interpolation #${eex.length - 1} stripped by studio-wide-deletion-diff */`;
  });

  if (!eex.some((t) => t.includes('paper_stylesheet'))) {
    die('the lifted <style> block no longer interpolates `paper_stylesheet()`.\n\n' +
        'That interpolation is the PREMISE of this file\'s ch ban: it is why the reading\n' +
        'face is absent from a static lift. If the face is now inlined, the ban may be\n' +
        'wrong — re-derive it deliberately rather than deleting this check.');
  }

  return { css, eex_stripped: eex, bytes: css.length };
}

// ── the desk DOM ─────────────────────────────────────────────────────────────

/** The nesting is the one from components.ex:
 *    .editor-panel > .editor-with-preview
 *                      > .editor-body.editor-panel-main.bp-paper-body
 *                          > main.bp-paper-shell.bp-paper-surface
 *                      > aside.bp-doc-sidebar          (SIBLING of the body)
 *  wrapped in a modelled wide rail. `.editor-panel-main` is not optional
 *  decoration — `.editor-with-preview .editor-panel-main { flex: 1 1 100%;
 *  min-width: 0 }` is what lets the reading column yield to the inspector, and
 *  `.editor-with-preview .editor-panel-main.bp-paper-body` is what declares the
 *  `content` container the measure floor queries. */
export function deskHtml({ css, userOpened = false, inspectorOpen = true }) {
  const rail = RAIL_MODEL
    .map((w, i) => `<div class="bp-rail-model" data-rail-index="${i}" style="flex:0 0 ${w}px"></div>`)
    .join('');
  const sidebarClass = inspectorOpen ? 'bp-doc-sidebar is-open' : 'bp-doc-sidebar is-collapsed';
  const userOpenedAttr = userOpened ? ' data-user-opened' : '';

  return `<!doctype html>
<html lang="en" data-width-bucket="wide" data-theme="light">
<head><meta charset="utf-8"><title>studio wide deletion diff</title>
<style>${css}</style>
<style>
  /* MODEL ONLY — the wide rail and a page frame. Kept in its own sheet so it is
     visibly not part of the lift, and so a deletion set can never reach it. */
  html, body { height: 100%; }
  .bp-desk-model-shell { display: flex; height: 100%; align-items: stretch; }
  .bp-rail-model { flex-shrink: 0; }
</style>
</head>
<body>
  <div class="bp-desk-model-shell">
    ${rail}
    <div class="editor-panel">
      <div class="editor-with-preview">
        <div class="editor-body editor-panel-main bp-paper-body">
          <main class="bp-paper-shell bp-paper-surface">
            <article><p>The reading column.</p></article>
          </main>
        </div>
        <aside class="${sidebarClass}"${userOpenedAttr}>
          <div class="bp-doc-sidebar__head">
            <button class="bp-doc-sidebar__collapse" type="button">x</button>
            <span class="bp-doc-sidebar__title">Document</span>
          </div>
          <div class="bp-doc-sidebar__body">
            <div class="bp-doc-sec"><div class="bp-doc-field"><span>Status</span><span>draft</span></div></div>
          </div>
        </aside>
      </div>
    </div>
  </div>
</body>
</html>`;
}

// ── in-page instruments ──────────────────────────────────────────────────────
// Serialised into the browser. Written as source strings so the file stays a
// single artifact with no build step, matching studio-desk-measure.mjs.

const ASSERT_SELECTORS = /* js */ `(selectors) => {
  const counts = {};
  for (const sel of selectors) counts[sel] = document.querySelectorAll(sel).length;
  return counts;
}`;

/** Every field, read never computed. `content` subtracts the READ padding
 *  (impossibility #2 of the sibling instrument: the gutter is viewport-@media'd
 *  56/40 -> 48/24 -> 32/16, so a hardcoded -80 is wrong in exactly the rows a
 *  matrix exists to interrogate — inert at 1280/1440, read anyway). */
const MEASURE = /* js */ `() => {
  const px = (v) => Math.round(parseFloat(v) * 100) / 100;
  const box = (el) => (el ? px(el.getBoundingClientRect().width) : null);
  const panel = document.querySelector('.editor-panel');
  const withPreview = document.querySelector('.editor-with-preview');
  const body = document.querySelector('.editor-body.bp-paper-body');
  const surface = document.querySelector('.bp-paper-surface');
  const sidebar = document.querySelector('.bp-doc-sidebar');
  const sCs = surface ? getComputedStyle(surface) : null;
  const padL = sCs ? px(sCs.paddingLeft) : null;
  const padR = sCs ? px(sCs.paddingRight) : null;
  const surfaceBox = box(surface);
  const sideCs = sidebar ? getComputedStyle(sidebar) : null;
  const scrim = withPreview ? getComputedStyle(withPreview, '::after') : null;

  return {
    panel: box(panel),
    editor_body: box(body),
    surface_border_box: surfaceBox,
    surface_padding_left: padL,
    surface_padding_right: padR,
    content: surfaceBox === null ? null : px(surfaceBox - padL - padR),
    surface_max_width: sCs ? sCs.maxWidth : null,
    surface_min_inline_size: sCs ? sCs.minInlineSize : null,
    inspector: box(sidebar),
    inspector_flex: sideCs ? sideCs.flex : null,
    inspector_position: sideCs ? sideCs.position : null,
    inspector_display: sideCs ? sideCs.display : null,
    inspector_z_index: sideCs ? sideCs.zIndex : null,
    scrim_content: scrim ? scrim.content : null,
    scrim_background: scrim ? scrim.backgroundColor : null,
    body_scroll_width: px(document.body.scrollWidth),
    body_client_width: px(document.body.clientWidth),
    reading_column_overflows: body ? body.scrollWidth > body.clientWidth : null,
  };
}`;

/** CSSOM deletion, context-qualified. Walks every sheet, recursing into
 *  CSSGroupingRule (@media / @container / @supports), and deletes ONLY rules
 *  whose (enclosing condition, selectorText) pair matches an entry in the set.
 *
 *  Deletes in reverse index order per parent, because deleteRule() reindexes
 *  its siblings — forward deletion silently skips every second match. */
const DELETE_RULES = /* js */ `(set) => {
  const norm = (s) => (s || '').replace(/\\s+/g, ' ').trim();
  const wanted = set.map((e) => ({ at: e.at === null ? null : norm(e.at), selector: norm(e.selector), hits: 0 }));

  // The group's PRELUDE, taken from cssText, for every grouping type alike:
  // '@container panel (max-width: 860px)', '@media (max-width: 767px)',
  // '@supports (…)'. Deliberately not assembled from conditionText +
  // containerName — in Chromium CSSContainerRule.conditionText ALREADY carries
  // the name ('panel (max-width: 860px)'), so prepending it again yields
  // '@container panel panel (…)', which matches nothing and reports a serene
  // zero. One source, and it is the text a caller can read off the stylesheet.
  const conditionText = (rule) => (rule ? norm(rule.cssText.split('{')[0]) : null);

  const found = [];
  const visit = (parent, at) => {
    let rules;
    try { rules = parent.cssRules; } catch (e) { return; } // cross-origin sheet
    if (!rules) return;
    for (let i = 0; i < rules.length; i++) {
      const rule = rules[i];
      if (rule.selectorText !== undefined) {
        const sel = norm(rule.selectorText);
        for (const w of wanted) {
          if (w.selector === sel && w.at === at) {
            found.push({ parent, index: i, selector: sel, at, entry: w });
          }
        }
      } else if (rule.cssRules) {
        visit(rule, conditionText(rule));
      }
    }
  };
  for (const sheet of Array.from(document.styleSheets)) visit(sheet, null);

  // Reverse order overall keeps every parent's indices valid as we go.
  const deletedRules = [];
  for (let i = found.length - 1; i >= 0; i--) {
    const f = found[i];
    f.parent.deleteRule(f.index);
    f.entry.hits += 1;
    deletedRules.push({ at: f.at, selector: f.selector });
  }

  return {
    deleted: deletedRules.length,
    deleted_rules: deletedRules.reverse(),
    missed: wanted.filter((w) => w.hits === 0).map((w) => ({ at: w.at, selector: w.selector })),
    hits: wanted.map((w) => ({ at: w.at, selector: w.selector, hits: w.hits })),
  };
}`;

// ── diffing ──────────────────────────────────────────────────────────────────

/** Field-by-field IDENTICAL/DIFFERENT. Pure — the self-test drives it directly. */
export function diffFields(before, after) {
  const keys = Array.from(new Set([...Object.keys(before), ...Object.keys(after)])).sort();
  const fields = {};
  let changed = 0;
  for (const k of keys) {
    const same = JSON.stringify(before[k]) === JSON.stringify(after[k]);
    if (!same) changed += 1;
    fields[k] = { before: before[k], after: after[k], verdict: same ? 'IDENTICAL' : 'DIFFERENT' };
  }
  return { verdict: changed === 0 ? 'IDENTICAL' : 'DIFFERENT', changed_field_count: changed, fields };
}

/** Honesty #2, as a function rather than a habit. */
export function assertNonVacuous(deletion) {
  if (!deletion || deletion.deleted === 0) {
    const missed = (deletion?.missed ?? []).map((m) => `  ${m.at ? m.at + ' :: ' : ''}${m.selector}`).join('\n');
    die('VACUOUS RUN — the deletion set matched ZERO rules, so IDENTICAL would prove nothing.\n' +
        'Selectors that matched nothing:\n' + (missed || '  (none reported)') + '\n\n' +
        'Check the enclosing at-rule condition as well as the selector: a rule inside\n' +
        '`@container panel (max-width: 860px)` is NOT matched by a top-level entry.');
  }
  if (deletion.missed.length > 0) {
    process.stderr.write('WARNING — part of the deletion set matched nothing:\n' +
      deletion.missed.map((m) => `  ${m.at ? m.at + ' :: ' : ''}${m.selector}`).join('\n') +
      '\nThe diff below is about the rules that DID match, and no others.\n\n');
  }
  return deletion;
}

export function checkFidelity(width, before) {
  const want = FIDELITY[width];
  if (!want) return { width, checked: false, reason: 'no committed row for this width' };
  const mismatches = Object.entries(want)
    .filter(([k, v]) => before[k] !== v)
    .map(([k, v]) => `${k}: expected ${v}, measured ${before[k]}`);
  return { width, checked: true, ok: mismatches.length === 0, mismatches };
}

// ── CLI ──────────────────────────────────────────────────────────────────────

export function parseArgs(argv) {
  const opts = { json: false, out: null, deletionSet: null, userOpened: false, checkFidelity: false, help: false };
  const deletes = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--help' || a === '-h') opts.help = true;
    else if (a === '--json') opts.json = true;
    else if (a === '--user-opened') opts.userOpened = true;
    else if (a === '--check-fidelity') opts.checkFidelity = true;
    else if (a === '--out') opts.out = argv[++i] ?? die('--out needs a path.');
    else if (a.startsWith('--out=')) opts.out = a.slice('--out='.length);
    else if (a === '--delete') deletes.push(argv[++i] ?? die('--delete needs a selector.'));
    else if (a.startsWith('--delete=')) deletes.push(a.slice('--delete='.length));
    else if (a === '--ch' || a === '--emit-ch' || a === '--with-ch') {
      die(`${a} REFUSED.\n\n${CH_BAN_REASON}`);
    } else die(`unknown argument: ${a}\nRun with --help.`);
  }
  if (deletes.length) opts.deletionSet = deletes.map(parseDeletionEntry);
  return opts;
}

/** `<selector>` = top level. `<at-rule condition> :: <selector>` = inside that
 *  group ONLY. The separator is deliberate and mandatory: there is no way to
 *  express "wherever it appears", because that is the mistake this file exists
 *  to make unavailable. */
export function parseDeletionEntry(spec) {
  const sep = spec.indexOf('::');
  const looksLikeAtRule = spec.trimStart().startsWith('@');
  if (sep !== -1 && looksLikeAtRule) {
    return { at: spec.slice(0, sep).trim(), selector: spec.slice(sep + 2).trim() };
  }
  return { at: null, selector: spec.trim() };
}

function usage() {
  return `studio-wide-deletion-diff.mjs — does deleting THIS rule set move the wide desk?

  node scripts/studio-wide-deletion-diff.mjs [--json] [--out <path>]
                                             [--delete '<spec>' ...]
                                             [--user-opened] [--check-fidelity]

  --delete '<selector>'                       a TOP-LEVEL rule
  --delete '@container panel (max-width: 860px) :: <selector>'
                                              a rule inside that group ONLY
  --user-opened     mark the inspector [data-user-opened]
  --check-fidelity  assert the BEFORE numbers match the committed wide rows
  --out <path>      also write the complete run JSON

Widths: ${WIDTHS.join(', ')} (wide bucket only — see the header).
Default deletion set: the ${DEFAULT_DELETION_SET.length} narrow/overlay inspector rules (D12 + D92).

There is NO "delete wherever it appears" mode. Two different rules share the
selectorText '.bp-doc-sidebar.is-open' — one is the wide-LIVE 300px dock — and a
set that takes both reports a real change to a rule nobody meant to test.

This script never emits ch. ${CH_BAN_REASON.split('\n')[0]}
`;
}

function resolvePlaywright() {
  const tried = [];
  const candidates = [];
  if (process.env.BP_PLAYWRIGHT_FROM) candidates.push(process.env.BP_PLAYWRIGHT_FROM);
  candidates.push(path.join(REPO, 'js', 'package.json'), path.join(REPO, 'package.json'));
  // A worktree has no node_modules. --git-common-dir points at the primary
  // clone's .git, whose parent is the checkout that DOES have them.
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
      // Playwright is CommonJS: default import, never a named ESM export.
      const pw = require_('playwright');
      let version = 'unknown';
      try { version = require_('playwright/package.json').version; } catch { /* keep unknown */ }
      return { pw, resolvedFrom: from, version };
    } catch { /* next */ }
  }
  die(`playwright could not be resolved. Tried, in order:\n  ${tried.join('\n  ')}\n` +
      `Set BP_PLAYWRIGHT_FROM=<path to a package.json that can require("playwright")>.`);
}

/** Call an in-page instrument with its arguments SERIALISED INTO the expression.
 *  Playwright's arg-passing form takes a real function; these instruments are
 *  source strings (so this file stays a single artifact with no build step), and
 *  a string plus an arg silently evaluates to the function itself rather than
 *  calling it — which is a confident `undefined`, the exact failure shape this
 *  epic keeps buying. Inlining the args removes the ambiguity. */
function evalIn(page, src, ...args) {
  return page.evaluate(`(${src})(${args.map((a) => JSON.stringify(a)).join(', ')})`);
}

/** The whole run, as a function, so the self-test drives the REAL path rather
 *  than a re-implementation of it. */
export async function runDiff({ deletionSet = DEFAULT_DELETION_SET, userOpened = false, widths = WIDTHS, source = null } = {}) {
  const heex = source ?? fs.readFileSync(LAYOUT, 'utf8');
  const lift = liftStyleBlock(heex);
  const { pw, resolvedFrom, version } = resolvePlaywright();
  const html = deskHtml({ css: lift.css, userOpened });

  const browser = await pw.chromium.launch();
  const rows = [];
  try {
    for (const width of widths) {
      const page = await browser.newPage({ viewport: { width, height: 900 } });
      try {
        await page.setContent(html, { waitUntil: 'load' });

        const counts = await evalIn(page, ASSERT_SELECTORS, REQUIRED_SELECTORS);
        const absent = REQUIRED_SELECTORS.filter((s) => counts[s] === 0);
        if (absent.length) {
          die(`the desk DOM did not build — these selectors matched ZERO elements at ` +
              `viewport ${width}px:\n  ${absent.join('\n  ')}\n` +
              `Every number below them would be a confident zero. Fix deskHtml().`);
        }

        const before = await evalIn(page, MEASURE);
        const deletion = assertNonVacuous(await evalIn(page, DELETE_RULES, deletionSet));
        const after = await evalIn(page, MEASURE);

        rows.push({
          viewport_width: width,
          rail_model: RAIL_MODEL,
          selector_counts: counts,
          deleted: deletion.deleted,
          deleted_rules: deletion.deleted_rules,
          missed: deletion.missed,
          before,
          after,
          diff: diffFields(before, after),
        });
      } finally {
        await page.close();
      }
    }
  } finally {
    await browser.close();
  }

  const run = {
    tool: 'studio-wide-deletion-diff',
    generated_at: new Date().toISOString(),
    host: os.hostname(),
    layout: path.relative(REPO, LAYOUT),
    lifted_bytes: lift.bytes,
    eex_stripped: lift.eex_stripped,
    playwright_resolved_from: resolvedFrom,
    playwright_version: version,
    scope_note: 'WIDE ONLY. The [44, 260] rail model is measured-true at these widths and false below them (D105).',
    // NOT keyed `ch_policy`: the ban is strict enough to refuse any key whose
    // first or last segment is `ch`, and the run record must not be the one
    // exception that teaches the next author to loosen it.
    unit_policy: 'px only. Character units are REFUSED here — see CH_BAN_REASON in the source.',
    user_opened: userOpened,
    deletion_set: deletionSet,
    rows,
    verdict: rows.every((r) => r.diff.verdict === 'IDENTICAL') ? 'IDENTICAL' : 'DIFFERENT',
  };

  // Honesty #1, applied to the whole artifact at the last possible moment.
  return assertNoChEmission(run);
}

function printTable(run) {
  const out = [];
  out.push('');
  out.push(`studio-wide-deletion-diff — ${run.generated_at}`);
  out.push(`layout: ${run.layout}  (${run.lifted_bytes} bytes lifted, ${run.eex_stripped.length} EEx tags stripped)`);
  out.push(`playwright ${run.playwright_version} from ${run.playwright_resolved_from}`);
  out.push(`rail model: [${RAIL_MODEL.join(', ')}] (MODELLED, not lifted — see the header)   inspector user-opened: ${run.user_opened}`);
  out.push('');
  out.push(`deletion set (${run.deletion_set.length} entries):`);
  for (const e of run.deletion_set) out.push(`  ${e.at ? e.at + ' :: ' : ''}${e.selector}`);
  out.push('');

  for (const row of run.rows) {
    out.push(`── viewport ${row.viewport_width}px ${'─'.repeat(48)}`);
    out.push(`   rules deleted: ${row.deleted}${row.missed.length ? `   (${row.missed.length} entries matched nothing)` : ''}`);
    out.push('');
    const name = 'field'.padEnd(26);
    out.push(`   ${name}${'before'.padEnd(20)}${'after'.padEnd(20)}verdict`);
    for (const [field, d] of Object.entries(row.diff.fields)) {
      out.push(`   ${field.padEnd(26)}${String(d.before).padEnd(20)}${String(d.after).padEnd(20)}${d.verdict}`);
    }
    out.push('');
    out.push(`   ROW VERDICT: ${row.diff.verdict}` +
      (row.diff.changed_field_count ? ` (${row.diff.changed_field_count} field(s) moved)` : ''));
    out.push('');
  }
  out.push(`RUN VERDICT: ${run.verdict}  — deleting this set ${run.verdict === 'IDENTICAL' ? 'moves NOTHING' : 'MOVES the desk'} at ${run.rows.map((r) => r.viewport_width + 'px').join(' and ')}.`);
  out.push('');
  return out.join('\n');
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) { process.stdout.write(usage()); return; }

  const run = await runDiff({
    deletionSet: opts.deletionSet ?? DEFAULT_DELETION_SET,
    userOpened: opts.userOpened,
  });

  if (opts.checkFidelity) {
    const checks = run.rows.map((r) => checkFidelity(r.viewport_width, r.before));
    run.fidelity = checks;
    const bad = checks.filter((c) => c.checked && !c.ok);
    if (bad.length) {
      die('FIDELITY FAILED — the BEFORE numbers do not reproduce the committed wide rows.\n' +
          bad.map((b) => `  viewport ${b.width}:\n    ${b.mismatches.join('\n    ')}`).join('\n') + '\n\n' +
          'THE MODEL IS WRONG, NOT THE DESK. Fix deskHtml()/RAIL_MODEL before believing any diff.');
    }
  }

  if (opts.out) {
    fs.mkdirSync(path.dirname(path.resolve(opts.out)), { recursive: true });
    fs.writeFileSync(path.resolve(opts.out), JSON.stringify(run, null, 2) + '\n');
  }

  if (opts.json) process.stdout.write(JSON.stringify(run, null, 2) + '\n');
  else { process.stdout.write(printTable(run)); process.stdout.write(JSON.stringify(run.rows.map((r) => ({ viewport: r.viewport_width, deleted: r.deleted, verdict: r.diff.verdict })), null, 2) + '\n'); }
}

export const __test = {
  DEFAULT_DELETION_SET, FIDELITY, RAIL_MODEL, WIDTHS, REQUIRED_SELECTORS,
  LAYOUT, CH_BAN_REASON, DiffError, MEASURE, DELETE_RULES, printTable,
};

/** Symlink-proof, matching studio-desk-measure.mjs: a run reached through a
 *  symlinked path must still be recognised as direct invocation, or it silently
 *  becomes a no-op import that prints nothing. */
function realResolve(p) {
  try { return fs.realpathSync(p); } catch { return path.resolve(p); }
}
const INVOKED_DIRECTLY =
  !!process.argv[1] && realResolve(process.argv[1]) === realResolve(fileURLToPath(import.meta.url));

if (INVOKED_DIRECTLY) {
  main().catch((err) => {
    process.stderr.write('\nDELETION DIFF FAILED — no diff was produced.\n\n');
    process.stderr.write((err instanceof DiffError ? err.message : (err?.stack || String(err))) + '\n\n');
    process.exit(1);
  });
}
