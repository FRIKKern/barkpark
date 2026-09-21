#!/usr/bin/env node
//
// studio-scrim-drift-check.mjs — THE TIE BACK TO THE SOURCE.
//
// scripts/fixtures/studio-scrim-threshold.html reproduces the Studio desk's
// scrim cascade so scripts/studio-scrim-threshold-control.mjs can force
// `.editor-panel` across the 860px container threshold offline. The fixture's
// own header says the rules are "COPIED VERBATIM" from
// api/lib/barkpark_web/layouts/root.html.heex — but a copy with no tie back is
// an UNLOCKED MIRROR: edit a suppressor in root.html.heex and the control keeps
// printing a confident matrix for a cascade that no longer ships. It would then
// certify the fixture, not the product.
//
// This file is the tie. It EXTRACTS the scrim rules from root.html.heex BY
// SELECTOR — never from a second hand-typed copy, which would be a tautology
// that reads exactly like coverage — and diffs them against the fixture's.
//
//   node scripts/studio-scrim-drift-check.mjs             # the diff, exit 1 on drift
//   node scripts/studio-scrim-drift-check.mjs --self-test # + prove it can fail
//   node scripts/studio-scrim-drift-check.mjs --list      # print what it extracted
//
// ── WHY NOT LINE NUMBERS ─────────────────────────────────────────────────────
// The fixture already carries `root.html.heex:1389` style citations. Line
// numbers alone are NOT a check, they are documentation that goes stale: when
// this file was written, EVERY citation in the fixture was already wrong (the
// generator had moved :1389 -> :1599, suppressor A :2029 -> :2336) and a FIFTH
// scrim rule had landed at :2484 that the fixture did not carry at all. Nothing
// noticed, because nothing was comparing.
//
// ── EXTRACTION IS A PREDICATE, NOT A LIST ────────────────────────────────────
// The scrim family is "every style rule whose selector list names
// `.editor-with-preview`, a `:has(` on `.bp-doc-sidebar`, and `::after`".
// A list of four would have been a SNAPSHOT: the fifth rule would have been
// invisible to it, which is precisely how the fixture rotted. The predicate
// sees a new sibling the day it lands.
//
// The `.editor-panel` base rule rides along as a second group: its
// `container-type: inline-size; container-name: panel` is what makes the
// 861/860 question a CONTAINER question at all. Strip that declaration in
// production and the generator becomes unreachable while every scrim rule still
// matches byte-for-byte — drift the rule-level diff alone cannot see.
//
// ── REFUSES AN EMPTY EXTRACTION ──────────────────────────────────────────────
// Zero rules found on either side is exit 2, never green. A parser that stops
// matching — a `<style>` moved, an at-rule reshaped, a HEEx construct it cannot
// walk — otherwise reports "no differences" forever, which is the loudest
// possible lie a drift check can tell.
//
// Node 22. No dependencies at all: no playwright, no browser, no network.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, '..');
const SOURCE = path.join(REPO, 'api', 'lib', 'barkpark_web', 'layouts', 'root.html.heex');
const FIXTURE = path.join(HERE, 'fixtures', 'studio-scrim-threshold.html');

// The parser's own liveness floor, per group. Not the contract — the ordered
// diff below is the contract — but a guard against a parser that silently
// under-matches and then reports agreement between two empty lists.
const SCRIM_FLOOR = 4;

class DriftError extends Error {}
const die = (msg) => { throw new DriftError(msg); };

// ── CSS out of an HTML/HEEx document ─────────────────────────────────────────

// Every <style> block, concatenated in document order. root.html.heex has two
// (the <link> splits them); a rule in the second must not be invisible here.
function styleBlocks(src) {
  const out = [];
  const re = /<style[^>]*>([\s\S]*?)<\/style>/gi;
  let m;
  while ((m = re.exec(src)) !== null) out.push(m[1]);
  return out;
}

// A flat walk: comments and strings are inert, `{`/`}` nest. Every style rule
// is emitted with the at-rule preludes enclosing it, so a rule inside
// `@container panel (max-width: 860px)` can never compare equal to the same
// selector at top level.
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
      // A style rule. Take its body up to the matching brace, depth-counted so
      // CSS nesting (were it to appear) cannot end the rule early.
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

// ── the two selector predicates ──────────────────────────────────────────────

// THE SCRIM FAMILY. Anything that generates or suppresses the overlay pseudo
// element does all three of these things in its selector.
const isScrimSelector = (sel) =>
  sel.includes('.editor-with-preview') &&
  sel.includes(':has(') &&
  sel.includes('.bp-doc-sidebar') &&
  sel.includes('::after');

const isScrimRule = (r) => r.selectors.some(isScrimSelector);

// THE CONTAINER. Exactly the bare `.editor-panel` rule at top level — not
// `.editor-panel.sheet-editor`, not a bucket-scoped override.
const isPanelRule = (r) => r.at.length === 0 && r.selectors.length === 1 && r.selectors[0] === '.editor-panel';

function extract(file, label) {
  if (!fs.existsSync(file)) die(`${label} not found: ${file}`);
  const src = fs.readFileSync(file, 'utf8');
  const blocks = styleBlocks(src);
  if (!blocks.length) die(`${label} (${file}) has no <style> block — the extractor cannot see any CSS at all.`);
  const rules = blocks.flatMap((b) => parseRules(b));
  return {
    file,
    label,
    styleBlocks: blocks.length,
    totalRules: rules.length,
    scrim: rules.filter(isScrimRule),
    panel: rules.filter(isPanelRule),
  };
}

// ── rendering + diff ─────────────────────────────────────────────────────────

function render(rules) {
  const lines = [];
  for (const r of rules) {
    for (const a of r.at) lines.push(`${a} {`);
    // One selector per LINE would be prettier, but a diff prefixes LINES:
    // a multi-line selector renders its continuation without a `-`/`+` and
    // the report stops being readable exactly where a comma-list drifts.
    lines.push(`${r.selectors.join(', ')} {`);
    for (const d of r.decls) lines.push(`  ${d};`);
    lines.push('}');
    for (let k = 0; k < r.at.length; k += 1) lines.push('}');
  }
  return lines;
}

// A plain LCS diff. Deliberately not a library: this script has no deps, and a
// drift report that cannot be produced offline is a drift report nobody runs.
function unified(aLines, bLines, aName, bName) {
  const n = aLines.length;
  const m = bLines.length;
  const lcs = Array.from({ length: n + 1 }, () => new Array(m + 1).fill(0));
  for (let i = n - 1; i >= 0; i -= 1) {
    for (let j = m - 1; j >= 0; j -= 1) {
      lcs[i][j] = aLines[i] === bLines[j] ? lcs[i + 1][j + 1] + 1 : Math.max(lcs[i + 1][j], lcs[i][j + 1]);
    }
  }
  const out = [`--- ${aName}`, `+++ ${bName}`];
  let i = 0;
  let j = 0;
  while (i < n && j < m) {
    if (aLines[i] === bLines[j]) { out.push(`  ${aLines[i]}`); i += 1; j += 1; }
    else if (lcs[i + 1][j] >= lcs[i][j + 1]) { out.push(`- ${aLines[i]}`); i += 1; }
    else { out.push(`+ ${bLines[j]}`); j += 1; }
  }
  while (i < n) { out.push(`- ${aLines[i]}`); i += 1; }
  while (j < m) { out.push(`+ ${bLines[j]}`); j += 1; }
  return out;
}

// ── the check ────────────────────────────────────────────────────────────────

// Returns a verdict object. Throws DriftError only for a REFUSAL (a reading it
// will not take); ordinary drift comes back as `ok: false` with the diff, so
// the self-test can assert on it.
function check({ sourcePath = SOURCE, fixturePath = FIXTURE, quiet = false } = {}) {
  const src = extract(sourcePath, 'source');
  const fix = extract(fixturePath, 'fixture');

  for (const side of [src, fix]) {
    if (side.scrim.length === 0) {
      die(`REFUSING TO REPORT: extracted ZERO scrim rules from the ${side.label} ` +
          `(${side.file}; ${side.styleBlocks} <style> block(s), ${side.totalRules} rules parsed). ` +
          `An empty extraction compares equal to any other empty extraction, so a green here ` +
          `would mean "the parser stopped matching", not "the copy is faithful".`);
    }
    if (side.scrim.length < SCRIM_FLOOR) {
      die(`REFUSING TO REPORT: the ${side.label} (${side.file}) yielded ${side.scrim.length} ` +
          `scrim rule(s), below the floor of ${SCRIM_FLOOR}. Either the cascade shrank — say so ` +
          `deliberately by lowering SCRIM_FLOOR in the same PR — or the extractor is under-matching.`);
    }
    if (side.panel.length !== 1) {
      die(`REFUSING TO REPORT: the ${side.label} (${side.file}) has ${side.panel.length} top-level ` +
          `\`.editor-panel\` rules, expected exactly 1. That rule carries \`container-type\`, which is ` +
          `what makes 861/860 a container question; an ambiguous one cannot be diffed.`);
    }
  }

  const groups = [
    { name: 'the scrim cascade', a: src.scrim, b: fix.scrim },
    { name: 'the .editor-panel container rule', a: src.panel, b: fix.panel },
  ];

  const drifted = [];
  for (const g of groups) {
    const aL = render(g.a);
    const bL = render(g.b);
    if (aL.join('\n') !== bL.join('\n')) {
      drifted.push({ ...g, diff: unified(aL, bL, `root.html.heex (${g.name})`, `fixture (${g.name})`) });
    }
  }

  if (!quiet) {
    console.log(`source   ${path.relative(REPO, sourcePath)}  [${src.styleBlocks} <style> block(s), ${src.totalRules} rules parsed]`);
    console.log(`fixture  ${path.relative(REPO, fixturePath)}  [${fix.styleBlocks} <style> block(s), ${fix.totalRules} rules parsed]`);
    console.log(`extracted BY SELECTOR: ${src.scrim.length} scrim rule(s) + ${src.panel.length} container rule from the source, ` +
      `${fix.scrim.length} + ${fix.panel.length} from the fixture`);
  }

  return { ok: drifted.length === 0, drifted, src, fix };
}

function report(verdict) {
  if (verdict.ok) {
    console.log(`\n  OK  the fixture's copy is FAITHFUL: every rule the selector predicate finds in ` +
      `root.html.heex is present in the fixture, in the same order, with the same declarations.`);
    return 0;
  }
  for (const d of verdict.drifted) {
    console.error(`\nDRIFT in ${d.name} — the fixture no longer reproduces what root.html.heex ships:\n`);
    for (const line of d.diff) console.error(`  ${line}`);
  }
  console.error(`\nFAIL: the fixture is an UNLOCKED MIRROR of root.html.heex and it has drifted. ` +
    `Every reading scripts/studio-scrim-threshold-control.mjs takes against it certifies the ` +
    `FIXTURE, not the product. Reconcile scripts/fixtures/studio-scrim-threshold.html with the ` +
    `\`+\`/\`-\` lines above, then re-run the control.`);
  return 1;
}

// ── self-test ────────────────────────────────────────────────────────────────

// Three arms, and the first is the one that matters: a mutation check whose
// POSITIVE control is missing proves only that the mutator works.
async function selfTest() {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'scrim-drift-'));
  let failures = 0;
  const arm = (name, fn) => {
    try { fn(); console.log(`  PASS  ${name}`); }
    catch (err) { failures += 1; console.error(`  FAIL  ${name}\n        ${err.message.split('\n')[0]}`); }
  };

  try {
    console.log('\nSELF-TEST:');

    // ARM 1 — POSITIVE CONTROL. The predicate can see the rules in the real
    // source. Without this, arms 2 and 3 pass on an extractor that finds
    // nothing and refuses everything.
    arm(`positive control: the predicate finds >= ${SCRIM_FLOOR} scrim rules in the real root.html.heex`, () => {
      const src = extract(SOURCE, 'source');
      if (src.scrim.length < SCRIM_FLOOR) throw new Error(`found ${src.scrim.length}`);
      const gen = src.scrim.find((r) => r.at.some((a) => a.includes('@container panel (max-width: 860px)')));
      if (!gen) throw new Error('no rule inside @container panel (max-width: 860px) — the generator is not being seen');
      console.log(`        found ${src.scrim.length}: ${src.scrim.map((r) => (r.at.length ? '@container/' : '') + r.selectors[0].slice(0, 46)).join('\n              ')}`);
    });

    // ARM 2 — MUTATION. One suppressor edited in a COPY of root.html.heex must
    // red with a diff. The mutation is the cheapest real one there is: flip
    // `content: none` to `content: ""` on the wide suppressor, which is exactly
    // the edit that would un-abolish the wide scrim in production.
    arm('mutation: one suppressor edited in root.html.heex reds with a diff', () => {
      const mutantPath = path.join(tmp, 'root.mutant.html.heex');
      const src = fs.readFileSync(SOURCE, 'utf8');
      const needle = 'html[data-width-bucket="wide"]';
      const at = src.indexOf(needle);
      if (at === -1) throw new Error(`the wide suppressor selector ${needle} is not in ${SOURCE}`);
      const declAt = src.indexOf('content: none;', at);
      if (declAt === -1 || declAt - at > 400) throw new Error('no `content: none;` follows the wide suppressor — the mutator would mutate the wrong rule');
      const mutant = src.slice(0, declAt) + 'content: "";' + src.slice(declAt + 'content: none;'.length);
      if (mutant === src) throw new Error('the mutation changed nothing');
      fs.writeFileSync(mutantPath, mutant);
      const v = check({ sourcePath: mutantPath, quiet: true });
      if (v.ok) throw new Error('the check stayed GREEN against a mutated source — it cannot fail');
      const diff = v.drifted.flatMap((d) => d.diff).join('\n');
      if (!diff.includes('content: ""') || !diff.includes('content: none')) {
        throw new Error('the diff does not show the changed declaration');
      }
      console.log(`        red, and the diff names the edit:\n${v.drifted[0].diff.filter((l) => l.startsWith('-') || l.startsWith('+')).map((l) => `          ${l}`).join('\n')}`);
    });

    // ARM 3 — THE EMPTY-EXTRACTION REFUSAL. Point it at a file with no CSS at
    // all and it must exit non-zero, not report "no differences".
    arm('refusal: an empty extraction is a REFUSAL, never a green', () => {
      const emptyPath = path.join(tmp, 'empty.html.heex');
      fs.writeFileSync(emptyPath, '<html><head></head><body></body></html>\n');
      let refusal = null;
      try { check({ sourcePath: emptyPath, quiet: true }); } catch (err) { refusal = err; }
      if (!refusal) throw new Error('an empty source was accepted — the refusal is dead');
      if (!(refusal instanceof DriftError)) throw new Error(`refused with the wrong error type: ${refusal}`);

      const emptyStylePath = path.join(tmp, 'empty-style.html.heex');
      fs.writeFileSync(emptyStylePath, '<html><head><style>\nbody { margin: 0; }\n</style></head></html>\n');
      let refusal2 = null;
      try { check({ sourcePath: emptyStylePath, quiet: true }); } catch (err) { refusal2 = err; }
      if (!refusal2) throw new Error('a CSS-bearing file with ZERO scrim rules was accepted — the floor is dead');
      console.log(`        REFUSED (no <style>):   ${refusal.message.split('\n')[0].slice(0, 96)}`);
      console.log(`        REFUSED (0 scrim rules): ${refusal2.message.split('\n')[0].slice(0, 96)}`);
    });
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }

  if (failures) {
    console.error(`\nFAIL: ${failures} self-test arm(s) failed. This drift check certifies nothing.`);
    return 1;
  }
  console.log(`\n  OK  THE DRIFT CHECK CAN FAIL, and it refuses an empty reading rather than greening on one.`);
  return 0;
}

// ── main ─────────────────────────────────────────────────────────────────────

const HELP = `studio-scrim-drift-check.mjs — ties scripts/fixtures/studio-scrim-threshold.html
back to api/lib/barkpark_web/layouts/root.html.heex.

  --self-test   also prove the check can fail (mutate a suppressor in a COPY of
                root.html.heex) and that it refuses an empty extraction
  --list        print every rule the selector predicate extracted, both sides
  --help

Fully offline and dependency-free: no playwright, no browser, no network.`;

async function main() {
  const argv = process.argv.slice(2);
  if (argv.includes('--help') || argv.includes('-h')) { console.log(HELP); return 0; }

  const verdict = check({});
  if (argv.includes('--list')) {
    console.log('\nSOURCE (root.html.heex), by selector:');
    for (const line of render(verdict.src.scrim)) console.log(`  ${line}`);
    console.log('\nFIXTURE:');
    for (const line of render(verdict.fix.scrim)) console.log(`  ${line}`);
  }
  let code = report(verdict);
  if (argv.includes('--self-test')) code = (await selfTest()) || code;
  return code;
}

main()
  .then((code) => { process.exit(code); })
  .catch((err) => {
    if (err instanceof DriftError) console.error(`\nFAIL: ${err.message}`);
    else console.error(`\nFAIL (unexpected): ${err && err.stack ? err.stack : err}`);
    process.exit(2);
  });
