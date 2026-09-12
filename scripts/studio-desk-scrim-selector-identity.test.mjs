#!/usr/bin/env node
//
// studio-desk-scrim-selector-identity.test.mjs — the committed proof that the
// desk instrument can tell a WRONG-BUT-REAL scrim selector from the right one.
//
//   THIS HARNESS HAS NO GATE AUTHORITY (charter D81).
//   It is a proof, not a fence. Nothing about the desk may be quoted from it.
//
// WHY IT EXISTS. The non-vacuity guard was mutation-proven only against a
// selector matching NOTHING: swap SCRIM_SELECTOR for a string that matches no
// rule and the run dies, exit 1, no artifact. That is a real proof of a real
// direction, and it is not the dangerous one.
//
// THE DANGEROUS DIRECTION, MEASURED (spd-scrim-guard-real-but-wrong-selector-
// untested, served sha 4889e332, 2026-09-10). SCRIM_SELECTOR was replaced with
// the b29 scrim SUPPRESSOR copied verbatim out of root.html.heex —
//
//     .editor-with-preview:has(.bp-doc-sidebar.is-open:not([data-user-opened]))::after
//
// — a REAL rule, on the SAME host, generating the SAME pseudo-element, one line
// of qualifier away from the constant it replaced. The sabotaged run:
//
//     exit 0 · 798,522-byte artifact written · 54 rows
//     positive control: guard_applies true, guard_passed true,
//                       natural [0,0,0,0,0] -> forced [580,580,580,580,580]
//     summary: "applies in 0 rows" + zero_cause "DESK-FIXED (proven)"
//
// — numerically byte-identical to the clean baseline. And yet the injection had
// silently missed the pseudo in 18 of 54 rows: `restore.pointer_events_forced`
// read "auto" in every user-opened row of the baseline and "none" in every
// user-opened row of the sabotage. The guard certifies EFFECT; it says nothing
// about IDENTITY, and three greens (guard, positive control, restore) sat on top
// of a rule that named the OFF switch.
//
// WHAT THIS FILE PROVES. `classifyScrimSelectorIdentity` is the identity half,
// and it is pure precisely so its four verdicts can be seen to fire without a
// browser, an admin token, an ssh hop or 40 seconds of deployed desk:
//
//   1. GENERATOR — the shipped scrim rule (declares content: "") passes.
//   2. NOT-A-GENERATOR — the b29 suppressor (content: none), the exact 2026-09-10
//      sabotage, is FATAL. This is the arm that had no test.
//   3. ABSENT — a selector matching nothing in a readable sheet is FATAL. This is
//      the wave-9 direction, kept so it cannot regress.
//   4. UNKNOWN — a scan where every sheet threw on .cssRules is NOT a red. An
//      empty read is not evidence of absence, and manufacturing a fatal out of
//      one would be a false alarm on any page with a cross-origin stylesheet.
//
// Run: node --test scripts/studio-desk-scrim-selector-identity.test.mjs

import test from 'node:test';
import assert from 'node:assert/strict';

import { classifyScrimSelectorIdentity } from './studio-desk-measure.mjs';

const SHIPPED = '.editor-with-preview:has(.bp-doc-sidebar.is-open)::after';
const SUPPRESSOR = '.editor-with-preview:has(.bp-doc-sidebar.is-open:not([data-user-opened]))::after';

/** The generator as root.html.heex ships it, inside @container panel (max-width: 860px). */
const generatorRule = (selector) => ({
  selector_text: selector,
  declared_properties: ['content', 'position', 'inset', 'z-index', 'background', 'pointer-events'],
  content_declared: true,
  content_value: '""',
  pointer_events: 'none',
  position: 'absolute',
  z_index: '4',
  css_text: 'content: ""; position: absolute; inset: 0px; z-index: 4; background: rgba(0,0,0,.55); pointer-events: none;',
});

/** The b29 suppressor, and the three siblings that share its idiom (D170, D175,
 *  narrow/phone). Four separate rules in root.html.heex declare `content: none`
 *  on this very host — four ways to copy the wrong one. */
const suppressorRule = (selector) => ({
  selector_text: selector,
  declared_properties: ['content'],
  content_declared: true,
  content_value: 'none',
  pointer_events: '',
  position: '',
  z_index: '',
  css_text: 'content: none;',
});

const scan = (selector, rules, over = {}) => ({
  selector,
  sheets_total: 3,
  sheets_readable: 2,
  sheets_unreadable: 1,
  scan_readable: true,
  matched_rules: rules,
  ...over,
});

test('GENERATOR — the shipped scrim rule is accepted and is not fatal', () => {
  const v = classifyScrimSelectorIdentity(scan(SHIPPED, [generatorRule(SHIPPED)]));
  assert.equal(v.verdict, 'generator');
  assert.equal(v.fatal, false);
  assert.equal(v.generator_rules, 1);
});

test('NOT-A-GENERATOR — the 2026-09-10 sabotage (the b29 suppressor) is FATAL', () => {
  // The exact mutation the run above survived with three greens.
  const v = classifyScrimSelectorIdentity(scan(SUPPRESSOR, [suppressorRule(SUPPRESSOR)]));
  assert.equal(v.verdict, 'not-a-generator');
  assert.equal(v.fatal, true);
  assert.equal(v.matched_rules, 1);
  assert.equal(v.generator_rules, 0);
  // The message must name what it saw, not merely refuse: a reader has to be
  // able to tell "you named the OFF switch" from "you named nothing".
  assert.match(v.reason, /content:none/);
});

test('NOT-A-GENERATOR — a selector matching ONLY suppressors stays fatal however many there are', () => {
  const v = classifyScrimSelectorIdentity(
    scan(SUPPRESSOR, [suppressorRule(SUPPRESSOR), suppressorRule(SUPPRESSOR), suppressorRule(SUPPRESSOR)]));
  assert.equal(v.verdict, 'not-a-generator');
  assert.equal(v.fatal, true);
  assert.equal(v.matched_rules, 3);
});

test('GENERATOR — one generator among suppressors is enough (the shipped shape)', () => {
  // root.html.heex really does carry both: the generator inside the @container
  // block and D170's unconditional `content: none` kill switch, and both have
  // this exact selectorText. A rule that generates the box exists, so the
  // constant names the generator.
  const v = classifyScrimSelectorIdentity(
    scan(SHIPPED, [generatorRule(SHIPPED), suppressorRule(SHIPPED)]));
  assert.equal(v.verdict, 'generator');
  assert.equal(v.fatal, false);
  assert.equal(v.matched_rules, 2);
  assert.equal(v.generator_rules, 1);
});

test('ABSENT — a readable scan with zero matching rules is FATAL (the wave-9 direction)', () => {
  const v = classifyScrimSelectorIdentity(scan('.this-selector-never-shipped::after', []));
  assert.equal(v.verdict, 'absent');
  assert.equal(v.fatal, true);
  assert.match(v.reason, /NOT ONE rule/);
});

test('UNKNOWN — a scan that could read no stylesheet is NOT fatal', () => {
  // An absence is never caught by inspection: zero matches out of zero readable
  // sheets measured nothing at all, and a fatal here would be a false red on any
  // page carrying a cross-origin stylesheet.
  const v = classifyScrimSelectorIdentity(
    scan(SHIPPED, [], { sheets_readable: 0, sheets_unreadable: 3, scan_readable: false }));
  assert.equal(v.verdict, 'unknown');
  assert.equal(v.fatal, false);
  assert.match(v.reason, /not evidence of absence/);
});

test('UNKNOWN — a record with no identity scan at all is NOT fatal', () => {
  // Older artifacts, and any row measured before the scan existed.
  for (const missing of [null, undefined, 'nonsense', 7]) {
    const v = classifyScrimSelectorIdentity(missing);
    assert.equal(v.verdict, 'unknown', `for ${JSON.stringify(missing)}`);
    assert.equal(v.fatal, false);
  }
});

test('a rule that declares no content at all does not count as a generator', () => {
  // The drift shape where the selector lands on a rule that only tweaks the
  // pseudo — a z-index bump, say — which has no box of its own to force.
  const tweak = {
    selector_text: SHIPPED,
    declared_properties: ['z-index'],
    content_declared: false,
    content_value: '',
    pointer_events: '',
    position: '',
    z_index: '9',
    css_text: 'z-index: 9;',
  };
  const v = classifyScrimSelectorIdentity(scan(SHIPPED, [tweak]));
  assert.equal(v.verdict, 'not-a-generator');
  assert.equal(v.fatal, true);
  assert.match(v.reason, /no content declaration/);
});
