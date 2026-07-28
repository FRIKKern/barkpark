#!/usr/bin/env node
// SEAL PREDICATE — Cloud GUI Remake phase 5.  FROZEN AT DECIDE, round 8.
//
//   exit 0 = SEAL.   exit 1 = NO SEAL.   exit 2 = INFRA FAULT.
//
// Three exit codes, not two. The two-code shape shipped at round 8 let exit 1 mean
// BOTH "no seal" and "a non-JSON HTTP response threw at the curl site", which is a
// red nobody can read; `tooling/grip/seal.mjs` names this file by name as that prior
// art and ports the triad plus a machine-readable `VERDICT-TOKEN:` line. Ported back
// here at wave 6, unchanged in spirit: infra gets its own code and its own token.
//
// Five rounds of this epic ended in a PROSE verdict whose bar moved with the reader.
// This file is that verdict made mechanical. It is frozen BEFORE any builder flies,
// so its bar cannot be re-derived after seeing a result. A rule re-derived after
// seeing a failure is not a rule.
//
//   Clause (a)  zero children open/in_progress without either an evidence-closure
//               or a named forwarding address under the successor.
//   Clause (b)  zero known user-facing defect — each tied to a landed commit AND
//               re-measured live at origin/main.
//   Bucket (c)  PERMANENT HUMAN GATE — rows no commit can ever close. Disclosed by
//               hardcoded id, never discovered, and tripwired on disappearance.
//
// ---------------------------------------------------------------------------
// WHY CLAUSE (b) SHELLS OUT TO A BROWSER GUARD INSTEAD OF GREPPING SOURCE
//
// The first draft of this file asserted GR108 as "does a .topbar rule exist inside
// the @media (max-width: 768px) block". That encodes the charter's THEORY of the
// cause (a breakpoint gap). The theory is wrong. Measured at Decide:
//
//   .topbar's right edge is 753 — INSIDE the client area. It does not overflow.
//   Its CHILDREN escape to 775-780 because they are flex items with the default
//   min-width:auto, so they refuse to shrink below min-content. And the broken band
//   reaches ~782, ABOVE the 768 breakpoint, so no max-width:768px rule can close it.
//
// Dry-run of that first draft, both directions:
//   CORRECT fix (unconditional min-width:0 — measured 0/44 overflow)  -> said DEFECT
//   BROKEN  fix (tighten .topbar in the 768 block — measured 14/16 STILL overflowing) -> said CLEAN
//
// It was exactly inverted: it would have rejected the fix that works and blessed the
// fix that does not. The same draft's GR109 assertion also reported DEFECT against the
// recommended specificity repair, because the later base rule legitimately still reads
// align-items:center after a correct fix.
//
// That is this epic's signature sin — a gate that cannot parse the artifact it
// certifies — reproduced inside the instrument built to end it. A source regex tests a
// story about the pixels. Only a browser tests the pixels. So clause (b) delegates to a
// committed guard that RENDERS and MEASURES, and this file asserts only that the guard
// exists, runs, and passes. If the guard is missing, that is NO SEAL, not a pass —
// an unmeasured defect is never a cleared defect.
//
// ---------------------------------------------------------------------------
// WHY THREE REFUSALS FIRE BEFORE ANY CLAUSE IS EVALUATED
//
// Round 8 shipped this file able to print `VERDICT: SEAL` over the sentence
// "0 forwarded by name / to null". Measured, not read: with ZERO live rows the
// `forwarded` set is never consulted, so a missing successor cost nothing and the
// run exited 0 — the defect fired exactly at the moment of success, which is the
// only run anybody ever quotes. A fixture omitting the key rendered "to undefined";
// `--successor task-DOES-NOT-EXIST-9999` was accepted verbatim and PRINTED as the
// forwarding address; and a register with `KNOWN_DEFECTS = []` sealed at exit 0
// having spawned no guard at all, its honest "KNOWN over 0" disclosure sitting under
// an unqualified SEAL. A predicate that prints an honest sentence and still exits 0
// is the same defect as one that lies, so these are REFUSALS, not prose:
//
//   R0  --guard-cmd given without --ledger      — clause (b) would certify a stub
//   R1  the defect register is empty            — clause (b) would certify nothing
//   R2  no successor is named                   — clause (a) has no forwarding address
//   R3  the named successor does not resolve to a published task
//
// They run BEFORE the roster is read, so a bogus id can never reach the output as a
// forwarding address; a refusal names it only as the id that was REJECTED.
//
// NOT fixed here (charter D83, next wave's `cch-bl-seal-predicate-retarget-and-reparent`):
// naming a successor does not by itself clear clause (a), because forwarding is
// MEMBERSHIP IN THE SUCCESSOR'S OWN ROSTER via fetchRoster(SUCCESSOR) — the residue
// must actually be re-parented, and the EPIC constant still points at the predecessor.
//
// ---------------------------------------------------------------------------
//   --ledger <file>    inject a ledger fixture instead of live HTTP (mutation proofs only)
//   --successor <id>   the successor epic's task id, for clause (a) forwarding
//   --repo <path>      repo root
//   --guard-cmd <cmd>  override the guard command (mutation proofs only — REFUSED
//                      unless --ledger is also given; see R0)

import { execFileSync, spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';

const argv = process.argv.slice(2);
const arg = (n) => { const i = argv.indexOf(n); return i === -1 ? null : argv[i + 1]; };

const EPIC = 'task-47bc4168392dec17';
const SERVER = process.env.BP_SERVER || 'https://guerrilla.barkpark.cloud';
const TOKEN = process.env.BP_TOKEN;
const REPO = arg('--repo') || process.cwd();

// ---------------------------------------------------------------------------
// FROZEN INPUT 1 — PERMANENT HUMAN GATES.
// Rows no commit can ever close. Each MUST be listed by explicit doc_id.
// cloud-console-billing-live-gate's parent is `cloud-console-goal`, NOT this epic,
// so NO epic-scoped filter[parent_id] query can ever reach it — proven at Decide
// (roster of 133 returns it: false; filter[_id] lookup resolves it: true).
// It is hardcoded here by name, which is the entire point of the bucket.
const PERMANENT_HUMAN_GATES = {
  'cloud-console-billing-live-gate':
    'Live Stripe keys + pricing/legal decisions. Parent is cloud-console-goal (OUTSIDE this epic) — unreachable by any roster query, carried only by hardcoded id.',
  'gr-ops-platform-admin-emails':
    'PLATFORM_ADMIN_EMAILS append on prod .env + redeploy. A human shell act; no commit can set an unset prod env var. The operator console — this epic\'s crown — is DARK until this fires.',
  'gr-backlog-qr-live-scan-proof':
    'Scanning the shipped 2FA QR with real authenticator apps. Requires a human with a phone.',
};

// FROZEN INPUT 2 — KNOWN USER-FACING DEFECTS.
// Each needs a landed commit AND a live re-measurement. `guard` is a repo-relative
// executable that must exist and exit 0. A commit id alone is a commit-message green.
const KNOWN_DEFECTS = [
  {
    id: 'GR108-tablet-topbar-overflow',
    desc: 'Horizontal scrollbar at 721-782px on the two past-due screens; .topbar-right children will not shrink (min-width:auto)',
    commit: '0261ace15',                                     // landed: .topbar-right > * { min-width: 0 } (app.css:787)
    guard: 'cloud/priv/static/__preview__/overflow-guard.mjs',
  },
  {
    id: 'GR109-attention-row-dead-rule',
    desc: '.attention-row stacks but stays centred — the authored align-items:flex-start is killed by a later base rule at equal specificity',
    commit: '0261ace15',                                     // landed: tablet-stack block moved after its base rule (app.css:2704-2713)
    guard: 'cloud/priv/static/__preview__/overflow-guard.mjs',
  },
  {
    id: 'GR115-bpconsole-dead-rule',
    desc: '.bp-console-body/.bp-console-toggle never take the authored 40vh cap or the 13px legibility floor at <=720px — same cascade-order death as GR109',
    commit: '0261ace15',                                     // landed: base block moved before the shared 720px media block (app.css:2420-2477)
    guard: 'cloud/priv/static/__preview__/overflow-guard.mjs',
  },
];

// FROZEN INPUT 3 — THE SWEEP ENVELOPE the green statement is allowed to claim.
// Measured at Decide, not estimated. A green may never imply more than this box.
const SWEEP = {
  scenariosSwept: 86, scenariosTotal: 86, themes: 2, width: 768,
  accentScenarios: 12, accents: 5,
  notSwept: '74 of 86 scenarios under the four non-default accents; widths other than 768 outside the 721-1440 band measured on the two past-due screens only',
};

// ---------------------------------------------------------------------------
// EXIT TRIAD, ported from tooling/grip/seal.mjs (read, never modified — that file
// is out of fence). `Infra` is never a verdict: nothing was measured, so nothing is
// claimed. `Refusal` IS a verdict — NO SEAL — reached before any clause ran.
class Infra extends Error {}
class Refusal extends Error {
  constructor(code, message) { super(message); this.code = code; }
}

function q(params) {
  const a = ['-sG', `${SERVER}/v1/data/query/production/task`];
  for (const [k, v] of params) a.push('--data-urlencode', `${k}=${v}`);
  a.push('-H', `Authorization: Bearer ${TOKEN}`);
  let body;
  try { body = execFileSync('curl', a, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 }); }
  catch (e) { throw new Infra(`curl failed: ${String(e.message).slice(0, 90)}`); }
  try { return JSON.parse(body); }
  catch { throw new Infra(`response is not JSON (${body.slice(0, 60).replace(/\s+/g, ' ')})`); }
}
// NEVER bare ?parent_id= — proven at Decide to silently return 500 unfiltered rows.
const fetchRoster = (parentId) => q([['filter[parent_id]', parentId], ['limit', '500']]).result.documents;
const fetchById = (id) => q([['filter[_id]', id]]).result.documents[0] || null;

// A task id is RESOLVED only by a document that exists, is a task, and is PUBLISHED.
// Unpublished is unresolved: boards and gates read the published ledger only, so an
// unpublished successor is a forwarding address no reader can follow.
function resolveTask(id, fixture) {
  const doc = fixture
    ? ((fixture.tasks || {})[id] || (fixture.gates || {})[id] || null)
    : fetchById(id);
  if (!doc) return { ok: false, why: 'no published task with that id' };
  if (doc._type && doc._type !== 'task') return { ok: false, why: `id resolves to _type=${doc._type}, not a task` };
  if (doc.status && doc.status !== 'published') return { ok: false, why: `task exists but status=${doc.status}` };
  return { ok: true, doc };
}

// ---------------------------------------------------------------------------
function main() {
  const L = [];
  const STAMP = new Date().toISOString();
  const ledgerPath = arg('--ledger');
  const guardOverride = arg('--guard-cmd');

  let fixture = null;
  if (ledgerPath) {
    try { fixture = JSON.parse(readFileSync(ledgerPath, 'utf8')); }
    catch (e) { throw new Infra(`--ledger ${ledgerPath}: ${String(e.message).slice(0, 90)}`); }
  }

  L.push('=== SEAL PREDICATE — Cloud GUI Remake phase 5 ===');
  L.push(`read at ${STAMP}${fixture ? '  (LEDGER FIXTURE — not live)' : '  (live ledger)'}`);

  // ── REFUSALS. Evaluated BEFORE the roster is read, so nothing downstream can
  // print an unresolvable id as a forwarding address. ────────────────────────
  if (!Array.isArray(KNOWN_DEFECTS) || KNOWN_DEFECTS.length === 0)
    throw new Refusal('EMPTY-DEFECT-REGISTER',
      'KNOWN_DEFECTS is empty — clause (b) would certify the word KNOWN over zero defects and spawn no guard at all. An unrun clause is not a passed clause.');

  // R0 — `--guard-cmd` is a FIXTURE-ONLY affordance. It is applied verbatim once
  // per registered defect and never receives the defect id, so a single
  // `--guard-cmd true` marks every entry in clause (b) measured-clean: the exact
  // vacuous green clause (b) exists to prevent, reachable from the command line.
  // Binding it to `--ledger` costs nothing (every mutation proof already injects
  // a fixture) and makes the live run — the only run whose green anybody quotes —
  // structurally incapable of substituting a stub for the browser guard.
  if (guardOverride !== null && !ledgerPath)
    throw new Refusal('GUARD-OVERRIDE-WITHOUT-FIXTURE',
      '--guard-cmd was given without --ledger. The override is applied once per registered defect and carries no defect id, so on a LIVE run it would certify clause (b) over a stub instead of the browser guard. Mutation proofs inject a ledger fixture; live runs use the committed guard.');

  const SUCCESSOR = arg('--successor') || (fixture ? fixture.successor : null) || null;
  if (typeof SUCCESSOR !== 'string' || SUCCESSOR.trim() === '')
    throw new Refusal('NO-SUCCESSOR',
      'no successor named (--successor, or `successor` in the ledger fixture). Clause (a) certifies that residue has a forwarding address; with none there is nothing to forward TO, and with zero live rows the absence would otherwise cost nothing and seal.');

  const resolution = resolveTask(SUCCESSOR, fixture);
  if (!resolution.ok)
    throw new Refusal('UNRESOLVABLE-SUCCESSOR',
      `the id offered as successor does not resolve to a published task (${resolution.why}). Rejected id: ${SUCCESSOR}. It is NOT printed as a forwarding address, because it is not one.`);

  // ── from here the successor is real, and may be named in the output ─────────
  const children = fixture ? fixture.children : fetchRoster(EPIC);
  if (!Array.isArray(children)) throw new Infra('roster is not an array of documents');

  // The successor's own roster is the ONLY thing that makes a forwarding address "named".
  const forwarded = fixture
    ? new Set(fixture.forwarded || [])
    : new Set(fetchRoster(SUCCESSOR).map((c) => c._id));

  const byStatus = {};
  for (const c of children) byStatus[c.lifecycle_status] = (byStatus[c.lifecycle_status] || 0) + 1;
  const live = children.filter((c) => c.lifecycle_status === 'open' || c.lifecycle_status === 'in_progress');

  const orphans = [], gatedLive = [], fwd = [];
  for (const c of live) {
    if (PERMANENT_HUMAN_GATES[c._id]) gatedLive.push(c._id);
    else if (forwarded.has(c._id)) fwd.push(c._id);
    else orphans.push(c._id);
  }

  // Bucket (c): every hardcoded gate must resolve. A gate that silently vanished is a
  // gate that stopped being disclosed — that is NO SEAL, not a clean sheet.
  const gateReport = Object.entries(PERMANENT_HUMAN_GATES).map(([id, why]) => {
    const doc = fixture ? (fixture.gates || {})[id] : fetchById(id);
    return { id, why, inRoster: children.some((c) => c._id === id), resolved: !!doc,
             status: doc ? doc.lifecycle_status : null, parent: doc ? doc.parent_id : null };
  });

  // Clause (b): landed commit AND a live measurement by a committed guard.
  const defectFails = [];
  for (const d of KNOWN_DEFECTS) {
    const commit = (fixture && fixture.defectCommits && fixture.defectCommits[d.id] !== undefined)
      ? fixture.defectCommits[d.id] : d.commit;
    const problems = [];

    if (!commit) problems.push('NO COMMIT — defect is known and unlanded');
    else if (fixture) { if (!(fixture.landed || []).includes(commit)) problems.push(`commit ${commit} is not an ancestor of origin/main`); }
    else {
      try { execFileSync('git', ['-C', REPO, 'merge-base', '--is-ancestor', commit, 'origin/main'], { stdio: 'ignore' }); }
      catch { problems.push(`commit ${commit} is not an ancestor of origin/main`); }
    }

    // The measurement. Absent guard fails CLOSED: unmeasured is never cleared. And a
    // guard that NEVER RAN (spawn error, timeout, signal — status null, not non-zero)
    // is named separately from one that ran and failed, because "did not run" read as
    // "passed" is exactly how an empty clause looks green.
    let ranClean = false;
    const guardPath = `${REPO}/${d.guard}`;
    if (guardOverride) {
      const r = spawnSync('sh', ['-c', guardOverride], { encoding: 'utf8' });
      if (r.error || r.status === null) problems.push(`guard override NEVER RAN (${r.error ? r.error.code || r.error.message : `signal ${r.signal || '?'}`})`);
      else if (r.status !== 0) problems.push(`guard exited ${r.status} — the defect is still measurable at origin/main`);
      else ranClean = true;
    } else if (!existsSync(guardPath)) {
      problems.push(`guard ${d.guard} is NOT COMMITTED — the fix is unmeasured, and unmeasured is not cleared`);
    } else {
      const r = spawnSync('node', [guardPath, '--defect', d.id], { encoding: 'utf8', timeout: 300000 });
      if (r.error || r.status === null) problems.push(`guard ${d.guard} NEVER RAN (${r.error ? r.error.code || r.error.message : `timeout or signal ${r.signal || '?'}`})`);
      else if (r.status !== 0) problems.push(`guard exited ${r.status} — the defect is still measurable at origin/main`);
      else ranClean = true;
    }
    // The explicit assertion: every registered entry must have had a guard RUN clean.
    if (!ranClean && problems.length === 0)
      problems.push('no guard ran for this entry — an unrun clause is not a passed clause');
    if (problems.length) defectFails.push({ id: d.id, problems, ranClean });
  }

  // ── output ─────────────────────────────────────────────────────────────────
  L.push(`epic ${EPIC}   successor: ${SUCCESSOR}`);
  L.push(`roster: ${children.length} children  ${JSON.stringify(byStatus)}`);
  L.push('');
  L.push(`CLAUSE (a) forwarding — live rows ${live.length}`);
  L.push(`  forwarded under successor : ${fwd.length}`);
  L.push(`  permanent human gate      : ${gatedLive.length}  [${gatedLive.join(', ') || '-'}]`);
  L.push(`  UNNAMED RESIDUE (orphans) : ${orphans.length}`);
  orphans.slice(0, 8).forEach((o) => L.push(`      ✗ ${o}`));
  if (orphans.length > 8) L.push(`      … and ${orphans.length - 8} more`);
  L.push('');
  L.push('BUCKET (c) permanent human gates');
  for (const g of gateReport)
    L.push(`  ${g.resolved ? '✓' : '✗'} ${g.id}  status=${g.status} parent=${g.parent} in-epic-roster=${g.inRoster}`);
  L.push('');
  L.push(`CLAUSE (b) known user-facing defects — ${KNOWN_DEFECTS.length} registered`);
  for (const d of KNOWN_DEFECTS) {
    const f = defectFails.find((x) => x.id === d.id);
    L.push(`  ${f ? '✗' : '✓'} ${d.id}`);
    if (f) f.problems.forEach((p) => L.push(`        ${p}`));
  }
  L.push('');

  const gateMissing = gateReport.filter((g) => !g.resolved);
  const ok = orphans.length === 0 && defectFails.length === 0 && gateMissing.length === 0;

  if (ok) {
    L.push('VERDICT: SEAL');
    L.push('');
    L.push(`SCOPE — what this green does and does NOT claim, read at ${STAMP}:`);
    L.push(`  Sealed ${children.length} children: ${byStatus.done || 0} evidence-closed, ${fwd.length} forwarded by name`);
    L.push(`  to ${SUCCESSOR}, and ${Object.keys(PERMANENT_HUMAN_GATES).length} permanent human gate(s) disclosed by hardcoded name.`);
    L.push('  Zero unnamed residue. Zero known user-facing defect, each re-measured in a browser.');
    L.push('');
    L.push('  NOT asserted by this green:');
    L.push('   1. Defect coverage is bounded by what was REGISTERED. Clause (b) certifies the word');
    L.push(`      KNOWN over ${KNOWN_DEFECTS.length} hand-registered defects. A defect nobody looked for is invisible to it.`);
    L.push(`   2. The overflow sweep covered ${SWEEP.scenariosSwept}/${SWEEP.scenariosTotal} scenarios x ${SWEEP.themes} themes at ${SWEEP.width}px (default accent),`);
    L.push(`      plus ${SWEEP.accentScenarios}/${SWEEP.scenariosTotal} scenarios x ${SWEEP.accents} accents. NOT swept: ${SWEEP.notSwept}.`);
    L.push('   3. 21 clean-CAS children are sealed on evidence nobody read. 0 of 39 checked failed,');
    L.push('      which bounds the true material-failure rate at ~8% upper 95% — so up to ~2 of the 21');
    L.push('      may carry one. They are enumerated BY NAME in the charter, not described as a subtraction.');
    L.push('   4. The crown is DARK. The operator console shipped fully built and unreachable;');
    L.push('      gr-ops-platform-admin-emails is a human act. "Seal" here means CODE seal, never');
    L.push('      "this feature is live for any human".');
  } else {
    L.push('VERDICT: NO SEAL');
    if (orphans.length) L.push(`  - ${orphans.length} live row(s) carry no forwarding address and no gate label (clause a)`);
    if (defectFails.length) L.push(`  - ${defectFails.length} known user-facing defect(s) unlanded or still measurable (clause b)`);
    if (gateMissing.length) L.push(`  - ${gateMissing.length} hardcoded human gate(s) failed to resolve (bucket c)`);
    L.push('  This is an acceptable, pre-committed outcome. The named successor is the honest handoff.');
  }
  L.push(`VERDICT-TOKEN: SEAL-PREDICATE ${ok ? 'SEAL' : 'NO-SEAL'} a=${orphans.length === 0 ? 'PASS' : 'FAIL'} b=${defectFails.length === 0 ? 'PASS' : 'FAIL'} c=${gateMissing.length === 0 ? 'PASS' : 'FAIL'} orphans=${orphans.length} successor=${SUCCESSOR}`);
  console.log(L.join('\n'));
  return ok ? 0 : 1;
}

let code = 2;
try {
  code = main();
} catch (e) {
  const stamp = new Date().toISOString();
  console.log('=== SEAL PREDICATE — Cloud GUI Remake phase 5 ===');
  if (e instanceof Refusal) {
    // A refusal IS a verdict — NO SEAL — but reached before any clause ran, so no
    // clause may be reported PASS. The predicate refuses to evaluate; it never seals.
    console.log(`REFUSED at ${stamp}, before any clause was evaluated: ${e.message}`);
    console.log('VERDICT: NO SEAL — REFUSED');
    console.log('  Nothing was certified. This is a pre-committed outcome: a predicate that prints an');
    console.log('  honest sentence and still exits 0 is the same defect as one that lies.');
    console.log(`VERDICT-TOKEN: SEAL-PREDICATE REFUSED reason=${e.code} a=UNEVALUATED b=UNEVALUATED c=UNEVALUATED`);
    code = 1;
  } else {
    console.log(`INFRA FAULT at ${stamp}: ${e instanceof Infra ? e.message : `unexpected ${e.name}: ${e.message}`}`);
    console.log('  This is NOT a verdict. Nothing was measured, so nothing is claimed — the whole point');
    console.log('  of a third exit code is that this can never be read as NO SEAL.');
    console.log('VERDICT-TOKEN: SEAL-PREDICATE INFRA-FAULT a=UNKNOWN b=UNKNOWN c=UNKNOWN');
    code = 2;
  }
}
process.exit(code);
