#!/usr/bin/env node
//
// studio-scrim-abolition-check.mjs — THE SCRIM STAYS GONE.
//
// The Studio inspector overlay used to dim the document it covered. It does
// not any more, and this file is what keeps it that way:
//
//     NO STYLE RULE IN api/lib/barkpark_web/layouts/root.html.heex MAY ATTACH
//     A GENERATED BOX TO `.editor-with-preview`.
//
//   node scripts/studio-scrim-abolition-check.mjs             # the verdict, exit 1 on a scrim
//   node scripts/studio-scrim-abolition-check.mjs --self-test # + prove it can fail
//   node scripts/studio-scrim-abolition-check.mjs --list      # print what it parsed
//
// ── WHAT THIS REPLACED, AND WHY THE SHAPE CHANGED ────────────────────────────
// Until 2026-09-22 root.html.heex carried a FIVE-RULE scrim family: one
// generator inside `@container panel (max-width: 860px)`
// (`.editor-with-preview:has(.bp-doc-sidebar.is-open)::after { content: "" }`)
// and four later `content: none` suppressors that cancelled it one width
// bucket at a time — the b29 guard (below wide, never asked for), D170 (wide,
// unconditional), D155 (narrow/phone, user-opened) and D175/D187 (standard,
// user-opened). Together they covered every shipped bucket x user-opened
// cell, and the forced-container control measured exactly that: `none` at
// 861px AND at 860px, 8 cells out of 8. The generator painted nowhere.
//
// All five rules were retired together, because a ruling held by four
// cancellations of one unreachable rule is a ruling nobody can read. What
// guarded it before was a playwright matrix over a committed fixture
// (`studio-scrim-threshold-control.mjs` + `fixtures/studio-scrim-threshold.html`,
// tied back to the source by `studio-scrim-drift-check.mjs`). That apparatus
// retired with its subject: its whole ability to fail was PARASITIC ON THE
// DEAD GENERATOR. Its self-test had to delete a suppressor first, so that the
// generator had a cell to itself and the probe had a scrim to see. Remove the
// generator and that arm cannot fire — the instrument would have gone quietly
// vacuous while still printing a confident eight-row table.
//
// So the guard moved from "which of these five rules wins in each of eight
// cells" to "is there a sixth". This one is cheaper, has no browser, no
// fixture and no copy to drift, and it refuses a shape the old one could not
// even express: a scrim written WITHOUT `:has()`, or on `::before`, or under a
// class nobody wrote down.
//
// ── AN ENUMERATION IS A SNAPSHOT, A PREDICATE IS A RULE ──────────────────────
// This does NOT grep for the five retired selectors. That family grew from one
// rule to five without any gate noticing, precisely because everything
// watching it was watching a list. The predicate is structural — subject plus
// pseudo-element — so a scrim that arrives under a name nobody anticipated
// still lands in front of it.
//
// ── AN ABSENCE ASSERTION IS THE ONE A DEAD PARSER PASSES FOR FREE ────────────
// "Zero matches" is the PASS condition here, which inverts the usual hazard: a
// `<style>` block moved, an at-rule reshaped, a HEEx construct the walker
// cannot cross, and this file reports a serene green forever. Two liveness
// gates run BEFORE the verdict and REFUSE (exit 2) rather than pass:
//
//   1. the sheet must parse at least RULE_FLOOR style rules, and
//   2. the subject itself must still be visible — at least one rule whose
//      selector names `.editor-with-preview` WITHOUT a pseudo-element.
//
// Gate 2 is the load-bearing one. A parser that stops seeing
// `.editor-with-preview` altogether would satisfy the verdict and gate 1 at
// the same time.
//
// ── COMMENTS ARE NOT CODE, AND THE SHIPPED FILE PROVES IT ────────────────────
// root.html.heex records what was retired, and that note quotes the retired
// selector verbatim. A text grep would red on the very comment explaining the
// abolition. The walker below treats comments as inert, and `--self-test`
// asserts the shipped source is green WITH that quotation present, so the
// property is measured on the real file rather than promised in a header.
//
// Node 22. No dependencies at all: no playwright, no browser, no network.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '..');
const SOURCE = path.join(REPO, 'api', 'lib', 'barkpark_web', 'layouts', 'root.html.heex');

// The parser's liveness floor. Not the contract — the emptiness of the scrim
// set is the contract — but a guard against a walker that silently stops
// matching and then reports an absence it never looked for. The sheet parses
// ~1100 rules today; this sits far enough below that ordinary churn cannot
// reach it and a broken parser cannot clear it.
const RULE_FLOOR = 500;

class AbolitionError extends Error {}
const die = (msg) => { throw new AbolitionError(msg); };

// ── CSS out of an HTML/HEEx document ─────────────────────────────────────────

// Every <style> block, concatenated in document order. root.html.heex has two
// (a <link> splits them); a rule in the second must not be invisible here.
function styleBlocks(src) {
  const out = [];
  const re = /<style[^>]*>([\s\S]*?)<\/style>/gi;
  let m;
  while ((m = re.exec(src)) !== null) out.push(m[1]);
  return out;
}

// A flat walk: comments and strings are inert, `{`/`}` nest. Every style rule
// is emitted with the at-rule preludes enclosing it, so an offender inside
// `@container panel (max-width: 860px)` is reported with the condition that
// gates it rather than as a bare selector.
function parseRules(css) {
  const rules = [];
  const stack = [];
  let buf = '';
  let i = 0;
  const n = css.length;

  while (i < n) {
    const c = css[i];

    if (c === '/' && css[i + 1] === '*') {
      const end = css.indexOf('*/', i + 2);
      i = end === -1 ? n : end + 2;
      buf += ' ';
      continue;
    }
    if (c === '"' || c === "'") {
      const quote = c;
      let j = i + 1;
      while (j < n && css[j] !== quote) j += css[j] === '\\' ? 2 : 1;
      buf += css.slice(i, Math.min(j + 1, n));
      i = j + 1;
      continue;
    }
    if (c === '{') {
      const prelude = buf.trim();
      buf = '';
      if (prelude.startsWith('@')) {
        stack.push(norm(prelude));
        i += 1;
        continue;
      }
      let depth = 1;
      let j = i + 1;
      let body = '';
      while (j < n && depth > 0) {
        const d = css[j];
        if (d === '/' && css[j + 1] === '*') { const e = css.indexOf('*/', j + 2); j = e === -1 ? n : e + 2; continue; }
        if (d === '"' || d === "'") {
          const q = d; let k = j + 1;
          while (k < n && css[k] !== q) k += css[k] === '\\' ? 2 : 1;
          body += css.slice(j, Math.min(k + 1, n)); j = k + 1; continue;
        }
        if (d === '{') depth += 1;
        if (d === '}') { depth -= 1; if (depth === 0) { j += 1; break; } }
        body += d;
        j += 1;
      }
      rules.push({ at: [...stack], selectors: splitSelectors(prelude), decls: splitDecls(body) });
      i = j;
      continue;
    }
    if (c === '}') {
      if (stack.length) stack.pop();
      buf = '';
      i += 1;
      continue;
    }
    buf += c;
    i += 1;
  }
  return rules;
}

const norm = (s) => s.replace(/\s+/g, ' ').trim();

// Depth-aware: a comma inside `:has(...)` or `:is(...)` is not a list break.
function splitSelectors(prelude) {
  const out = [];
  let depth = 0;
  let cur = '';
  for (const ch of prelude) {
    if (ch === '(' || ch === '[') depth += 1;
    else if (ch === ')' || ch === ']') depth -= 1;
    if (ch === ',' && depth === 0) { out.push(norm(cur)); cur = ''; continue; }
    cur += ch;
  }
  if (norm(cur)) out.push(norm(cur));
  return out;
}

function splitDecls(body) {
  const out = [];
  let depth = 0;
  let cur = '';
  for (const ch of body) {
    if (ch === '(') depth += 1;
    else if (ch === ')') depth -= 1;
    if (ch === ';' && depth === 0) { if (norm(cur)) out.push(norm(cur)); cur = ''; continue; }
    cur += ch;
  }
  if (norm(cur)) out.push(norm(cur));
  return out;
}

// ── the predicate ────────────────────────────────────────────────────────────

// THE SUBJECT. Every scrim this desk has ever shipped hung off
// `.editor-with-preview`, the box that wraps the document and the inspector
// together — a scrim on anything narrower cannot cover both.
const SUBJECT = '.editor-with-preview';

// THE PSEUDO-ELEMENTS. Both spellings of both boxes: CSS2 single-colon
// `:after` is still valid and still generates one.
const PSEUDO = /::?(after|before)\b/;

// A selector "attaches a generated box to the subject" when it names the
// subject and a generated box. Deliberately NOT anchored to the start of the
// selector: four of the five retired rules were prefixed with an
// `html[data-width-bucket=...]` qualifier, and a start-anchored predicate
// would have seen one of them.
const generatesOnSubject = (sel) => sel.includes(SUBJECT) && PSEUDO.test(sel);

// The liveness sentinel: the subject is still parsed, in a rule that is NOT an
// offender. If this disappears the walker has lost the subject and the verdict
// below is void, not clean.
const isSubjectSentinel = (sel) => sel.includes(SUBJECT) && !PSEUDO.test(sel);

function analyse(file, { label = 'source' } = {}) {
  if (!fs.existsSync(file)) die(`${label} not found: ${file}`);
  return analyseSource(fs.readFileSync(file, 'utf8'), { file, label });
}

function analyseSource(src, { file = '<memory>', label = 'source' } = {}) {
  const blocks = styleBlocks(src);
  if (!blocks.length) {
    die(`REFUSING TO REPORT: the ${label} (${file}) has no <style> block at all. ` +
        `The extractor can see no CSS, so "no scrim found" would mean "nothing was looked at".`);
  }
  const rules = blocks.flatMap((b) => parseRules(b));
  const offenders = [];
  let sentinels = 0;
  for (const r of rules) {
    if (r.selectors.some(isSubjectSentinel)) sentinels += 1;
    for (const sel of r.selectors) {
      if (generatesOnSubject(sel)) offenders.push({ at: r.at, selector: sel, decls: r.decls });
    }
  }
  return { file, label, styleBlocks: blocks.length, totalRules: rules.length, sentinels, offenders };
}

// ── the check ────────────────────────────────────────────────────────────────

// Throws AbolitionError for a REFUSAL (a reading it will not take). An
// ordinary finding comes back as `ok: false` with the offenders, so the
// self-test can assert on it instead of catching an exception.
function check(src, meta) {
  const a = typeof src === 'string' ? analyseSource(src, meta) : analyse(src.file, meta);

  if (a.totalRules < RULE_FLOOR) {
    die(`REFUSING TO REPORT: the ${a.label} (${a.file}) parsed ${a.totalRules} style rule(s), ` +
        `below the floor of ${RULE_FLOOR}. An absence assertion over a sheet the walker cannot ` +
        `read is not a clean bill of health — it is a measurement that never happened. Either ` +
        `the sheet genuinely shrank (lower RULE_FLOOR in the same PR and say why) or the walker broke.`);
  }
  if (a.sentinels === 0) {
    die(`REFUSING TO REPORT: the ${a.label} (${a.file}) parsed ${a.totalRules} rule(s) but NOT ONE ` +
        `naming \`${SUBJECT}\`. The subject of this check is invisible to the walker, so "no scrim ` +
        `on ${SUBJECT}" is trivially true and says nothing about the sheet.`);
  }
  return { ...a, ok: a.offenders.length === 0 };
}

function describe(o) {
  const at = o.at.length ? `${o.at.join(' > ')} > ` : '';
  return `${at}${o.selector} { ${o.decls.join('; ')} }`;
}

function report(v, { quiet = false } = {}) {
  if (!quiet) {
    console.log(`source   ${path.relative(REPO, v.file)}  [${v.styleBlocks} <style> block(s), ` +
                `${v.totalRules} rules parsed, ${v.sentinels} naming ${SUBJECT}]`);
  }
  if (v.ok) {
    if (!quiet) {
      console.log(`\n  OK  THE SCRIM STAYS ABOLISHED: no style rule attaches a \`::after\`/\`::before\` ` +
                  `to \`${SUBJECT}\`. The inspector overlay does not dim the document it covers, in any ` +
                  `bucket, at any pane width, opened by the server or by the user.`);
    }
    return true;
  }
  console.error(`\n  FAIL  THE SCRIM IS BACK: ${v.offenders.length} rule(s) attach a generated box to ` +
                `\`${SUBJECT}\`.\n`);
  for (const o of v.offenders) console.error(`    ${describe(o)}`);
  console.error(
    `\n  A \`content: none\` here is NOT a fix — that is the exact shape this family grew out of: one\n` +
    `  generator and four cancellations, none of which ever painted. If the overlay now needs to say\n` +
    `  it is on top, say it with the panel (it already covers the pane below \`wide\`), not with a wash\n` +
    `  over live prose — D127 ruled that indeterminate. If the ruling has genuinely changed, change\n` +
    `  THIS FILE in the same PR and record who changed it.`);
  return false;
}

// ── self-test ────────────────────────────────────────────────────────────────

// A check whose pass condition is "found nothing" must be shown finding
// something. Each arm names the way this file could have gone quietly vacuous.
function selfTest() {
  const src = fs.readFileSync(SOURCE, 'utf8');
  const arms = [];
  const add = (name, fn) => {
    try {
      const msg = fn();
      arms.push({ name, pass: true, msg });
    } catch (e) {
      arms.push({ name, pass: false, msg: e.message });
    }
  };

  // Splice a rule into the FIRST <style> block of a copy of the real sheet.
  const plant = (rule) => src.replace(/(<style[^>]*>)/i, `$1\n${rule}\n`);
  const verdict = (text) => check(text, { file: '<planted copy>', label: 'planted source' });

  const mustFail = (label, rule) => add(label, () => {
    const v = verdict(plant(rule));
    if (v.ok) throw new Error(`planted ${label} and the check still passed — it cannot see this shape`);
    return `caught: ${describe(v.offenders[0])}`;
  });

  const mustPass = (label, rule) => add(label, () => {
    const v = verdict(plant(rule));
    if (!v.ok) throw new Error(`planted ${label} and the check RED — it over-matches: ${describe(v.offenders[0])}`);
    return 'correctly ignored';
  });

  // ARM 0 — the real file, with the retired selector quoted in a comment.
  add('the shipped sheet is green WITH the retired selector quoted in a comment', () => {
    if (!src.includes('.editor-with-preview:has(.bp-doc-sidebar.is-open)::after')) {
      throw new Error(
        'the retirement note in root.html.heex no longer quotes the retired selector, so this arm ' +
        'proves nothing about comment-blindness. Either restore the quotation or delete this arm ' +
        'deliberately — do not leave it passing on an absent premise.');
    }
    const v = check({ file: SOURCE }, { label: 'source' });
    if (!v.ok) throw new Error(`the shipped sheet RED: ${describe(v.offenders[0])}`);
    return `green over ${v.totalRules} rules with the quotation present — comments are inert`;
  });

  // ARMS 1-4 — the shapes that must red.
  mustFail('a GENERATOR, the exact rule that was retired',
    '@container panel (max-width: 860px) { .editor-with-preview:has(.bp-doc-sidebar.is-open)::after { content: ""; background: #000; } }');
  mustFail('a SUPPRESSOR — a cancellation is the same family, not a fix',
    'html[data-width-bucket="standard"] .editor-with-preview:has(.bp-doc-sidebar.is-open)::after { content: none; }');
  mustFail('a `::before` scrim — the old apparatus was `::after`-only',
    '.editor-with-preview::before { content: ""; position: absolute; inset: 0; }');
  mustFail('a scrim with NO `:has()` and an unanticipated class',
    '.editor-with-preview.bp-inspector-over:after { content: ""; background: rgba(0,0,0,.4); }');

  // ARMS 5-6 — the shapes that must NOT red. A predicate that reds on
  // everything near the subject is not discriminating, it is just loud.
  mustPass('an ordinary `.editor-with-preview` rule with no pseudo-element',
    '.editor-with-preview { outline: 0; }');
  mustPass('an `::after` on a DIFFERENT subject',
    '.editor-body::after { content: ""; display: block; }');

  // ARM 7 — the refusal that makes an absence mean something.
  add('a sheet the walker cannot read is REFUSED, never green', () => {
    let refused = null;
    try { check('<style>.editor-with-preview { color: red; }</style>', { file: '<tiny>', label: 'tiny source' }); }
    catch (e) { refused = e; }
    if (!(refused instanceof AbolitionError)) throw new Error('a 1-rule sheet was NOT refused — the liveness floor is inert');
    if (!refused.message.includes(String(RULE_FLOOR))) throw new Error('the refusal did not name the floor it tripped');
    return 'refused, naming the floor';
  });

  // ARM 8 — the refusal gate 1 cannot catch on its own.
  add('a sheet with rules but NO subject is REFUSED, never green', () => {
    const filler = Array.from({ length: RULE_FLOOR + 10 }, (_, k) => `.filler-${k} { color: red; }`).join('\n');
    let refused = null;
    try { check(`<style>${filler}</style>`, { file: '<subjectless>', label: 'subjectless source' }); }
    catch (e) { refused = e; }
    if (!(refused instanceof AbolitionError)) {
      throw new Error(
        `${RULE_FLOOR + 10} rules and not one naming ${SUBJECT} passed the check — the verdict is ` +
        'trivially true whenever the walker loses the subject, which is the whole hazard');
    }
    if (!refused.message.includes(SUBJECT)) throw new Error('the refusal did not name the missing subject');
    return 'refused, naming the missing subject';
  });

  // ARM 9 — no <style> at all.
  add('a document with no <style> block is REFUSED, never green', () => {
    let refused = null;
    try { check('<html><body>nothing here</body></html>', { file: '<styleless>', label: 'styleless source' }); }
    catch (e) { refused = e; }
    if (!(refused instanceof AbolitionError)) throw new Error('a document with no CSS was not refused');
    return 'refused';
  });

  let failed = 0;
  for (const a of arms) {
    console.log(`  ${a.pass ? 'PASS' : 'FAIL'}  ${a.name}`);
    console.log(`          ${a.msg}`);
    if (!a.pass) failed += 1;
  }
  console.log('');
  if (failed) {
    console.error(`FAIL: ${failed} self-test arm(s) failed. This check certifies nothing.`);
    return false;
  }
  console.log(`--self-test: ${arms.length}/${arms.length} passed — the check reds on four scrim shapes, ` +
              `ignores two near-misses, and refuses three unreadable sheets.`);
  return true;
}

// ── main ─────────────────────────────────────────────────────────────────────

function main(argv) {
  const args = argv.slice(2);
  const unknown = args.filter((a) => !['--self-test', '--list', '--help', '-h'].includes(a));
  if (unknown.length) {
    console.error(`unknown argument(s): ${unknown.join(' ')}`);
    return 2;
  }
  if (args.includes('--help') || args.includes('-h')) {
    console.log(fs.readFileSync(fileURLToPath(import.meta.url), 'utf8')
      .split('\n').filter((l) => l.startsWith('//')).map((l) => l.slice(3)).join('\n'));
    return 0;
  }

  let v;
  try {
    v = check({ file: SOURCE }, { label: 'source' });
  } catch (e) {
    if (e instanceof AbolitionError) { console.error(`  REFUSED: ${e.message}`); return 2; }
    throw e;
  }

  if (args.includes('--list')) {
    console.log(`source   ${path.relative(REPO, v.file)}  [${v.styleBlocks} <style> block(s), ` +
                `${v.totalRules} rules parsed]`);
    console.log(`subject  ${SUBJECT} — ${v.sentinels} rule(s) name it without a pseudo-element`);
    console.log(`scrim    ${v.offenders.length} rule(s) attach \`::after\`/\`::before\` to it`);
    for (const o of v.offenders) console.log(`  ${describe(o)}`);
  }

  const ok = report(v, { quiet: args.includes('--list') });

  if (args.includes('--self-test')) {
    console.log('');
    return selfTest() && ok ? 0 : 1;
  }
  return ok ? 0 : 1;
}

process.exitCode = main(process.argv);
