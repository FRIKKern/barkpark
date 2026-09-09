#!/usr/bin/env node
//
// repo-papers-freshness.mjs — the .demo-content/repo-papers/*.json snapshots are
// COPIES of docs/*.md with no lock. Nothing produced them after the one-off
// mirroring commit (6bd70d201), nothing regenerates them, and until this script
// nothing in the repo READ THE PAIR at all: `git grep -l repo-papers` over
// scripts/, Makefile, .github/ and tooling/ returned exactly one hit and it was
// an EXCLUDE regex. So drift was only ever found by a human who already
// suspected it — which is how ops-adding-a-domain.json shipped an operator
// instruction to "Re-enable force_ssl" for weeks after the doc said the
// opposite (found by task-1fd898cb53bd4831, hand-fixed for that ONE file by
// #14617). Golden Rule 5 and Past Mistake 5 both record what force_ssl without
// HTTPS did to this box. A stale snapshot is a plausible, specific, WRONG
// instruction that re-creates a known outage.
//
// WHAT IT MEASURES, stated so nobody reads more into a green than it earns.
// The snapshots are NOT byte-copies: the mirroring re-authored each doc into
// PortableDoc blocks, so no diff of the two files could ever be meaningful.
// What IS comparable is the HARD TERMS — the things a reader would act on:
//
//   heading    every block of type "heading" (its .text)
//   code-span  every text node marked "code"
//   code-line  every line of every "code" block
//
// The assertion is ONE-DIRECTIONAL CONTAINMENT: every hard term in the snapshot
// must still appear somewhere in its source doc. That is the direction the harm
// runs in — a snapshot ASSERTING something the doc no longer says is the wrong
// instruction; a doc that grew a new section the snapshot lacks is merely
// incomplete. Both sides are normalized first (markdown backticks/asterisks and
// backslash-escapes stripped, typographic dashes and quotes folded to ASCII,
// whitespace collapsed) because those differ by transcription, not by meaning.
//
// THIS INSTRUMENT HAS FALSE POSITIVES AND THEY ARE NOT HIDDEN. The mirroring
// re-ordered and re-worded plenty ("404 not_found" in the snapshot for
// "`not_found` 404" in the doc). Every such term is reported BY NAME like any
// other, and the per-paper `baseline` in the manifest is where the pre-existing
// pile is PARKED — not excused. A baseline is a debt number, not a verdict:
// what the gate enforces is that the number cannot GROW. An `exempt` entry is
// the opposite: a term someone deliberately allowed to diverge, each carrying a
// written reason, and the gate REFUSES an exemption nobody justified and one
// that no longer applies. That is the difference between a ledger that shrinks
// and an allowlist that rots.
//
// EXIT CODES.  0 = every paper within its baseline.  1 = FAIL (a paper drifted
// past its baseline, or an exemption is unjustified/stale).  2 = REFUSE, the
// harness cannot measure (unmapped snapshot, missing source, an extractor that
// found no terms at all) — never reported as clean.
//
// Usage:
//   node scripts/repo-papers-freshness.mjs            # gate
//   node scripts/repo-papers-freshness.mjs --report   # name every drift, always exit 0
//   node scripts/repo-papers-freshness.mjs --selftest # 10 planted arms, exits nonzero if any arm misbehaves
//
// REPO_PAPERS_ROOT overrides the tree it reads, which is what --selftest drives.

import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const SELF = fileURLToPath(import.meta.url);
const ROOT = process.env.REPO_PAPERS_ROOT || process.cwd();
const MANIFEST_REL = 'scripts/repo-papers-freshness.manifest.json';
const MIN_TERM_LEN = 6;
const MIN_REASON_LEN = 20;
const NBSP = String.fromCharCode(160);

function normalize(s) {
  return s
    .replace(/\\([*_`[\]()#+\-.!|~<>])/g, '$1')
    .split('`').join('')
    .split('*').join('')
    .replace(/[—–]/g, '-')
    .replace(/[‘’]/g, "'")
    .replace(/[“”]/g, '"')
    .split(NBSP).join(' ')
    .replace(/\s+/g, ' ')
    .trim();
}

// Walk the whole block tree rather than the top level: callouts, list items and
// table cells all nest content, and a code span buried three levels down is
// exactly as load-bearing as one in a paragraph.
function collectTerms(node, out) {
  if (Array.isArray(node)) {
    for (const n of node) collectTerms(n, out);
    return out;
  }
  if (node && typeof node === 'object') {
    if (node.type === 'heading' && typeof node.text === 'string') out.push(['heading', node.text]);
    if (node.type === 'code' && typeof node.value === 'string') {
      for (const line of node.value.split('\n')) out.push(['code-line', line]);
    }
    if (node.type === 'text' && Array.isArray(node.marks) && node.marks.includes('code')
        && typeof node.value === 'string') out.push(['code-span', node.value]);
    for (const k of Object.keys(node)) {
      if (k === 'marks') continue;
      collectTerms(node[k], out);
    }
  }
  return out;
}

class Refuse extends Error {}

function readManifest(root) {
  const p = path.join(root, MANIFEST_REL);
  if (!fs.existsSync(p)) throw new Refuse(`manifest not found: ${MANIFEST_REL}`);
  let m;
  try { m = JSON.parse(fs.readFileSync(p, 'utf8')); }
  catch (e) { throw new Refuse(`manifest is not valid JSON: ${e.message}`); }
  if (!m || typeof m.snapshot_dir !== 'string' || !m.papers || typeof m.papers !== 'object') {
    throw new Refuse('manifest must carry a string snapshot_dir and an object papers');
  }
  return m;
}

function analyse(root) {
  const manifest = readManifest(root);
  const snapDir = path.join(root, manifest.snapshot_dir);
  if (!fs.existsSync(snapDir)) throw new Refuse(`snapshot_dir does not exist: ${manifest.snapshot_dir}`);

  const onDisk = fs.readdirSync(snapDir).filter((f) => f.endsWith('.json')).map((f) => f.slice(0, -5)).sort();
  const mapped = Object.keys(manifest.papers).sort();

  // BOTH DIRECTIONS. A snapshot with no manifest row is a file nothing checks —
  // the exact hole this script exists to close, so it must never be a silent
  // pass. A manifest row with no snapshot is a mapping that stopped describing
  // the tree.
  const unmapped = onDisk.filter((s) => !mapped.includes(s));
  const orphaned = mapped.filter((s) => !onDisk.includes(s));
  if (unmapped.length) throw new Refuse(`snapshot(s) with no manifest entry: ${unmapped.join(', ')}`);
  if (orphaned.length) throw new Refuse(`manifest entr(ies) with no snapshot file: ${orphaned.join(', ')}`);

  const results = [];
  for (const slug of mapped) {
    const entry = manifest.papers[slug];
    if (!entry || typeof entry.source !== 'string') throw new Refuse(`${slug}: manifest entry needs a string source`);
    const srcPath = path.join(root, entry.source);
    if (!fs.existsSync(srcPath)) throw new Refuse(`${slug}: source doc does not exist: ${entry.source}`);

    let snap;
    try { snap = JSON.parse(fs.readFileSync(path.join(snapDir, `${slug}.json`), 'utf8')); }
    catch (e) { throw new Refuse(`${slug}: snapshot is not valid JSON: ${e.message}`); }

    const haystack = normalize(fs.readFileSync(srcPath, 'utf8'));
    const snapText = fs.readFileSync(path.join(snapDir, `${slug}.json`), 'utf8');
    const raw = collectTerms(snap.blocks, []);
    const seen = new Set();
    const terms = [];
    for (const [kind, value] of raw) {
      const t = normalize(value);
      if (t.length < MIN_TERM_LEN) continue;
      const key = `${kind} ${t}`;
      if (seen.has(key)) continue;
      seen.add(key);
      terms.push([kind, t]);
    }
    // NON-VACUITY FLOOR — but keyed on the FILE, not on the count. A snapshot
    // whose block shape this walker cannot reach yields zero terms and would
    // otherwise pass with a perfect score: the green with no subject. Zero is
    // nevertheless a LEGITIMATE tree here — adr-0002-npm-dist-tag-publish.json
    // is a one-line redirect stub with a single ingress block and genuinely has
    // nothing hard in it. So the refusal fires only when the raw JSON CONTAINS
    // something the walker should have picked up and it picked up nothing,
    // which is the blind-extractor signature and not the empty-stub one.
    // The \\? arms matter: a snapshot can carry those nodes inside an escaped
    // JSON string, which is one concrete way the walker ends up reaching none.
    const hasCandidates = /\\?"type\\?"\s*:\s*\\?"(heading|code)\\?"|\\?"marks\\?"\s*:\s*\[[^\]]*\\?"code/.test(snapText);
    if (raw.length === 0 && hasCandidates) {
      throw new Refuse(`${slug}: the snapshot JSON carries heading/code nodes but the extractor found ZERO comparable terms — it cannot read this snapshot`);
    }

    const missing = terms.filter(([, t]) => !haystack.includes(t));
    const missingSet = new Set(missing.map(([, t]) => t));

    const exempt = Array.isArray(entry.exempt) ? entry.exempt : [];
    const problems = [];
    const exemptTerms = new Set();
    for (const ex of exempt) {
      if (!ex || typeof ex.term !== 'string' || !ex.term.trim()) {
        problems.push(`${slug}: an exempt entry has no term`);
        continue;
      }
      const t = normalize(ex.term);
      // FAIL CLOSED ON AN UNJUSTIFIED ENTRY. This is the whole point of
      // criterion 2: an allowlist that can grow by adding a line is not a
      // record of a decision, it is a way to make the gate stop talking.
      if (typeof ex.reason !== 'string' || ex.reason.trim().length < MIN_REASON_LEN) {
        problems.push(`${slug}: exemption "${ex.term}" carries no justification (reason must be >= ${MIN_REASON_LEN} chars)`);
        continue;
      }
      // AND ON A STALE ONE. An exemption whose term is no longer missing is
      // describing a world that ended; left in place it would silently absorb
      // some FUTURE drift that happens to match.
      const stillMissing = missingSet.has(t);
      if (!stillMissing) {
        problems.push(`${slug}: exemption "${ex.term}" is STALE — that term is no longer diverging; delete the entry`);
        continue;
      }
      exemptTerms.add(t);
    }

    const counted = missing.filter(([, t]) => !exemptTerms.has(t));
    const baseline = Number.isInteger(entry.baseline) ? entry.baseline : 0;
    results.push({ slug, source: entry.source, terms: terms.length, missing, counted, baseline, problems });
  }
  return { manifest, results };
}

function render({ results }, { report }) {
  let fail = false;
  let totalCounted = 0;
  let driftingPapers = 0;
  const lines = [];

  for (const r of results) {
    if (r.counted.length) { driftingPapers++; totalCounted += r.counted.length; }
    const over = r.counted.length > r.baseline;
    if (r.problems.length || over) fail = true;
    // In gate mode print the papers that FAILED, in full and by name. Printing
    // all 426 baselined terms on a pass would bury the three that are new — the
    // reason nobody reads an advisory gate twice. --report is the door to the
    // whole ledger and it is one flag away.
    if (report || over || r.problems.length) {
      if (r.counted.length || r.problems.length) {
        lines.push('');
        lines.push(`${r.slug}  (${r.source})  ${r.counted.length} diverging term(s), baseline ${r.baseline}`);
        for (const [kind, t] of r.counted) lines.push(`    ${kind}: ${t}`);
        for (const p of r.problems) lines.push(`    EXEMPTION PROBLEM: ${p}`);
      }
      if (over) lines.push(`    ^^ OVER BASELINE: ${r.counted.length} > ${r.baseline} for ${r.slug}`);
    }
    if (r.counted.length < r.baseline) {
      // A shrink never reds — same rule the neighbouring silencer growth
      // ratchet follows. It is still said out loud, because an unpinned
      // improvement is how a ratchet quietly loses its teeth.
      lines.push(`note: ${r.slug} improved (${r.counted.length} < baseline ${r.baseline}) — re-pin the baseline to keep the ratchet tight`);
    }
  }

  console.log(`repo-papers freshness: ${results.length} snapshot(s) checked, ${driftingPapers} diverging, ${totalCounted} term(s) total`);
  for (const l of lines) console.log(l);

  if (report) {
    console.log('\n--report: exit 0 regardless of verdict');
    return 0;
  }
  if (!fail && totalCounted) {
    console.log(`(${totalCounted} term(s) sit AT their recorded baseline — none of them new. \`node ${path.posix.join('scripts', 'repo-papers-freshness.mjs')} --report\` names every one.)`);
  }
  if (fail) {
    console.log('\nFAILED — a snapshot diverged past its recorded baseline, or an exemption is unjustified/stale.');
    console.log('Fix the SNAPSHOT (or the doc) so the terms above agree. If a divergence is deliberate, add it to');
    console.log(`${MANIFEST_REL} under that paper's "exempt" with a written reason. Baselines are edited by hand`);
    console.log('on purpose: there is no regenerate flag, because a one-command re-pin is how a finding gets buried.');
    return 1;
  }
  console.log('OK — every snapshot is within its recorded baseline.');
  return 0;
}

// ---------------------------------------------------------------------------
// --selftest: every arm plants ONE condition in a throwaway tree and re-invokes
// THIS file against it, so the assertions drive the shipping code path and not a
// copy of it. It writes nothing into this repo.
// ---------------------------------------------------------------------------

function runAgainst(root, args = []) {
  const res = spawnSync(process.execPath, [SELF, ...args], {
    env: { ...process.env, REPO_PAPERS_ROOT: root },
    encoding: 'utf8',
  });
  return { code: res.status, out: `${res.stdout || ''}${res.stderr || ''}` };
}

function fixture(papers, docs, manifest) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'repo-papers-selftest-'));
  fs.mkdirSync(path.join(dir, 'scripts'), { recursive: true });
  fs.mkdirSync(path.join(dir, '.demo-content/repo-papers'), { recursive: true });
  fs.mkdirSync(path.join(dir, 'docs'), { recursive: true });
  for (const [name, body] of Object.entries(papers)) {
    fs.writeFileSync(path.join(dir, '.demo-content/repo-papers', `${name}.json`), JSON.stringify(body));
  }
  for (const [name, body] of Object.entries(docs)) fs.writeFileSync(path.join(dir, 'docs', name), body);
  fs.writeFileSync(path.join(dir, MANIFEST_REL), JSON.stringify(manifest, null, 2));
  return dir;
}

const GREEN_PAPER = {
  slug: 'demo', title: 'Demo',
  blocks: [
    { id: 'b1', type: 'heading', level: 2, text: 'Step 6 — force_ssl stays OFF' },
    { id: 'b2', type: 'paragraph', content: [{ type: 'text', value: 'run ' }, { type: 'text', value: 'systemctl restart barkpark.service', marks: ['code'] }] },
    { id: 'b3', type: 'code', value: 'curl -s http://localhost:4000/api/schemas' },
  ],
};
const GREEN_DOC = [
  '## Step 6 — `force_ssl` stays OFF',
  '',
  'Run `systemctl restart barkpark.service` after compiling.',
  '',
  '```bash',
  'curl -s http://localhost:4000/api/schemas',
  '```',
  '',
].join('\n');
const GREEN_MANIFEST = {
  snapshot_dir: '.demo-content/repo-papers',
  papers: { demo: { source: 'docs/demo.md', baseline: 0 } },
};

function clone(o) { return JSON.parse(JSON.stringify(o)); }

function selftest() {
  const arms = [];
  const check = (name, cond, detail) => { arms.push({ name, ok: !!cond, detail }); };

  // (a) the green baseline — proves a pass is reachable at all.
  {
    const d = fixture({ demo: GREEN_PAPER }, { 'demo.md': GREEN_DOC }, GREEN_MANIFEST);
    const r = runAgainst(d);
    check('a: clean pair exits 0', r.code === 0 && /OK — every snapshot/.test(r.out), `code=${r.code}`);
    // non-vacuity floor for THIS arm: the pass must have measured something.
    check('a2: the clean pass measured terms', /1 snapshot\(s\) checked/.test(r.out), r.out.split('\n')[0]);
  }

  // (b) snapshot drifts (the incident shape: the snapshot keeps a wording the doc dropped).
  {
    const p = clone(GREEN_PAPER);
    p.blocks[0].text = 'Step 6 — Re-enable force_ssl';
    const d = fixture({ demo: p }, { 'demo.md': GREEN_DOC }, GREEN_MANIFEST);
    const r = runAgainst(d);
    check('b: drifted snapshot exits 1', r.code === 1, `code=${r.code}`);
    check('b2: it names the file', /^demo {2}\(docs\/demo\.md\)/m.test(r.out), 'no per-file line');
    check('b3: it names the term', /Re-enable force_ssl/.test(r.out), 'term not printed');
  }

  // (c) the doc moves and the snapshot is left behind.
  {
    const doc = GREEN_DOC.replace('systemctl restart barkpark.service', 'systemctl reload barkpark.service');
    const d = fixture({ demo: GREEN_PAPER }, { 'demo.md': doc }, GREEN_MANIFEST);
    const r = runAgainst(d);
    check('c: doc-side change exits 1', r.code === 1, `code=${r.code}`);
    check('c2: it names the stale term', /systemctl restart barkpark\.service/.test(r.out), 'term not printed');
  }

  // (d) a justified exemption absorbs a deliberate divergence.
  {
    const p = clone(GREEN_PAPER);
    p.blocks[0].text = 'Step 6 — force_ssl stays OFF (demo-only phrasing)';
    const m = clone(GREEN_MANIFEST);
    m.papers.demo.exempt = [{
      term: 'Step 6 - force_ssl stays OFF (demo-only phrasing)',
      reason: 'the demo corpus deliberately labels this heading for the seeded tour and the doc must not carry it',
    }];
    const d = fixture({ demo: p }, { 'demo.md': GREEN_DOC }, m);
    const r = runAgainst(d);
    check('d: justified exemption exits 0', r.code === 0, `code=${r.code}\n${r.out}`);
  }

  // (e) an exemption nobody justified FAILS CLOSED — it does not silently absorb.
  {
    const p = clone(GREEN_PAPER);
    p.blocks[0].text = 'Step 6 — Re-enable force_ssl';
    const m = clone(GREEN_MANIFEST);
    m.papers.demo.exempt = [{ term: 'Step 6 - Re-enable force_ssl', reason: 'legacy' }];
    const d = fixture({ demo: p }, { 'demo.md': GREEN_DOC }, m);
    const r = runAgainst(d);
    check('e: unjustified exemption exits 1', r.code === 1, `code=${r.code}`);
    check('e2: it says why', /carries no justification/.test(r.out), 'reason not explained');
  }

  // (f) a stale exemption is a finding, not a free pass.
  {
    const m = clone(GREEN_MANIFEST);
    m.papers.demo.exempt = [{
      term: 'systemctl restart barkpark.service',
      reason: 'this used to diverge before the doc was corrected and the entry was never removed',
    }];
    const d = fixture({ demo: GREEN_PAPER }, { 'demo.md': GREEN_DOC }, m);
    const r = runAgainst(d);
    check('f: stale exemption exits 1', r.code === 1, `code=${r.code}`);
    check('f2: it says STALE', /is STALE/.test(r.out), 'not labelled stale');
  }

  // (g) a snapshot nobody mapped is a REFUSAL, never a pass.
  {
    const d = fixture({ demo: GREEN_PAPER, stranger: GREEN_PAPER }, { 'demo.md': GREEN_DOC }, GREEN_MANIFEST);
    const r = runAgainst(d);
    check('g: unmapped snapshot exits 2', r.code === 2, `code=${r.code}`);
    check('g2: it names the stranger', /stranger/.test(r.out), 'not named');
  }

  // (h) a manifest row pointing at a source that does not exist is a REFUSAL.
  {
    const m = clone(GREEN_MANIFEST);
    m.papers.demo.source = 'docs/gone.md';
    const d = fixture({ demo: GREEN_PAPER }, { 'demo.md': GREEN_DOC }, m);
    const r = runAgainst(d);
    check('h: missing source exits 2', r.code === 2, `code=${r.code}`);
  }

  // (i) the extractor going blind is a REFUSAL — the "green with no subject" arm.
  //     The blocks here are a STRING holding the same JSON the walker expects,
  //     so the file plainly carries heading nodes and the walker reaches none.
  {
    const d = fixture({ demo: { slug: 'demo', title: 'Demo', blocks: JSON.stringify(GREEN_PAPER.blocks) } },
      { 'demo.md': GREEN_DOC }, GREEN_MANIFEST);
    const r = runAgainst(d);
    check('i: blind extractor exits 2', r.code === 2, `code=${r.code}`);
    check('i2: it says the extractor cannot read it', /ZERO comparable terms/.test(r.out), 'not explained');
  }

  // (i3) THE CONTROL for arm (i): a genuinely term-free stub — one ingress
  //      block, no headings and no code, which the real corpus contains — must
  //      PASS, not refuse. Without this arm the floor above would be indistinguishable
  //      from "every snapshot must be big".
  {
    const stub = { slug: 'demo', title: 'Demo', blocks: [{ id: 'b1', type: 'ingress', content: [{ type: 'text', value: 'Moved. See the canonical record.' }] }] };
    const d = fixture({ demo: stub }, { 'demo.md': GREEN_DOC }, GREEN_MANIFEST);
    const r = runAgainst(d);
    check('i3: a term-free stub passes (exit 0)', r.code === 0, `code=${r.code}\n${r.out}`);
  }

  // (j) THE RATCHET, in both directions: a baseline absorbs known debt, and one
  //     more term than the baseline reds.
  {
    const p = clone(GREEN_PAPER);
    p.blocks[0].text = 'Step 6 — Re-enable force_ssl';
    const m = clone(GREEN_MANIFEST);
    m.papers.demo.baseline = 1;
    const d1 = fixture({ demo: p }, { 'demo.md': GREEN_DOC }, m);
    const r1 = runAgainst(d1);
    check('j: baseline 1 absorbs 1 drift (exit 0)', r1.code === 0, `code=${r1.code}\n${r1.out}`);

    const p2 = clone(p);
    p2.blocks[2].value = 'curl -s http://localhost:4000/api/GONE';
    const d2 = fixture({ demo: p2 }, { 'demo.md': GREEN_DOC }, m);
    const r2 = runAgainst(d2);
    check('j2: one more than baseline exits 1', r2.code === 1, `code=${r2.code}`);
    check('j3: it prints the over-baseline line', /OVER BASELINE: 2 > 1/.test(r2.out), 'ratchet line missing');
  }

  // (k) --report never reds, so a reader can list every divergence without a
  //     failing shell.
  {
    const p = clone(GREEN_PAPER);
    p.blocks[0].text = 'Step 6 — Re-enable force_ssl';
    const d = fixture({ demo: p }, { 'demo.md': GREEN_DOC }, GREEN_MANIFEST);
    const r = runAgainst(d, ['--report']);
    check('k: --report exits 0 and still names the drift', r.code === 0 && /Re-enable force_ssl/.test(r.out), `code=${r.code}`);
  }

  let bad = 0;
  for (const a of arms) {
    console.log(`${a.ok ? 'ok  ' : 'FAIL'}  ${a.name}${a.ok ? '' : `  <- ${a.detail}`}`);
    if (!a.ok) bad++;
  }
  console.log(`\nselftest: ${arms.length - bad}/${arms.length} arms passed`);
  return bad === 0 ? 0 : 1;
}

// ---------------------------------------------------------------------------

function main() {
  const argv = process.argv.slice(2);
  if (argv.includes('--selftest')) return selftest();
  try {
    return render(analyse(ROOT), { report: argv.includes('--report') });
  } catch (e) {
    if (e instanceof Refuse) {
      console.log(`REFUSE — repo-papers freshness cannot measure this tree: ${e.message}`);
      console.log('This is not a clean result. Fix the mapping and re-run.');
      return 2;
    }
    throw e;
  }
}

process.exit(main());
