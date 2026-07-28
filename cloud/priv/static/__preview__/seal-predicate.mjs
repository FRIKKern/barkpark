#!/usr/bin/env node
// SEAL PREDICATE — asks ONE question about ONE epic: may this epic be sealed?
// The epic is `--epic`, defaulting to the Cloud Console hardening epic. FROZEN AT
// DECIDE (wave 7, charter D88/D89/D90) — before any builder of this wave flew.
//
//   exit 0 = SEAL.   exit 1 = NO SEAL.   exit 2 = INFRA FAULT.
//
// Three exit codes, not two. The two-code shape let exit 1 mean BOTH "no seal" and
// "a non-JSON HTTP response threw at the curl site", which is a red nobody can read;
// `tooling/grip/seal.mjs` names this file as that prior art and ports the triad plus
// a machine-readable `VERDICT-TOKEN:` line.
//
// Five rounds of the PREDECESSOR epic ended in a PROSE verdict whose bar moved with
// the reader. This file is that verdict made mechanical. Its inputs are frozen BEFORE
// any builder flies, so its bar cannot be re-derived after seeing a result. A rule
// re-derived after seeing a failure is not a rule.
//
//   Clause (a)  zero children open/in_progress/CONSIDERING without either an
//               evidence-closure or a named forwarding address under the successor.
//   Clause (b)  zero known user-facing defect — each tied to a landed commit
//               (verified by ANCESTRY and by DIFF) AND actually measured.
//   Bucket (c)  PERMANENT HUMAN GATE — rows no commit can ever close. Disclosed by
//               hardcoded id, never discovered, and tripwired on disappearance.
//
// ---------------------------------------------------------------------------
// WHY A COMMIT IS VERIFIED BY ITS DIFF AND NEVER BY ITS SUBJECT LINE
//
// `481d6f231`'s subject is "clear the Overview snapshot on sign-out"; its squash body
// carries the request-coalescing fix that actually closes the refetch storm. A register
// that matched on `%s` would have rejected the commit that pays the defect. So the
// commit fetch here is `git show --format= <sha>` — the message is never even read into
// the process. What is asserted is (1) ancestry of origin/main and (2) that the DIFF
// touches the registered path and contains the registered marker.
//
// ---------------------------------------------------------------------------
// WHY CLAUSE (b) HAS THREE RUNGS AND WHY "NEITHER" IS A LOUD FAILURE
//
// `guard:` is contractually a repo-relative NODE executable, spawned as
// `node <guard> --defect <id>` with no cwd and a 300s timeout — so an ExUnit
// measurement CANNOT be expressed as a guard (a `#!/bin/sh` guard that `exit 0`s is
// reported by the spawn as "still measurable"). The ladder is therefore:
//
//   rung 1  guard:            a node executable that RUNS here, and whose stdout must
//                             NAME the measurement (`guardExpect`) — an exit 0 alone
//                             is an exit code, not a post-condition read.
//   rung 2  measured_by: +    an ExUnit file plus the CI workflow+job that runs it.
//           measured_in_ci:   PASSES, but is printed MEASURED-ELSEWHERE, never silently
//                             green: this run verified that the test file and the CI
//                             job EXIST, and says in the same breath that it did not
//                             execute them.
//   rung 3  NEITHER           FAILS clause (b), by name, with the gap stated.
//
// Register entry CCH-D5 (the rate limiter bucketing every user together) is rung 3
// today — `grep -rn peer_ip cloud/test` returns exactly one hit and it is a COMMENT.
// Clause (b) therefore FAILS. That is the true answer and it is not engineered around.
//
// ---------------------------------------------------------------------------
// WHY A GUARD'S EXIT 2 IS AN INFRA FAULT AND NOT A DEFECT CLAIM
//
// `overflow-guard.mjs` exits 2 for "unknown --defect" — a REFUSAL to measure — and the
// prior shape of this file laundered any non-zero into "the defect is still measurable
// at origin/main", i.e. it reported a defect it had never measured. This file now reads
// a guard's exit 2 as REFUSED → its own INFRA FAULT (exit 2), never a verdict.
// The GUARD-SIDE fix (overflow-guard.mjs's own exit vocabulary) is NOT duplicated here:
// it is owned by the open row `hg-overflow-guard-refusal-exits-1`, and that file is
// deliberately left untouched by this slice.
//
// ---------------------------------------------------------------------------
// WHY FOUR REFUSALS FIRE BEFORE ANY CLAUSE IS EVALUATED
//
//   R0  --guard-cmd given without --ledger      — clause (b) would certify a stub
//   R1  the defect register is empty            — clause (b) would certify nothing
//   R2  no successor is named                   — clause (a) has no forwarding address
//   R3  the named successor does not resolve to a published task
//   R4  the named successor IS the epic         — forwarding to yourself is not
//       forwarding: `forwarded = fetchRoster(SUCCESSOR)` becomes the epic's OWN roster,
//       which contains every live row by construction. Measured live before this was
//       added: 83 live rows -> `forwarded: 79`, `orphans: 0`, `a=PASS`. A one-flag path
//       to a false clause (a) is exactly the class this predicate exists to kill.
//
// And a FOURTH clause-(a) shape, TERMINAL, reached only AFTER the roster is read:
// `--successor TERMINAL` claims the epic has no residue to forward. It is accepted ONLY
// on a post-condition READ of the roster showing live==0 AND considering==0 — never on
// the flag alone. Without it, R2+R3 make "zero residue, terminal epic" unreachable and
// the epic is architecturally required to spawn a child forever.
//
// ---------------------------------------------------------------------------
//   --epic <id>        the epic under judgement (default: cloud-console-hardening-epic)
//   --ledger <file>    inject a ledger fixture instead of live HTTP (mutation proofs only)
//   --successor <id>   the successor epic's task id, or the literal TERMINAL
//   --repo <path>      repo root
//   --guard-cmd <cmd>  override the guard command (mutation proofs only — REFUSED
//                      unless --ledger is also given; see R0)

import { execFileSync, spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';

const argv = process.argv.slice(2);
const arg = (n) => { const i = argv.indexOf(n); return i === -1 ? null : argv[i + 1]; };

const EPIC = arg('--epic') || 'cloud-console-hardening-epic';
const TERMINAL = 'TERMINAL';
const SERVER = process.env.BP_SERVER || 'https://guerrilla.barkpark.cloud';
const TOKEN = process.env.BP_TOKEN;
const REPO = arg('--repo') || process.cwd();

// Statuses. `considering` is NOT live work, but it is NOT closed either — leaving it
// out of both buckets is how a roster with unfinished rows seals with them disclosed
// nowhere. It is counted as residue AND printed by name (charter D90).
const GUARD_ENV = { ...process.env };
for (const k of ['NODE_TEST_CONTEXT', 'NODE_OPTIONS', 'NODE_V8_COVERAGE']) delete GUARD_ENV[k];

const LIVE_STATUSES = ['open', 'in_progress'];
const PENDING_STATUSES = ['considering'];

// ---------------------------------------------------------------------------
// FROZEN INPUT 1 — PERMANENT HUMAN GATES (charter D89: THREE, not five).
// Rows no commit can ever close. Each MUST be listed by explicit doc_id.
// `cloud-console-billing-live-gate` is DROPPED: its parent `cloud-console-goal` is
// lifecycle=done, so it is an open row hanging under a closed goal — an address that
// exists but no longer accepts mail. A gate belonging to a different, closed goal can
// neither block nor unblock THIS epic's seal.
const PERMANENT_HUMAN_GATES = {
  'gr-ops-platform-admin-emails':
    'PLATFORM_ADMIN_EMAILS append on prod .env + redeploy. A human shell act; no commit can set an unset prod env var. The operator console — this epic\'s crown — is DARK until this fires.',
  'gr-backlog-qr-live-scan-proof':
    'Scanning the shipped 2FA QR with real authenticator apps. Requires a human with a phone.',
  'cch-hg-compose-network-recreation':
    'A compose network recreation on the live host — a human operator act on prod infrastructure, not a deploy step any commit performs.',
};

// FROZEN INPUT 2 — KNOWN USER-FACING DEFECTS (charter D88: SIX, drawn from the
// charter's own enumerated lies, frozen before any triage result was known).
// Each needs a landed commit — verified by ANCESTRY and by DIFF, never by subject —
// AND a measurement on one of the three rungs.
//   commit    the merge SHA
//   diff      { paths: [...], grep: /…/ } asserted against `git show --format=` output
//   guard     rung 1: repo-relative node executable, spawned with `--defect <id>`
//   guardExpect  the string that guard's own output must contain — an exit code alone
//                is never a post-condition read
//   measured_by / measured_in_ci   rung 2
//   unmeasured                     rung 3: the stated gap. FAILS clause (b).
const KNOWN_DEFECTS = [
  {
    id: 'CCH-D1-overview-refetch-storm',
    desc: 'One boot plus seven fleet ticks cost 40 HTTP requests; every live event refetched all five Overview reads',
    commit: '481d6f231',
    diff: { paths: ['cloud/priv/static/app.js'], grep: /OVERVIEW_FULL/ },
    guard: 'cloud/priv/static/__app.test.mjs',
    guardExpect: 'cch-w1: seven fleet ticks after one boot cost 12 requests, not 40',
  },
  {
    id: 'CCH-D2-session-peer-ip-is-the-docker-bridge',
    desc: 'Every session row reported the docker bridge gateway 172.18.0.1 as the client IP, so "signed in from" was fiction',
    commit: '8fd00b6afb1eca55d3c991f7921ed6ec2b7d77b4',
    diff: { paths: ['cloud/lib/barkpark_cloud/web/router.ex'], grep: /trusted_proxy_peers/ },
    measured_by: ['cloud/test/barkpark_cloud/web/router_test.exs'],
    measured_in_ci: { workflow: '.github/workflows/cloud.yml', job: 'test', paths: 'cloud/**' },
  },
  {
    id: 'CCH-D3-bearer-token-in-the-access-log',
    desc: 'The SSE stream carried the session bearer in the URL, so every access log and proxy trace along the path held a live credential',
    commit: 'd157d098c78bc6604d00d84e22d038bdb176ef58',
    diff: { paths: ['cloud/lib/barkpark_cloud/accounts.ex'], grep: /consume_sse_ticket/ },
    // D88 names `router_oauth_test.exs`; the SHA's OWN diff adds
    // `router_sse_ticket_test.exs`, which is the file that exercises the ticket path.
    // Both are registered rather than silently preferring one — and `linkedToCommit`
    // below requires at least one named file to appear in the commit's diff.
    measured_by: [
      'cloud/test/barkpark_cloud/web/router_sse_ticket_test.exs',
      'cloud/test/barkpark_cloud/web/router_oauth_test.exs',
    ],
    measured_in_ci: { workflow: '.github/workflows/cloud.yml', job: 'test', paths: 'cloud/**' },
  },
  {
    id: 'CCH-D4-head-prober-gets-a-session-token',
    desc: 'plug(Plug.Head) rewrote HEAD->GET router-wide, so any unfurler or prefetcher HEADing the OAuth callback was handed a live session token',
    commit: '26acc7a91be0f0352efdb3e89b2017accb786367',
    diff: { paths: ['cloud/lib/barkpark_cloud/web/router.ex'], grep: /side-effecting-GET fence/ },
    measured_by: [
      'cloud/test/barkpark_cloud/web/router_head_and_favicon_test.exs',
      'cloud/test/barkpark_cloud/web/router_oauth_test.exs',
    ],
    measured_in_ci: { workflow: '.github/workflows/cloud.yml', job: 'test', paths: 'cloud/**' },
  },
  {
    id: 'CCH-D5-rate-limiter-sees-every-user-as-one',
    desc: 'The sign-in rate bucket keyed on the proxy peer, so all users behind the front door shared one bucket — one attacker locks out everyone',
    // Same root fix as CCH-D2 (peer_ip/1 now resolves the real client IP), but NOTHING
    // measures the bucket separation: `grep -rn peer_ip cloud/test` returns exactly one
    // hit and it is a COMMENT (router_test.exs:2215). Rung 3.
    commit: '8fd00b6afb1eca55d3c991f7921ed6ec2b7d77b4',
    diff: { paths: ['cloud/lib/barkpark_cloud/web/router.ex'], grep: /trusted_proxy_peers/ },
    unmeasured:
      'no test anywhere asserts that two clients behind the front door get SEPARATE rate buckets. The root fix landed; the BEHAVIOUR is unmeasured, and unmeasured is not cleared. Filed as the measurement gap this clause names.',
  },
  {
    id: 'CCH-D6-css-check-passes-on-deleted-code',
    desc: 'The emit --write path could delete an attributed marker span and still exit 0 — a CSS check greening over code it had removed',
    commit: '58862f621',
    diff: { paths: ['design/emit-fence.test.mjs'], grep: /sentinel SURVIVES/ },
    guard: 'design/emit-fence.test.mjs',
    guardExpect: 'fence REFUSES an unattributed marker-span write',
  },
];

// ---------------------------------------------------------------------------
// EXIT TRIAD, ported from tooling/grip/seal.mjs (read, never modified — that file
// is out of fence). `Infra` is never a verdict: nothing was measured, so nothing is
// claimed. `Refusal` IS a verdict — NO SEAL — reached before any clause could pass.
class Infra extends Error {}
class Refusal extends Error {
  constructor(code, message, stage = 'before any clause was evaluated') {
    super(message);
    this.code = code;
    this.stage = stage;
  }
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
// COMMIT VERIFICATION. Ancestry AND diff. The commit MESSAGE is never fetched:
// `git show --format=` emits the patch alone, so matching on a subject line is not
// merely discouraged here, it is unreachable.
function gitDiffBody(sha) {
  return execFileSync('git', ['-C', REPO, 'show', '--format=', sha], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
}
function gitDiffPaths(sha) {
  return execFileSync('git', ['-C', REPO, 'show', '--name-only', '--format=', sha], { encoding: 'utf8' })
    .split('\n').map((l) => l.trim()).filter(Boolean);
}

function verifyCommit(d, commit, fixture, problems) {
  if (fixture) {
    // Fixture mode is a MUTATION CONTROL, never a live claim. `landed` stands in for
    // ancestry; `diffs[sha]` optionally stands in for the patch so the diff rule is
    // itself testable. Absent diffs, the check is SKIPPED and said to be skipped.
    if (!(fixture.landed || []).includes(commit)) {
      problems.push(`commit ${commit} is not an ancestor of origin/main`);
      return null;
    }
    const fx = (fixture.diffs || {})[commit];
    if (!fx) return 'fixture: diff verification not applicable (no `diffs` entry)';
    const missing = (d.diff.paths || []).filter((p) => !(fx.paths || []).includes(p));
    if (missing.length) problems.push(`commit ${commit} does not touch ${missing.join(', ')} — the registered fix is not in this diff`);
    if (!d.diff.grep.test(fx.body || '')) problems.push(`commit ${commit}'s diff never matches ${d.diff.grep} — verified by DIFF, never by subject line`);
    return 'fixture diff';
  }

  try { execFileSync('git', ['-C', REPO, 'merge-base', '--is-ancestor', commit, 'origin/main'], { stdio: 'ignore' }); }
  catch { problems.push(`commit ${commit} is not an ancestor of origin/main`); return null; }

  let paths, body;
  try { paths = gitDiffPaths(commit); body = gitDiffBody(commit); }
  catch (e) { throw new Infra(`git show ${commit} failed: ${String(e.message).slice(0, 90)}`); }

  const missing = (d.diff.paths || []).filter((p) => !paths.includes(p));
  if (missing.length) problems.push(`commit ${commit} does not touch ${missing.join(', ')} — the registered fix is not in this diff`);
  if (!d.diff.grep.test(body)) problems.push(`commit ${commit}'s diff never matches ${d.diff.grep} — verified by DIFF, never by subject line`);
  return `diff ${paths.length} file(s)`;
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

  L.push(`=== SEAL PREDICATE — epic ${EPIC} ===`);
  L.push(`read at ${STAMP}${fixture ? '  (LEDGER FIXTURE — not live)' : '  (live ledger)'}`);

  // ── REFUSALS. Evaluated BEFORE the roster is read, so nothing downstream can
  // print an unresolvable id as a forwarding address. ────────────────────────
  if (!Array.isArray(KNOWN_DEFECTS) || KNOWN_DEFECTS.length === 0)
    throw new Refusal('EMPTY-DEFECT-REGISTER',
      'KNOWN_DEFECTS is empty — clause (b) would certify the word KNOWN over zero defects and spawn no guard at all. An unrun clause is not a passed clause.');

  // R0 — `--guard-cmd` is a FIXTURE-ONLY affordance. It is applied verbatim once
  // per registered defect and never receives the defect id, so a single
  // `--guard-cmd true` marks every rung-1 entry measured-clean: the exact vacuous
  // green clause (b) exists to prevent, reachable from the command line.
  if (guardOverride !== null && !ledgerPath)
    throw new Refusal('GUARD-OVERRIDE-WITHOUT-FIXTURE',
      '--guard-cmd was given without --ledger. The override is applied once per registered defect and carries no defect id, so on a LIVE run it would certify clause (b) over a stub instead of the committed guard. Mutation proofs inject a ledger fixture; live runs use the committed guard.');

  const SUCCESSOR = arg('--successor') || (fixture ? fixture.successor : null) || null;
  if (typeof SUCCESSOR !== 'string' || SUCCESSOR.trim() === '')
    throw new Refusal('NO-SUCCESSOR',
      `no successor named (--successor <id>, --successor ${TERMINAL}, or \`successor\` in the ledger fixture). Clause (a) certifies that residue has a forwarding address; with none there is nothing to forward TO, and with zero live rows the absence would otherwise cost nothing and seal.`);

  // R4 — forwarding to yourself is not forwarding. `forwarded` is the SUCCESSOR's own
  // roster, so a successor equal to the epic makes clause (a) structurally unfailable.
  if (SUCCESSOR === EPIC)
    throw new Refusal('SELF-SUCCESSOR',
      `the successor offered is the epic itself (${EPIC}). Forwarding to yourself is not forwarding: the forwarded set is fetchRoster(successor), which for the epic's own id contains every live row by construction, so clause (a) could never fail. Measured before this refusal existed: 83 live rows -> forwarded 79, orphans 0, a=PASS.`);

  const terminal = SUCCESSOR === TERMINAL;

  if (!terminal) {
    const resolution = resolveTask(SUCCESSOR, fixture);
    if (!resolution.ok)
      throw new Refusal('UNRESOLVABLE-SUCCESSOR',
        `the id offered as successor does not resolve to a published task (${resolution.why}). Rejected id: ${SUCCESSOR}. It is NOT printed as a forwarding address, because it is not one.`);
  }

  // ── from here the successor is real (or TERMINAL), and may be named ─────────
  const children = fixture ? fixture.children : fetchRoster(EPIC);
  if (!Array.isArray(children)) throw new Infra('roster is not an array of documents');

  // The successor's own roster is the ONLY thing that makes a forwarding address "named".
  // TERMINAL claims there is nothing to forward, so it consults no roster at all.
  const forwarded = terminal
    ? new Set()
    : (fixture ? new Set(fixture.forwarded || []) : new Set(fetchRoster(SUCCESSOR).map((c) => c._id)));

  const byStatus = {};
  for (const c of children) byStatus[c.lifecycle_status] = (byStatus[c.lifecycle_status] || 0) + 1;
  const live = children.filter((c) => LIVE_STATUSES.includes(c.lifecycle_status));
  const considering = children.filter((c) => PENDING_STATUSES.includes(c.lifecycle_status));
  const residue = [...live, ...considering];

  // TERMINAL is a POST-CONDITION READ, not a flag. It is evaluated only after the
  // roster has been fetched and counted, and it refuses on either bucket.
  if (terminal && residue.length > 0)
    throw new Refusal('TERMINAL-CLAIM-REFUTED',
      `${TERMINAL} claims this epic has no residue to forward, and the roster read refutes it: ${live.length} live row(s) [${live.slice(0, 6).map((c) => c._id).join(', ')}${live.length > 6 ? ', …' : ''}] and ${considering.length} considering row(s) [${considering.slice(0, 6).map((c) => c._id).join(', ')}${considering.length > 6 ? ', …' : ''}]. A terminal epic is a roster fact, never a flag.`,
      'after the post-condition roster read');

  const orphans = [], gatedLive = [], fwd = [];
  for (const c of residue) {
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

  // Clause (b): a landed commit verified by ancestry AND diff, plus a measurement on
  // one of the three rungs. Rung 3 (neither) FAILS, by name.
  const waivers = new Set(fixture ? (fixture.unmeasuredWaivers || []) : []);
  const ladder = [];
  for (const d of KNOWN_DEFECTS) {
    const commit = (fixture && fixture.defectCommits && fixture.defectCommits[d.id] !== undefined)
      ? fixture.defectCommits[d.id] : d.commit;
    const problems = [];
    const notes = [];

    if (!commit) problems.push('NO COMMIT — defect is known and unlanded');
    else {
      const how = verifyCommit(d, commit, fixture, problems);
      if (how) notes.push(`commit ${commit} verified by ancestry + ${how}`);
    }

    // ── THE MEASUREMENT LADDER ──────────────────────────────────────────────
    let rung = 0;
    let stubbed = false;
    let waived = false;
    if (d.guard) {
      rung = 1;
      const guardPath = `${REPO}/${d.guard}`;
      let r;
      if (guardOverride) {
        r = spawnSync('sh', ['-c', guardOverride], { encoding: 'utf8' });
        stubbed = true;
        notes.push('guard STUBBED by --guard-cmd (fixture mode) — its output is not checked against guardExpect');
      } else if (!existsSync(guardPath)) {
        problems.push(`guard ${d.guard} is NOT COMMITTED — the fix is unmeasured, and unmeasured is not cleared`);
        r = null;
      } else {
        // A guard's verdict must not depend on WHO SPAWNED IT. Measured: driven from
        // `node --test`, NODE_TEST_CONTEXT is inherited, a node:test guard switches to
        // the V8-serialised reporter, and its stream is 1.16MB — over spawnSync's
        // default 1MB buffer. The guard PASSED and the predicate reported
        // "NEVER RAN (ENOBUFS)": a claim about a defect from a read that failed.
        // Hence both the sanitised env and the buffer wide enough for a chatty guard.
        r = spawnSync('node', [guardPath, '--defect', d.id], { encoding: 'utf8', timeout: 300000, env: GUARD_ENV, maxBuffer: 16 * 1024 * 1024 });
      }
      if (r) {
        const out = `${r.stdout || ''}${r.stderr || ''}`;
        if (r.error || r.status === null) {
          problems.push(`guard ${d.guard} NEVER RAN (${r.error ? r.error.code || r.error.message : `timeout or signal ${r.signal || '?'}`})`);
        } else if (r.status === 2) {
          // A guard's exit 2 is a REFUSAL to measure, never a defect claim. Reading it
          // as "still measurable" reports a defect nobody measured. The guard-side fix
          // is owned by the open row `hg-overflow-guard-refusal-exits-1`.
          throw new Infra(`guard ${d.guard} exited 2 for ${d.id} — that is a REFUSAL to measure (its own infra code), not a defect claim. Nothing is asserted about ${d.id}. The guard-side vocabulary fix is owned by hg-overflow-guard-refusal-exits-1, which this file names rather than duplicates.`);
        } else if (r.status !== 0) {
          problems.push(`guard exited ${r.status} — the defect is still measurable at origin/main`);
        } else if (!guardOverride && d.guardExpect && !out.includes(d.guardExpect)) {
          problems.push(`guard exited 0 but its output never named the measurement ("${d.guardExpect}") — an exit code is not a post-condition read`);
        } else {
          notes.push(guardOverride
            ? `MEASURED BY STUB — fixture mode only`
            : `MEASURED HERE by ${d.guard}, which printed "${d.guardExpect}"`);
        }
      }
    } else if (d.measured_by && d.measured_in_ci) {
      rung = 2;
      const missing = d.measured_by.filter((p) => !existsSync(`${REPO}/${p}`));
      if (missing.length === d.measured_by.length)
        problems.push(`measured_by names ${missing.join(', ')} and NONE of them exist — the measurement is asserted, not present`);
      const wf = `${REPO}/${d.measured_in_ci.workflow}`;
      if (!existsSync(wf)) problems.push(`measured_in_ci names ${d.measured_in_ci.workflow}, which does not exist`);
      else {
        const src = readFileSync(wf, 'utf8');
        if (!new RegExp(`^\\s{2}${d.measured_in_ci.job}:\\s*$`, 'm').test(src))
          problems.push(`${d.measured_in_ci.workflow} has no job \`${d.measured_in_ci.job}\` — the CI leg of this measurement does not exist`);
        if (!src.includes(d.measured_in_ci.paths))
          problems.push(`${d.measured_in_ci.workflow} does not filter on \`${d.measured_in_ci.paths}\` — the job exists but this code path would not trigger it`);
      }
      if (problems.length === 0)
        notes.push(`MEASURED-ELSEWHERE by ${d.measured_by.filter((p) => existsSync(`${REPO}/${p}`)).join(', ')}, run by ${d.measured_in_ci.workflow} job \`${d.measured_in_ci.job}\` on ${d.measured_in_ci.paths}. THIS RUN DID NOT EXECUTE IT — it verified only that the test file and the CI job exist.`);
    } else if (waivers.has(d.id)) {
      // FIXTURE-ONLY. Named, printed, and unreachable on a live run (a waiver can only
      // arrive through --ledger). It exists so the clause-(a) fixtures can reach a SEAL
      // while a rung-3 entry stands unmeasured in the register.
      rung = 3;
      waived = true;
      notes.push('UNMEASURED — WAIVED BY LEDGER FIXTURE. A mutation control only; no live run can carry a waiver.');
    } else {
      rung = 3;
      problems.push(`NO MEASUREMENT (rung 3): ${d.unmeasured || 'nothing measures this defect'}`);
    }

    ladder.push({ id: d.id, rung, problems, notes, stubbed, waived });
  }
  const defectFails = ladder.filter((e) => e.problems.length);

  // ── output ─────────────────────────────────────────────────────────────────
  L.push(`epic ${EPIC}   successor: ${terminal ? `${TERMINAL} (no successor — post-condition roster read: live=0 considering=0)` : SUCCESSOR}`);
  L.push(`roster: ${children.length} children  ${JSON.stringify(byStatus)}`);
  L.push('');
  L.push(`CLAUSE (a) forwarding — residue ${residue.length} (live ${live.length}, considering ${considering.length})`);
  L.push(`  forwarded under successor : ${fwd.length}`);
  L.push(`  permanent human gate      : ${gatedLive.length}  [${gatedLive.join(', ') || '-'}]`);
  L.push(`  considering (disclosed)   : ${considering.length}  [${considering.slice(0, 8).map((c) => c._id).join(', ') || '-'}${considering.length > 8 ? ', …' : ''}]`);
  L.push(`  UNNAMED RESIDUE (orphans) : ${orphans.length}`);
  orphans.slice(0, 8).forEach((o) => L.push(`      ✗ ${o}`));
  if (orphans.length > 8) L.push(`      … and ${orphans.length - 8} more`);
  L.push('');
  L.push('BUCKET (c) permanent human gates');
  for (const g of gateReport)
    L.push(`  ${g.resolved ? '✓' : '✗'} ${g.id}  status=${g.status} parent=${g.parent} in-epic-roster=${g.inRoster}`);
  L.push('');
  L.push(`CLAUSE (b) known user-facing defects — ${KNOWN_DEFECTS.length} registered`);
  const RUNG_MARK = { 1: '✓', 2: '◐', 3: '·' };
  for (const e of ladder) {
    const bad = e.problems.length > 0;
    L.push(`  ${bad ? '✗' : RUNG_MARK[e.rung] || '·'} ${e.id}  (rung ${e.rung}${e.rung === 2 ? ' — MEASURED-ELSEWHERE' : ''})`);
    e.notes.forEach((n) => L.push(`        ${n}`));
    e.problems.forEach((p) => L.push(`        ${p}`));
  }
  L.push('');

  const gateMissing = gateReport.filter((g) => !g.resolved);
  const ok = orphans.length === 0 && defectFails.length === 0 && gateMissing.length === 0;
  const measuredHere = ladder.filter((e) => e.rung === 1 && !e.problems.length && !e.stubbed).length;
  const stubbedCount = ladder.filter((e) => e.stubbed).length;
  const waivedCount = ladder.filter((e) => e.waived).length;
  const measuredElsewhere = ladder.filter((e) => e.rung === 2 && !e.problems.length).length;

  if (ok) {
    L.push('VERDICT: SEAL');
    L.push('');
    L.push(`SCOPE — what this green does and does NOT claim, read at ${STAMP}:`);
    L.push(`  Sealed ${children.length} children of ${EPIC}: ${byStatus.done || 0} evidence-closed, ${fwd.length} forwarded by name`);
    L.push(`  ${terminal ? `with NO successor — TERMINAL, on a roster read of live=0 and considering=0` : `to ${SUCCESSOR}`}, and ${Object.keys(PERMANENT_HUMAN_GATES).length} permanent human gate(s) disclosed by hardcoded name.`);
    L.push('  Zero unnamed residue — open, in_progress AND considering all accounted for.');
    L.push(`  Clause (b): ${measuredHere} defect(s) measured HERE by a committed guard, ${measuredElsewhere} MEASURED-ELSEWHERE.`);
    if (stubbedCount || waivedCount)
      L.push(`  FIXTURE-ONLY GREEN: ${stubbedCount} guard(s) STUBBED by --guard-cmd and ${waivedCount} unmeasured entr(ies) WAIVED by the ledger fixture. This green certifies the predicate's own logic, never the product.`);
    L.push('');
    L.push('  NOT asserted by this green:');
    L.push('   1. Defect coverage is bounded by what was REGISTERED. Clause (b) certifies the word');
    L.push(`      KNOWN over ${KNOWN_DEFECTS.length} hand-registered defects. A defect nobody looked for is invisible to it.`);
    L.push(`   2. ${measuredElsewhere} entr(y/ies) are MEASURED-ELSEWHERE: this run verified that the ExUnit file and`);
    L.push('      the CI job exist, and did NOT execute either. A green here is not a green suite.');
    L.push('   3. The mock-revoke divergence is NOT in the register — it is live clause-(a) residue,');
    L.push('      named here so a reader never mistakes its absence from clause (b) for its absence.');
    L.push('   4. This is a CODE seal. The permanent human gates above are discharged by humans,');
    L.push('      never by a commit, so "seal" never means "this feature is live for any human".');
  } else {
    L.push('VERDICT: NO SEAL');
    if (orphans.length) L.push(`  - ${orphans.length} residue row(s) carry no forwarding address and no gate label (clause a)`);
    if (defectFails.length) L.push(`  - ${defectFails.length} known user-facing defect(s) unlanded, unverifiable or UNMEASURED (clause b): ${defectFails.map((e) => e.id).join(', ')}`);
    if (gateMissing.length) L.push(`  - ${gateMissing.length} hardcoded human gate(s) failed to resolve (bucket c)`);
    L.push('  This is an acceptable, pre-committed outcome. The named successor is the honest handoff.');
  }
  L.push(`VERDICT-TOKEN: SEAL-PREDICATE ${ok ? 'SEAL' : 'NO-SEAL'} a=${orphans.length === 0 ? 'PASS' : 'FAIL'} b=${defectFails.length === 0 ? 'PASS' : 'FAIL'} c=${gateMissing.length === 0 ? 'PASS' : 'FAIL'} orphans=${orphans.length} considering=${considering.length} successor=${SUCCESSOR} epic=${EPIC} mode=${fixture ? 'fixture' : 'live'} stubbed=${stubbedCount} waived=${waivedCount}`);
  console.log(L.join('\n'));
  return ok ? 0 : 1;
}

let code = 2;
try {
  code = main();
} catch (e) {
  const stamp = new Date().toISOString();
  console.log(`=== SEAL PREDICATE — epic ${EPIC} ===`);
  if (e instanceof Refusal) {
    // A refusal IS a verdict — NO SEAL — but no clause may be reported PASS: either
    // none ran, or the one that would have passed was structurally unfailable.
    console.log(`REFUSED at ${stamp}, ${e.stage}: ${e.message}`);
    console.log('VERDICT: NO SEAL — REFUSED');
    console.log('  Nothing was certified. This is a pre-committed outcome: a predicate that prints an');
    console.log('  honest sentence and still exits 0 is the same defect as one that lies.');
    console.log(`VERDICT-TOKEN: SEAL-PREDICATE REFUSED reason=${e.code} a=UNEVALUATED b=UNEVALUATED c=UNEVALUATED epic=${EPIC}`);
    code = 1;
  } else {
    console.log(`INFRA FAULT at ${stamp}: ${e instanceof Infra ? e.message : `unexpected ${e.name}: ${e.message}`}`);
    console.log('  This is NOT a verdict. Nothing was measured, so nothing is claimed — the whole point');
    console.log('  of a third exit code is that this can never be read as NO SEAL.');
    console.log(`VERDICT-TOKEN: SEAL-PREDICATE INFRA-FAULT a=UNKNOWN b=UNKNOWN c=UNKNOWN epic=${EPIC}`);
    code = 2;
  }
}
// `process.exitCode`, never `process.exit()`: on a PIPE stdout is async, and an
// immediate exit truncates the verdict mid-sentence — a reader piping this into
// `head`/`tee` would see a report that stops before its own VERDICT line.
process.exitCode = code;
