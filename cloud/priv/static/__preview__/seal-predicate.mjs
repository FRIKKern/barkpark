#!/usr/bin/env node
// SEAL PREDICATE — asks ONE question about ONE epic: may this epic be sealed?
// The epic is `--epic`, defaulting to the Cloud Console hardening epic. FROZEN AT
// DECIDE (wave 7, charter D88/D89/D90) — before any builder of this wave flew.
//
//   exit 0 = SEAL.   exit 1 = NO SEAL (measured).   exit 2 = INFRA FAULT.   exit 3 = REFUSED (nothing measured).
//
// Four exit codes, not two — and not three. The two-code shape let exit 1 mean BOTH
// "no seal" and "a non-JSON HTTP response threw at the curl site", which is a red
// nobody can read; `tooling/grip/seal.mjs` names this file as that prior art and ports
// the triad plus a machine-readable `VERDICT-TOKEN:` line. The three-code shape then
// let exit 1 mean BOTH "no seal, measured over a real roster" and "REFUSED — an empty
// or malformed roster, nothing measured at all" (a `Refusal`, e.g. EMPTY-ROSTER,
// NO-SUCCESSOR, SELF-SUCCESSOR): the same ambiguity the third code was carved out to
// remove for infra faults, left standing one split over. Exit 3 removes it: a `Refusal`
// is not a verdict and must never share a code with one. Any consumer reading the exit
// code alone (`scripts/seal-run.sh` is the live one) needs the update too.
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
//   rung 2  measured_by: +    an ExUnit file, the CI workflow+job that runs it, AND a
//           measured_in_ci:   merge boundary that cannot pass while that job is red.
//                             PASSES, but is printed MEASURED-ELSEWHERE, never silently
//                             green: this run verified that the test file and the CI
//                             job EXIST, and says in the same breath that it did not
//                             execute them.
//   rung 3  NEITHER           FAILS clause (b), by name, with the gap stated.
//
// Register entry CCH-D5 (the rate limiter bucketing every user together) WAS rung 3
// through waves 7 and 8's Decide — `grep -rn peer_ip cloud/test` returned exactly one
// hit and it was a COMMENT — and clause (b) failed on it, which was the true answer and
// was not engineered around. Wave 8 paid it: `router_signin_rate_bucket_test.exs`
// measures the bucket separation through a real `Router.call/2`, so CCH-D5 is rung 2 and
// clause (b) can pass on its own merits. No rung-3 entry remains in the register. If a
// later wave adds one, this is where it will say so.
//
// ---------------------------------------------------------------------------
// WHY RUNG 2 IS A THREE-LEG STRUCTURAL READ AND NOT A grep FOR A PATHS FILTER
//
// Through wave 8 this file resolved rung 2 by `src.includes(d.measured_in_ci.paths)`
// against the workflow's RAW TEXT. Three things were wrong with that, and only the
// third is fatal:
//
//   1. It matched TEXT. A YAML COMMENT containing `cloud/**` satisfied it — measured
//      this wave. The epic's own honesty instrument could be greened with prose.
//   2. It asserted the WRONG STRUCTURE. A workflow-level `on: … paths:` filter is not
//      evidence that a job runs; it is evidence the whole workflow — and therefore the
//      check run — is ABSENT on every other PR (honest-gates D18).
//   3. It never asked the only question that matters: CAN THIS MEASUREMENT STOP A
//      MERGE? A job can exist, run, and go red while the PR merges green, because the
//      job is not a required status check. "Measured in CI" over an unenforced job is
//      a success claim backed by nothing — which is the exact class of lie this epic
//      was chartered to remove, sitting inside the instrument that certifies it.
//
// So rung 2 now reads STRUCTURE, in three legs, and each leg fails LOUDLY BY NAME:
//
//   Leg A  `.github/required-checks.json` — the committed record of this branch's
//          protection. `enforced !== true` is an INFRA FAULT, never a verdict: with no
//          enforcing boundary there is nothing to read a rung-2 claim against, so the
//          honest answer is "nothing was measured", not "measured".
//          WHAT LEG A IS NOT: this is the committed RECORD, not a live read of GitHub.
//          The predicate makes no network call by design (it is spawned bare in test
//          contexts with no token), so a spec that was never applied — or a branch
//          whose protection was changed out from under it — would read the same here.
//          That drift is a different instrument's job: `required-checks-verify.sh`
//          diffs this file against the live branch. The MEASURED-ELSEWHERE line says
//          which of the two it read, so the claim is never larger than the evidence.
//   Leg B  the AGGREGATOR over the named job, found structurally: the job in that same
//          workflow whose `needs:` contains the named job AND which carries
//          `if: always()`. Its rendered check-run context is its `name:` — which is
//          only true because it carries no `strategy.matrix`, so a matrixed candidate
//          is rejected by name rather than silently accepted.
//   Leg C  that aggregator's name is IN the required-context set. If not, the entry
//          drops to RUNG 3 and says which name is missing from which branch.
//
// A comment satisfies none of the three. The `paths` field is gone from the register
// entirely rather than left as data nothing reads.
//
// KNOWN AND ACCEPTED at the commit that introduced this: `Cloud gate` exists in
// cloud.yml and is NOT yet in the required set, so all four rung-2 entries read RUNG 3
// and clause (b) is FAIL. Registration is `cch-w9-register-console-and-cloud-gates`.
// Leg C is deliberately NOT softened to hide that window — a predicate that green-lights
// an unenforced job is worse than one that reds honestly for a week.
//
// ---------------------------------------------------------------------------
// WHY A GUARD'S EXIT 2 IS AN INFRA FAULT AND NOT A DEFECT CLAIM
//
// HISTORY, kept because the rule came from it: `overflow-guard.mjs` exits 2 for
// "unknown --defect" — a REFUSAL to measure — and the prior shape of this file
// laundered any non-zero into "the defect is still measurable at origin/main",
// i.e. it reported a defect it had never measured. This file now reads a guard's
// exit 2 as REFUSED → its own INFRA FAULT (exit 2), never a verdict.
//
// WHAT THIS FILE ACTUALLY SPAWNS (cchi-w18-bl-seal-predicate-header-asserts-
// absent-wiring): clause (b)'s spawn site reaches EXACTLY the `guard:` entries
// in KNOWN_DEFECTS, and the live register carries TWO —
// `cloud/priv/static/__app.test.mjs` (CCH-D1) and `design/emit-fence.test.mjs`
// (CCH-D7). overflow-guard.mjs is NOT among them and is never spawned here; it
// appears in this block as the historical example only. No clause-(b) entry
// naming it exists or is intended — wiring one in would be NEW work for its own
// row, none is filed. The guard-side vocabulary row
// `hg-overflow-guard-refusal-exits-1` has since CLOSED with a residual its
// closure does not cover: the die() refusal paths exit 2, but overflow-guard's
// outer `main().catch` still exits 1, so an unhandled crash there wears CI's
// measured-defect banner — a closed row is not proof the capability is
// complete.
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
//   R5  the named successor is a CORPSE         — DEAD-SUCCESSOR. Published, a task,
//       and `lifecycle_status` done/cancelled. Nothing read lifecycle_status until
//       wave 12, so the dead letterbox of D89 was wide open: `--successor
//       gr-p5r5-successor-seal` RESOLVED against a row that is `done` — and that row
//       was closed for PROMISING to file a successor.
//   R6  the named successor is INSIDE the epic  — SUCCESSOR-INSIDE-EPIC. R4 catches
//       only `SUCCESSOR === EPIC`; a CHILD of the epic is the same defect one hop
//       down. `gr-p5r5-successor-seal` was BOTH: done, and `parent_id:
//       cloud-console-hardening-epic`. Residue forwarded to a row inside the epic has
//       not left the epic, so clause (a) would certify a move that moved nothing.
//
// And a FOURTH clause-(a) shape, TERMINAL, reached only AFTER the roster is read:
// `--successor TERMINAL` claims the epic has no residue to forward. It is accepted ONLY
// on a post-condition READ of the roster showing live==0 AND considering==0 — never on
// the flag alone. Without it, R2+R3 make "zero residue, terminal epic" unreachable and
// the epic is architecturally required to spawn a child forever.
//
// ---------------------------------------------------------------------------
// WHY `--ladder-only` READS THE CLAUSE-(b) LADDER AND NEVER CLAIMS A VERDICT
//
// Four waves running, the epic's own seal question was unanswerable for a reason
// that has nothing to do with the epic: this instrument CONFLATED READING the
// clause-(b) ladder with CLAIMING a verdict. Every legal live invocation refuses
// UPSTREAM of the ladder — `--successor TERMINAL` throws TERMINAL-CLAIM-REFUTED and
// `--successor <name>` throws UNRESOLVABLE-SUCCESSOR, both ~20 lines before the
// ladder is even constructed — and the catch block prints a=UNEVALUATED
// b=UNEVALUATED c=UNEVALUATED. The only way anyone has read the ladder is by passing
// `--ledger <fixture>`, which substitutes the ROSTER but not the rung evidence (no
// fixture supplies `requiredContexts`, so Legs A/B/C read the real committed spec
// and the real cloud.yml and the guards really spawn). That accidental diagnostic is
// what `--ladder-only` makes explicit.
//
//   THE D83 BOUNDARY, IN SO MANY WORDS. D83 forbids MANUFACTURING A SUCCESSOR TO
//   FORCE A VERDICT — inventing a forwarding address so clause (a) passes and the
//   run can print SEAL. It does not forbid READING the ladder without claiming one.
//   `--ladder-only` manufactures nothing: it names no successor, reads no roster,
//   and evaluates neither clause (a) nor bucket (c). Its token says so in its own
//   letters — `LADDER-ONLY … a=NOT-READ c=NOT-READ` — so no reader can quote a
//   `--ladder-only` run as "the seal". There is no SEAL/NO-SEAL token on this path
//   and no `VERDICT:` line, by construction and by test.
//
//   WHY IT EXITS 0 ON A CLEAN READ EVEN WITH RUNG-3 ENTRIES. An instrument that
//   reads and then exits 1 gets wired into CI as a gate, and a gate is a verdict:
//   the conflation would grow straight back. The ONLY non-zero here is an INFRA
//   FAULT — nothing was read, so nothing is reported. A rung-3 entry is a READING,
//   printed by name, and reporting it is the whole job.
//
//   THE NEW LIE THE REGISTRATION FLIP CREATES, and this reading's own footer says it:
//   rung 2 is Leg A + Leg B + Leg C over the COMMITTED RECORD ONLY — this program
//   makes no network call BY DESIGN (see Leg A above). If the 4-context spec merges
//   but the PUT never lands, or is reverted, the ladder still prints rung 2 while
//   nothing enforces it. `scripts/required-checks-verify.sh` is the only instrument
//   that catches that drift, and this one names it rather than pretending to cover it.
//
// ---------------------------------------------------------------------------
// WHY TWO REFUSALS WERE ADDED IN WAVE 27, AND WHY THEY ARE ONE DISCIPLINE
//
// Both are the same sentence in two places: A POPULATION THIS PROGRAM COULD NOT READ IS
// NOT A POPULATION IT READ AND FOUND CLEAN.
//
//   UNREADABLE-REPO-ROOT / REPO-NOT-A-GIT-WORK-TREE (infra, exit 2)
//     Five clause-(b) legs resolve paths under `--repo`, and each reports its own miss
//     as a DEFECT sentence. A `git archive` extraction therefore produced six verbatim
//     "commit <sha> is not an ancestor of origin/main" lines — all false, all about a
//     directory rather than the product — at exit 0. Two consecutive waves quoted
//     output of that shape as this epic's primary finding. `assertReadableRepoRoot`
//     below fires BEFORE every clause and every refusal. See its own block for why the
//     git leg is live-path-only and why it never stats `.git`.
//
//   EMPTY-ROSTER (refusal, NO SEAL)
//     Clause (a) had no cardinality floor: `--epic cloud-console-hardening-epicc` — one
//     doubled letter — exited 0, `VERDICT: SEAL`, `a=PASS b=PASS c=PASS orphans=0`,
//     mode=live, over a roster of NOBODY, and printed "Sealed 0 children of
//     cloud-console-hardening-epicc". Clause (b) has refused an empty register since
//     wave 6 (R1); this is the identical rule finally pointed at clause (a)'s own
//     population.
//
// Neither changes a FROZEN INPUT and neither lowers a bar. `PERMANENT_HUMAN_GATES` and
// `KNOWN_DEFECTS` are byte-identical: a refusal turns a FALSE verdict into an honest
// infra fault, which is the opposite of re-deriving a rule after seeing a result.
//
// ---------------------------------------------------------------------------
//   --epic <id>        the epic under judgement (default: cloud-console-hardening-epic)
//   --ledger <file>    inject a ledger fixture instead of live HTTP (mutation proofs only)
//   --successor <id>   the successor epic's task id, or the literal TERMINAL
//   --repo <path>      repo root
//   --guard-cmd <cmd>  override the guard command (mutation proofs only — REFUSED
//                      unless --ledger is also given; see R0)
//   --ladder-only      READ the clause-(b) ladder and print it. No roster fetch, no
//                      successor refusals, no clause (a), no bucket (c), and NO
//                      VERDICT — never SEAL, never NO-SEAL. Exit 0 on a clean read;
//                      non-zero ONLY on an INFRA FAULT.

import { execFileSync, spawnSync } from 'node:child_process';
import { existsSync, readFileSync, realpathSync } from 'node:fs';

const argv = process.argv.slice(2);
const arg = (n) => { const i = argv.indexOf(n); return i === -1 ? null : argv[i + 1]; };

const EPIC = arg('--epic') || 'cloud-console-hardening-epic';
const TERMINAL = 'TERMINAL';
const SERVER = process.env.BP_SERVER || 'https://guerrilla.barkpark.cloud';
const TOKEN = process.env.BP_TOKEN;
const REPO = arg('--repo') || process.cwd();
// A boolean flag, never `arg('--ladder-only')`: it takes no value, so reading one
// would swallow the next flag and silently mode-shift a run nobody asked to shift.
const LADDER_ONLY = argv.includes('--ladder-only');

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
//   measured_by / measured_in_ci   rung 2. `measured_in_ci` is { workflow, job } — and
//                                  deliberately NOT a `paths:` string any more: the
//                                  resolver reads the workflow's JOB GRAPH and the
//                                  branch's required-context set, so there is nothing
//                                  left for a path glob to be grepped against.
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
    measured_in_ci: { workflow: '.github/workflows/cloud.yml', job: 'test' },
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
    measured_in_ci: { workflow: '.github/workflows/cloud.yml', job: 'test' },
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
    measured_in_ci: { workflow: '.github/workflows/cloud.yml', job: 'test' },
  },
  {
    id: 'CCH-D5-rate-limiter-sees-every-user-as-one',
    desc: 'The sign-in rate bucket keyed on the proxy peer, so all users behind the front door shared one bucket — one attacker locks out everyone',
    // Same root fix as CCH-D2 (peer_ip/1 now resolves the real client IP). It stood at
    // RUNG 3 through waves 7 and 8's Decide, because the only mention of peer_ip in
    // cloud/test was a COMMENT (router_test.exs:2374 — the cite read 2215 until this
    // edit corrected it), and a comment measures nothing.
    //
    // Now rung 2. router_signin_rate_bucket_test.exs drives TWO forwarded client
    // addresses through a real `Router.call/2` and asserts one client's exhausted
    // budget does not touch the other's. It is registered as the SOLE measured_by path
    // deliberately: the classifier only raises when EVERY named path is missing, so a
    // second, weaker path would let this entry survive that file's deletion.
    //
    // Its two neighbours are NOT registered here, because neither measures this:
    // device_auth_test.exs's "distinct keys have independent budgets" calls
    // RateLimiter.check/1 directly and is blind to which key the router builds, and
    // router_test.exs's "front door" block reads conn.remote_ip on GET /up and never
    // reaches a bucket. Both stay GREEN (203/0) under the key-collapse mutation at
    // router.ex:766 that reds the registered file 2/2 — that is the discrimination.
    commit: '8fd00b6afb1eca55d3c991f7921ed6ec2b7d77b4',
    diff: { paths: ['cloud/lib/barkpark_cloud/web/router.ex'], grep: /trusted_proxy_peers/ },
    measured_by: ['cloud/test/barkpark_cloud/web/router_signin_rate_bucket_test.exs'],
    measured_in_ci: { workflow: '.github/workflows/cloud.yml', job: 'test' },
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
//
// `Infra` carries an OPTIONAL machine-readable `code`, added in wave 27 for the same
// reason `Refusal` has always had one: an infra fault whose only distinguishing mark is
// a paragraph of English cannot be told apart by anything that reads the token line, so
// "you pointed me at the wrong tree" and "your ledger fixture is unreadable" were one
// undifferentiated exit 2. Legacy throws pass no code and print `code=UNSPECIFIED`
// rather than being retrofitted with a guess.
class Infra extends Error {
  constructor(message, code = null) { super(message); this.code = code; }
}
class Refusal extends Error {
  constructor(code, message, stage = 'before any clause was evaluated') {
    super(message);
    this.code = code;
    this.stage = stage;
  }
}

// CURL IS NO LONGER MUTE. `curl -sG` carries no `--fail`, so an HTTP 401/403/404/500 with
// a JSON error body PARSED FINE and the caller's `.result.documents` then threw a bare
// `TypeError: Cannot read properties of undefined (reading 'documents')` —
// `code=UNSPECIFIED`. It failed CLOSED, which is right, and named neither the HTTP status
// nor the `request_id` it had just parsed and thrown away, which is the whole diagnosis a
// reader needs. `-w` appends the status on its own trailing line so the status is read
// from curl itself rather than guessed from the body's shape.
function q(params) {
  const a = ['-sG', `${SERVER}/v1/data/query/production/task`, '-w', '\n%{http_code}'];
  for (const [k, v] of params) a.push('--data-urlencode', `${k}=${v}`);
  a.push('-H', `Authorization: Bearer ${TOKEN}`);
  let raw;
  try { raw = execFileSync('curl', a, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 }); }
  catch (e) { throw new Infra(`curl failed: ${String(e.message).slice(0, 90)}`, 'LEDGER-UNREACHABLE'); }
  // TRAILING WHITESPACE FIRST. `-w '\n%{http_code}'` emits no newline after the code, but
  // a `lastIndexOf('\n')` over bytes that DO end in one reads the status as the empty
  // string and then reports `HTTP ` — a diagnosis with a hole exactly where the number
  // goes, which is the defect this whole change exists to remove.
  const trimmed = raw.replace(/\s+$/, '');
  const cut = trimmed.lastIndexOf('\n');
  const status = cut === -1 ? '000' : trimmed.slice(cut + 1).trim();
  const body = cut === -1 ? trimmed : trimmed.slice(0, cut);
  let parsed = null;
  try { parsed = JSON.parse(body); } catch { parsed = null; }
  if (!/^2\d\d$/.test(status)) {
    const err = (parsed && (parsed.error || parsed)) || {};
    throw new Infra(
      `the ledger answered HTTP ${status} — error.code=${err.code || '(none named)'} request_id=${(parsed && (parsed.request_id || err.request_id)) || '(none returned)'} message=${String(err.message || '').slice(0, 90) || '(none)'}. `
      + 'Nothing about clause (a) or bucket (c) is asserted: a roster this program could not fetch is not a roster it fetched and found clean.',
      'LEDGER-UNREADABLE');
  }
  if (parsed === null)
    throw new Infra(`response is not JSON (HTTP ${status}; ${body.slice(0, 60).replace(/\s+/g, ' ')})`, 'LEDGER-UNREADABLE');
  return parsed;
}
// NEVER bare ?parent_id= — proven at Decide to silently return 500 unfiltered rows.
//
// AND NEVER AN UNCHECKED PAGE. `result.count` is the PAGE SIZE, not a total. Waves 29–63
// read ONE page of 500 and REFUSED whenever it came back full, because a full page cannot
// be told from a complete one: measured, lower the limit to 3 and the predicate printed
// `VERDICT: SEAL  orphans=0` at exit 0 over a roster of 288 carrying 57 orphans — a DRIVEN
// false seal, exit 0, from one number. The refusal was right. What it was NOT is a read:
// this epic passed 500 children in wave ~40 and has 850 today, so the instrument that
// certifies this epic could no longer read this epic, and every Law-0 figure the waves
// quoted came from a raw `curl limit=1000` with NO truncation guard of its own — 150 rows
// from failing SILENTLY the exact way the predicate failed loudly.
//
// SO: PAGINATE, AND NAME THE AFFORDANCE. The endpoint is not mute about paging; the old
// read simply never asked. `docs/api-v1.md` §4 documents `offset` and `count=true`, and
// both were re-measured against the live ledger on 2026-08-09 before a line of this was
// written:
//
//   …/v1/data/query/production/task?filter[parent_id]=cloud-console-hardening-epic
//     &limit=500&offset=0&count=true   -> {count:500, offset:0, limit:500, total:850}
//     &limit=500&offset=500&count=true -> {count:350, offset:500, limit:500, total:850}
//
// `offset` MOVES THE WINDOW and `count=true` ADDS `result.total`. So the "no total and no
// hasMore" clause of the old refusal was never a property of the endpoint — it was a
// property of the request.
//
// ORDER IS `_createdAt:asc`, AND IT IS LOAD-BEARING. The default order is
// `_updatedAt:desc`, which MUTATES under a live wave: every pulse, stamp and close
// re-sorts the population mid-walk, so offset paging over it hands back one row twice and
// drops another for good. `_createdAt` never changes after insert, so pages cannot
// re-shuffle beneath the walk, and rows created DURING it sort to the tail where the walk
// has not been yet. Also measured on 2026-08-09: an order the endpoint does not honour is
// IGNORED SILENTLY, not refused — `order=_id:asc` came back in `_updatedAt:desc` with no
// error and no signal — so the walk VERIFIES the ordering it asked for instead of
// trusting it.
//
// THE REFUSAL SURVIVES, RE-AIMED. `ROSTER-TRUNCATED` is no longer "a page came back full";
// it is "PAGINATION COULD NOT TERMINATE", which has exactly two shapes and both are
// refusals, never warnings: the window stopped advancing (a full page repeating the
// previous page's first id — the signature of an `offset` the server ignored), or the page
// ceiling was reached with the walk still unfinished. A pagination fix that left the
// instrument unable to refuse would have traded one silence for another.
const ROSTER_PAGE_LIMIT = 500;
// The walk terminates or it refuses. 40 pages x 500 = 20,000 rows — two orders of
// magnitude above the largest parent in this ledger, so reaching it is a broken endpoint
// or a broken loop, never a big epic.
const ROSTER_MAX_PAGES = 40;
// Immutable after insert. See the ORDER paragraph above: this is why, and it is verified
// rather than assumed because an unhonoured order is dropped in silence.
const ROSTER_ORDER = '_createdAt:asc';
const fetchRoster = (parentId) => {
  const rows = [];
  const seen = new Set();
  let offset = 0;
  let total = null;
  let prevFirstId = null;
  let highWater = '';
  for (let page = 1; ; page += 1) {
    if (page > ROSTER_MAX_PAGES)
      throw new Infra(
        `the roster of ${parentId} could not be paginated to the end — ${ROSTER_MAX_PAGES} pages of ${ROSTER_PAGE_LIMIT} were read (${rows.length} rows) and the walk was still not finished${total === null ? '' : `, against a reported total of ${total}`}. Pagination that cannot terminate is a roster this program could not read WHOLE, and every row beyond the ceiling is invisible: clause (a) would count orphans over a population it silently truncated and report orphans=0 as evidence. Nothing is asserted about clause (a).`,
        'ROSTER-TRUNCATED');

    const result = q([
      ['filter[parent_id]', parentId],
      ['limit', String(ROSTER_PAGE_LIMIT)],
      ['offset', String(offset)],
      ['order', ROSTER_ORDER],
      ['count', 'true'],
    ]).result || {};
    const docs = result.documents;
    if (!Array.isArray(docs)) throw new Infra(`the roster of ${parentId} is not an array of documents`, 'ROSTER-NOT-AN-ARRAY');
    if (typeof result.total === 'number') total = result.total;

    // THE WINDOW MUST MOVE. A full page whose first id repeats the previous page's is an
    // `offset` the server ignored, and the walk would read page 1 forever.
    //
    // FIRST, BEFORE THE ORDER CHECK, and that ordering is the diagnosis. A repeated page
    // also reads as OUT OF ORDER — the same rows, the same stamps, going backwards — so
    // whichever check runs first NAMES the fault. "Your offset did nothing" is the true
    // sentence; "your rows came back out of order" is a symptom of it.
    const firstId = docs.length ? docs[0]._id : null;
    if (docs.length >= ROSTER_PAGE_LIMIT && firstId !== null && firstId === prevFirstId)
      throw new Infra(
        `the roster of ${parentId} STOPPED ADVANCING at offset ${offset} — a FULL page of ${ROSTER_PAGE_LIMIT} rows came back whose first id (${firstId}) is the first id of the page before it, so \`offset\` did not move the window and every row beyond this page is invisible. Pagination that cannot terminate is a roster this program could not read WHOLE: clause (a) would count orphans over a population it silently truncated and report orphans=0 as evidence. Nothing is asserted about clause (a).`,
        'ROSTER-TRUNCATED');
    prevFirstId = firstId;

    // THE ORDER THE SERVER ACTUALLY USED, read off the rows rather than off a parameter
    // it may have dropped without saying so. A descending or absent `_createdAt` means
    // the walk is paging over a sequence that is not the one it asked for, and offset
    // paging over a re-sorting population skips rows.
    for (const d of docs) {
      const at = d && d._createdAt;
      if (typeof at !== 'string' || at === '')
        throw new Infra(
          `the roster of ${parentId} carries a row with no _createdAt (${(d && d._id) || 'id absent'}) at offset ${offset}. The walk pages by \`order=${ROSTER_ORDER}\` and verifies it; a row with no sort key cannot be placed, so the completeness of this roster is unknown and nothing is asserted about clause (a).`,
          'ROSTER-UNORDERED');
      if (at < highWater)
        throw new Infra(
          `the roster of ${parentId} came back OUT OF ORDER at offset ${offset}: ${d._id} carries _createdAt=${at}, before ${highWater} which was already read. \`order=${ROSTER_ORDER}\` was requested and this endpoint IGNORES an order it does not honour SILENTLY, so the walk verifies it — offset paging over a sequence that re-sorts mid-walk repeats rows and drops others, and a roster read that way is not a roster this program read. Nothing is asserted about clause (a).`,
          'ROSTER-UNORDERED');
      highWater = at;
    }

    // Dedupe by `_id`: a row created mid-walk sorts to the tail under `_createdAt:asc`,
    // but a row that lands exactly on a page boundary can still be served twice, and a
    // roster counted with a double in it is not the population it claims to be.
    for (const d of docs) if (!seen.has(d._id)) { seen.add(d._id); rows.push(d); }

    // A SHORT PAGE IS THE END — the only termination this walk has, and it is the one
    // the old single-shot read could not distinguish from a truncation.
    if (docs.length < ROSTER_PAGE_LIMIT) break;
    offset += ROSTER_PAGE_LIMIT;
  }

  // THE COUNT THE SERVER ITSELF REPORTED. Fewer unique rows than `total` means the walk
  // MISSED some — a row unpublished or reparented mid-walk shifts the window left and
  // takes a row with it. More is fine and is not a miss: rows created after the count
  // was taken land at the tail and were read.
  if (typeof total === 'number' && rows.length < total)
    throw new Infra(
      `the roster of ${parentId} came back SHORT — ${rows.length} unique rows paginated against a server-reported total of ${total} (${total - rows.length} missing). The population shifted underneath the walk, so this is a roster this program could not read whole and clause (a) would report orphans=0 over the part of it that survived. Nothing is asserted about clause (a).`,
      'ROSTER-INCOMPLETE');
  return rows;
};
// THE OTHER HALF OF THE SAME DISEASE, and the one wave 64 left standing. The roster read
// was taught to page-or-refuse; this by-id read still could not tell the row it ASKED FOR
// from a row it merely RECEIVED:
//
//     const fetchById = (id) => q([['filter[_id]', id]]).result.documents[0] || null;
//
// No `limit`, no `count`, and no check that `documents[0]._id === id`. Three lines above,
// this file already records that this endpoint DROPS a filter it does not recognise
// SILENTLY and answers unfiltered ("NEVER bare ?parent_id= — proven at Decide to silently
// return 500 unfiltered rows"). RE-MEASURED against the live ledger on 2026-08-22, and the
// precedent is not history — it is current behaviour:
//
//   …/v1/data/query/production/task?filter[_id]=<a real id>&count=true -> {count:1, total:1}
//   …?filter[_id]=<a garbage id>&count=true                            -> {count:0, total:0}
//   …?_id=<a real id>&limit=3&count=true   (the filter[] wrapper LOST) -> {count:3, total:6994}
//   …?count=true            (no filter, no limit — the DEFAULT window) -> {count:100, total:6994}
//
// So one dropped `filter[]` wrapper — a rename, a typo, an API revision — turns
// `fetchById(anything)` into "the most recently updated task in the ledger", HTTP 200, no
// error, no signal. What reads off it:
//
//   BUCKET (c) — `resolved: !!doc` over PERMANENT_HUMAN_GATES. The clause exists to catch
//     a gate that silently VANISHED. Under a dropped filter EVERY gate resolves ✓, over a
//     stranger's row, and the clause becomes structurally unable to lose — the exact shape
//     of the roster defect this task was filed for, one call site over.
//   resolveTask — R5 (dead letterbox) and R6 (successor inside the epic) read
//     `lifecycle_status` and `parent_id`. Off the wrong row, both fences read a stranger.
//
// SO: ASK FOR A WINDOW, AND VERIFY THE ROW. `limit=2` is the whole trick — one row is the
// answer, a SECOND row is proof the filter did not hold — and `count=true` makes the
// server state how many rows actually matched, so the refusal can report its own sample
// size instead of implying one. Zero rows stays a real answer (`null`): "no such task" is
// a fact about the ledger, not a truncation.
//
// TWO ARMS, AND NEITHER SUBSUMES THE OTHER. Cardinality catches a dropped filter over a
// populated ledger (many rows come back). Identity catches the same drop where only one
// row could come back at all — a one-row page, or a server that pins `limit` to 1. A
// checkout that kept only one of them would still have a shape it answers blind on.
const LOOKUP_LIMIT = 2;
const fetchById = (id) => {
  const result = q([['filter[_id]', id], ['limit', String(LOOKUP_LIMIT)], ['count', 'true']]).result || {};
  const docs = result.documents;
  if (!Array.isArray(docs))
    throw new Infra(`the lookup of ${id} is not an array of documents`, 'LOOKUP-NOT-AN-ARRAY');
  const total = typeof result.total === 'number' ? result.total : null;

  // ARM 1 — CARDINALITY. `_id` is unique, so more than one row for one id means the
  // response is not an answer to the question that was asked.
  if (docs.length > 1)
    throw new Infra(
      `the lookup of ${id} came back with ${docs.length} rows for ONE _id${total === null ? '' : ` (the server's own count says ${total} matched)`} — [${docs.slice(0, 4).map((d) => (d && d._id) || 'id absent').join(', ')}${docs.length > 4 ? ', …' : ''}]. \`_id\` is unique, so a multi-row answer is a \`filter[_id]\` this endpoint DROPPED and answered unfiltered — measured live on 2026-08-22, a lost \`filter[]\` wrapper returns the whole task table. Read blind, bucket (c) would resolve every permanent human gate ✓ against whichever stranger sorted first and could never lose. Nothing is asserted about bucket (c) or the successor fences.`,
      'LOOKUP-UNFILTERED');

  const doc = docs[0];
  if (!doc) return null;

  // ARM 2 — IDENTITY. One row is not evidence it is THE row. Read the id off the document
  // rather than off the parameter that was sent, exactly as the roster walk reads the
  // order off the rows rather than off the `order=` it asked for.
  if (doc._id !== id)
    throw new Infra(
      `the lookup of ${id} came back with ${(doc && doc._id) || 'a row carrying no _id'} instead${total === null ? '' : ` (the server's own count says ${total} matched)`}. One row is not evidence it is THE row: a \`filter[_id]\` the endpoint dropped answers HTTP 200 with a stranger, and every fence downstream — bucket (c)'s \`resolved\`, R5's \`lifecycle_status\`, R6's \`parent_id\` — would then be read off that stranger. Nothing is asserted about bucket (c) or the successor fences.`,
      'LOOKUP-WRONG-ROW');
  return doc;
};

// A successor must be a row someone can still WORK. `done` and `cancelled` are
// containers nobody opens again, so forwarding residue into one is filing it into a
// dead letterbox — the address exists, and nothing behind it will ever be read.
const SUCCESSOR_LIVE_STATUSES = ['open', 'in_progress'];
// How far up a parent chain the ancestry fence will walk before it stops. A ledger
// tree this deep is a data fault, not a legitimate successor, and the walk must
// terminate whatever the ledger says.
const ANCESTRY_MAX_HOPS = 16;

// A task id is RESOLVED only by a document that exists, is a task, is PUBLISHED, is
// LIVE, and sits OUTSIDE the epic it forwards out of.
// Unpublished is unresolved: boards and gates read the published ledger only, so an
// unpublished successor is a forwarding address no reader can follow.
//
// The last two fences were added in wave 12, and both were REACHABLE on the live
// ledger the hour before: `--successor gr-p5r5-successor-seal` RESOLVED, and that row
// is `lifecycle_status: done`, `status: published`, `parent_id:
// cloud-console-hardening-epic` — a corpse AND a child of the epic it was offered as
// the way out of. It was closed for PROMISING to file a successor. R4 refuses only
// `SUCCESSOR === EPIC`, so a child of the epic slipped straight past it; nothing read
// `lifecycle_status` at all. Each fence gets its OWN refusal code, because "this id is
// unknown", "this id is a corpse" and "this id is inside the epic" are three different
// facts about the ledger and a reader must be told which one fired.
function resolveTask(id, fixture, opts = {}) {
  const lookup = (x) => (fixture
    ? ((fixture.tasks || {})[x] || (fixture.gates || {})[x] || null)
    : fetchById(x));
  const doc = lookup(id);
  if (!doc) return { ok: false, code: 'UNRESOLVABLE-SUCCESSOR', why: 'no published task with that id' };
  if (doc._type && doc._type !== 'task') return { ok: false, code: 'UNRESOLVABLE-SUCCESSOR', why: `id resolves to _type=${doc._type}, not a task` };
  if (doc.status && doc.status !== 'published') return { ok: false, code: 'UNRESOLVABLE-SUCCESSOR', why: `task exists but status=${doc.status}` };

  // R5 — THE DEAD LETTERBOX. A closed row accepts forwarding and works none of it.
  const lifecycle = doc.lifecycle_status;
  if (!SUCCESSOR_LIVE_STATUSES.includes(lifecycle))
    return {
      ok: false,
      code: 'DEAD-SUCCESSOR',
      why: `lifecycle_status=${lifecycle === undefined || lifecycle === null ? '(absent)' : lifecycle}, and a successor must be one of ${SUCCESSOR_LIVE_STATUSES.join('/')}. Forwarding residue into a closed row is filing it into a dead letterbox: the address resolves, and nothing behind it is ever worked again`,
    };

  // R6 — INSIDE THE EPIC IT FORWARDS OUT OF. R4 refuses only the epic itself; a CHILD
  // of the epic is the same defect one hop down, and every hop below that too.
  const epic = opts.epic;
  if (epic) {
    const trail = [id];
    const seen = new Set([id]);
    let cur = doc;
    for (let hop = 1; cur && cur.parent_id && hop <= ANCESTRY_MAX_HOPS; hop += 1) {
      trail.push(cur.parent_id);
      if (cur.parent_id === epic)
        return {
          ok: false,
          code: 'SUCCESSOR-INSIDE-EPIC',
          why: `its parent chain reaches the epic under judgement after ${hop} hop(s): ${trail.join(' -> ')}. A row inside the epic is not OUT of it: residue forwarded there is still residue of ${epic}, so clause (a) would certify a move that moved nothing`,
        };
      if (seen.has(cur.parent_id)) break; // a cycle in the ledger, not a successor
      seen.add(cur.parent_id);
      cur = lookup(cur.parent_id);
    }
  }

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

// ---------------------------------------------------------------------------
// FOUR PROBES — "I COULD NOT LOOK" IS NOT "THE THING IS BROKEN"
//
// The ancestry leg used to be one `try/catch` around `merge-base --is-ancestor`, and
// its catch swallowed FIVE distinguishable conditions into one identical sentence about
// the PRODUCT: `commit <sha> is not an ancestor of origin/main`. Measured on origin/main
// in a pristine `git clone --depth 1 --branch main` of this repository: six of those
// sentences, all six false, none of them about the product. Wave 27 fixed the shape at
// the ROOT (a `git archive` extraction is refused before any clause runs) and left it
// standing at the OBJECT — a real checkout of a real repository whose HISTORY is simply
// not present.
//
// WHAT WAS MEASURED, so no future reader re-derives it (charter D328/D335):
//
//   (A) rc 1 FROM `merge-base --is-ancestor` IS AMBIGUOUS. In a depth-1 clone with the
//       commit object fetched IN (grafted), `cat-file -e` is rc 0, `git show
//       --name-only` is rc 0 WITH REAL BYTES, and `is-ancestor` still answers rc 1 for a
//       commit a full clone confirms IS an ancestor. OBJECT PRESENCE IS NOT THE
//       DISCRIMINATOR; the truncated WALK is.
//   (B) `git rev-parse --is-shallow-repository` ALONE OVER-REPORTS. This repository's own
//       `.git/shallow` holds one graft (`360b675903…`) that is NOT on main's ancestry, so
//       the developer host, every epic worktree, and even a plain `git clone` over
//       file:// all answer `true`. EXPECT is-shallow=true LOCALLY WITH walk=complete —
//       that is a correct reading, not a degraded environment. A leg keyed on the
//       store-level flag alone would degrade every local run to "unreadable".
//   (C) `actions/checkout@v4` makes TWO shapes. push->main resolves `origin/main` (rc 0)
//       and misses the OBJECTS (rc 128). A pull_request checkout fetches only
//       `refs/remotes/pull/N/merge`, so `rev-parse --verify --quiet origin/main` answers
//       rc 1 — the SAME code as an honest "no". Both still die rc 128 at merge-base, so
//       the discrimination keys on the MERGE-BASE rc and on the four probes, never on
//       "does origin/main resolve" alone.
//
// THE FOUR PROBES, read SEPARATELY and never folding one's rc into another's:
//
//   1. REF     `rev-parse --verify --quiet origin/main` — is there a thing to compare to?
//   2. OBJECT  `cat-file -e <sha>^{commit}` — is the commit itself in this store?
//   3. WALK    is a graft on HEAD's OWN history? — PORTED from
//              `scripts/pds-record-parity.sh:261 walk_truncation()`, which is
//              mutation-proven in `scripts/pds-record-parity.test.sh`. That file is
//              PDS-owned and a concurrent wave is live on it, so the LOGIC is ported
//              rather than the file imported — and this file's own header law is ZERO
//              DEPENDENCIES anyway. EXTENDED here with the REF leg, because
//              `walk_truncation` only ever asks about HEAD and the pull_request shape's
//              failure is that `origin/main` does not exist at all.
//   4. ANCESTRY `merge-base --is-ancestor` — reached only with 1, 2 and 3 clean, and only
//              THEN is its rc 1 an honest claim about the PRODUCT.
//
// A FIFTH LEG NOBODY NAMED, and it is the false PASS to the others' false FAIL: a grafted
// clone ALSO corrupts clause (b)'s DIFF. `git show --name-only` for
// `8fd00b6afb1eca55d…` returns 7535 paths in a grafted clone versus 5 in a full one — the
// parent is absent, so the whole tree renders as additions and BOTH the path-touch leg
// and the diff grep pass by construction. Probing only ancestry would fix the false FAIL
// and leave a false PASS standing, so `diffIntegrity` is probed on the ancestor path too.
const gitProbe = (args) => {
  const r = spawnSync('git', ['-C', REPO, ...args], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  // A spawn that never ran and a `null` status are BOTH "git would not answer". They are
  // reported as 128 — git's own can-not-look code — and never as 1, which is an ANSWER.
  return { rc: r.error || r.status === null ? 128 : r.status, out: (r.stdout || '').trim() };
};

// PORTED from scripts/pds-record-parity.sh:261 `walk_truncation()`, fail-closed in all
// four of its own unknown shapes (non-boolean store answer, missing common dir,
// unreadable graft list, untestable graft). Memoised: it is repository-wide, asked once
// per registered defect, and cannot change mid-run.
let _walkCache = null;
function walkTruncation() {
  if (_walkCache) return _walkCache;
  // `shallowStore` is a BOOLEAN, not a sentence. `graftList()` needs to know whether a
  // graft list can exist at all, and keying that on the prose of `reason` would couple a
  // control path to a string anyone may reword. `null` = the store never answered.
  const set = (state, reason, graft = null, shallowStore = null) =>
    (_walkCache = { state, reason, graft, shallowStore });

  const store = gitProbe(['rev-parse', '--is-shallow-repository']);
  if (store.rc !== 0)
    return set('unknown', `\`git rev-parse --is-shallow-repository\` exited ${store.rc}, so this checkout will not say whether its walk is whole`);
  if (store.out === 'false') return set('complete', 'the store is not shallow at all', null, false);
  if (store.out !== 'true')
    return set('unknown', `\`git rev-parse --is-shallow-repository\` answered '${store.out || '<nothing>'}', which is neither true nor false`);

  // Store-shallow. THE STORE FLAG IS NOT THE QUESTION (see (B) above): ask whether a
  // graft lies on HEAD's OWN history.
  const common = gitProbe(['rev-parse', '--git-common-dir']);
  if (common.rc !== 0 || !common.out)
    return set('unknown', 'the store is shallow but `git rev-parse --git-common-dir` answered nothing, so the graft list cannot be located', null, true);
  const dir = common.out.startsWith('/') ? common.out : `${REPO}/${common.out}`;
  const grafts = `${dir.replace(/\/$/, '')}/shallow`;
  if (!existsSync(grafts))
    return set('unknown', `the store is shallow but the graft list ${grafts} is missing or unreadable, so no graft can be tested against HEAD`, null, true);
  let list;
  try { list = readFileSync(grafts, 'utf8'); }
  catch { return set('unknown', `the store is shallow but the graft list ${grafts} could not be read, so no graft can be tested against HEAD`, null, true); }

  for (const line of list.split('\n')) {
    const g = line.trim();
    if (!g || g.startsWith('#')) continue;
    const r = gitProbe(['merge-base', '--is-ancestor', g, 'HEAD']);
    if (r.rc === 0) return set('truncated', `graft ${g} lies on HEAD's own history, so this walk stops early`, g, true);
    if (r.rc === 1) continue;               // a real answer: this graft is off HEAD's history
    return set('unknown', `graft ${g} could not be tested against HEAD (git merge-base --is-ancestor exit ${r.rc})`, g, true);
  }
  return set('complete', `store-shallow, but no graft in ${grafts} lies on HEAD's history`, null, true);
}

// The graft shas themselves, full-length, for the diff-integrity probe. [] when the
// store is not shallow or the list is unreadable — the WALK probe is what reports an
// unreadable graft list, and reporting it twice would double-count one condition.
function graftList() {
  const w = walkTruncation();
  if (w.shallowStore === false) return [];
  const common = gitProbe(['rev-parse', '--git-common-dir']);
  if (common.rc !== 0 || !common.out) return [];
  const dir = common.out.startsWith('/') ? common.out : `${REPO}/${common.out}`;
  try { return readFileSync(`${dir.replace(/\/$/, '')}/shallow`, 'utf8').split('\n').map((l) => l.trim()).filter(Boolean); }
  catch { return []; }
}

// PROBE 5 — CAN THIS COMMIT'S DIFF BE COMPUTED AT ALL? A graft boundary has no parent in
// the store, so git renders its patch against the EMPTY TREE and every path in the
// repository reads as an addition. Clause (b) then passes by construction on a register
// entry it never actually verified.
function diffIntegrity(sha) {
  const rl = gitProbe(['rev-list', '--parents', '-n', '1', sha]);
  if (rl.rc !== 0) return { state: 'unknown', why: `\`git rev-list --parents -n 1 ${sha}\` exited ${rl.rc}` };
  const parents = rl.out.split(/\s+/).filter(Boolean).slice(1);
  const full = gitProbe(['rev-parse', `${sha}^{commit}`]).out;
  if (full && graftList().includes(full))
    return { state: 'grafted', why: `${full} is a GRAFT BOUNDARY in this store — git has no parent for it, so \`git show\` renders the whole tree as additions and both the path leg and the diff grep would pass over a patch nobody has` };
  for (const p of parents) {
    if (gitProbe(['cat-file', '-e', `${p}^{commit}`]).rc !== 0)
      return { state: 'missing-parent', why: `its parent ${p} is NOT in this object store, so the patch \`git show\` would render is not this commit's patch` };
  }
  if (!parents.length && walkTruncation().state !== 'complete')
    return { state: 'unknown', why: 'git reports NO parent for it while this walk is not known to be whole, so its rendered patch cannot be trusted to be its own' };
  return { state: 'intact', why: `${parents.length} parent(s) present` };
}

// THE COMPOSITE READ. Returns one of:
//   { verdict: 'ancestor' }        — 1,2,3,5 clean and merge-base said YES
//   { verdict: 'not-ancestor' }    — 1,2,3 clean and merge-base said NO. A PRODUCT claim.
//   { verdict: 'unavailable', code, sentence } — this checkout could not look.
// The reading string names ALL FOUR probes on every unavailable sentence, so a reader
// never has to guess which leg answered what.
function historyProbe(sha) {
  const ref = gitProbe(['rev-parse', '--verify', '--quiet', 'origin/main']);
  const obj = gitProbe(['cat-file', '-e', `${sha}^{commit}`]);
  let ancRc = null;
  if (ref.rc === 0 && obj.rc === 0) ancRc = gitProbe(['merge-base', '--is-ancestor', sha, 'origin/main']).rc;
  const walk = walkTruncation();
  const reading = () => `[ref: origin/main ${ref.rc === 0 ? `resolves to ${ref.out.slice(0, 12)}` : `DOES NOT RESOLVE (rev-parse --verify rc ${ref.rc})`}`
    + ` | object: ${obj.rc === 0 ? 'present' : `ABSENT (cat-file -e rc ${obj.rc})`}`
    + ` | walk: ${walk.state} (${walk.reason})`
    + ` | ancestry: ${ancRc === null ? 'NOT RUN — an earlier probe already answered' : `merge-base --is-ancestor rc ${ancRc}`}]`;
  const unavailable = (code, why) => ({
    verdict: 'unavailable',
    code,
    sentence: `HISTORY-UNAVAILABLE: commit ${sha} — ${code}. ${why} This is a fact about THIS CHECKOUT, not about the product: nothing is claimed about whether the fix landed. ${reading()}`,
  });

  if (ref.rc !== 0)
    return unavailable('MISSING-REF', 'There is no `origin/main` in this checkout to compare anything against — the shape a pull_request checkout leaves behind, where only refs/remotes/pull/N/merge was ever fetched.');
  if (obj.rc !== 0)
    return unavailable('MISSING-OBJECT', 'The commit object itself is not in this store — the shape `actions/checkout@v4` leaves behind on a push, where origin/main resolves and the history behind it was never fetched.');
  if (ancRc !== 0 && ancRc !== 1)
    return unavailable('ANCESTRY-UNREADABLE', `\`git merge-base --is-ancestor\` exited ${ancRc}, which is git refusing to answer rather than answering no.`);

  if (ancRc === 1) {
    // rc 1 IS AMBIGUOUS (see (A)). Only a walk known to be WHOLE makes it a product claim.
    if (walk.state !== 'complete')
      return unavailable(walk.state === 'truncated' ? 'WALK-TRUNCATED' : 'WALK-UNKNOWN',
        `merge-base answered "no", but this walk is ${walk.state}, so "no" is what a truncated history says about a commit it cannot reach — measured: a grafted depth-1 clone answers rc 1 for a commit a full clone confirms IS an ancestor.`);
    // The cheap corroborator, measured: after an rc-1 answer, `git merge-base <sha>
    // origin/main` prints a real sha for a genuinely non-ancestor tip and NOTHING for a
    // walk that could not reach far enough. Fails closed on "nothing".
    const mb = gitProbe(['merge-base', sha, 'origin/main']);
    if (mb.rc !== 0 || !mb.out)
      return unavailable('NO-MERGE-BASE',
        `merge-base answered "no" and \`git merge-base ${sha} origin/main\` then found NO common ancestor at all (rc ${mb.rc}). A commit genuinely off main still shares a fork point with it; sharing none means this store cannot place the commit, not that the product lacks the fix.`);
    return { verdict: 'not-ancestor' };
  }

  // An ancestor — but a grafted commit's PATCH is not its patch. Probe 5, or the false
  // FAIL is fixed and a false PASS is left standing in its place.
  const integ = diffIntegrity(sha);
  if (integ.state !== 'intact')
    return unavailable('DIFF-UNVERIFIABLE',
      `It IS an ancestor of origin/main, but its DIFF cannot be verified here: ${integ.why}. Certifying the registered path and grep against that patch would be a clause-(b) PASS over bytes this checkout does not have.`);
  return { verdict: 'ancestor' };
}

function verifyCommit(d, commit, fixture, problems, unavailable) {
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

  const probe = historyProbe(commit);
  if (probe.verdict === 'unavailable') { unavailable.push(probe.sentence); return null; }
  // The ONE honest product sentence, reached only with all four probes clean.
  if (probe.verdict === 'not-ancestor') { problems.push(`commit ${commit} is not an ancestor of origin/main`); return null; }

  let paths, body;
  try { paths = gitDiffPaths(commit); body = gitDiffBody(commit); }
  catch (e) {
    // RECLASSIFIED (wave 29). This catch used to throw `Infra`, which unwinds to the
    // top-level handler and prints `INFRA-FAULT a=UNKNOWN b=UNKNOWN c=UNKNOWN` at exit 2
    // — a PROCESS-level fault for a PER-DEFECT condition, and exactly the shape
    // cch-w28-s1's clause-(a) tripwire is armed to red. A commit whose patch this store
    // cannot render is the same fact as a commit this store cannot reach: b's own letter,
    // at exit 1, with clauses (a) and (c) still evaluated and still printed.
    unavailable.push(`HISTORY-UNAVAILABLE: commit ${commit} — DIFF-UNREADABLE. \`git show\` could not render its patch here (${String(e.message).slice(0, 90)}). This is a fact about THIS CHECKOUT, not about the product: nothing is claimed about whether the fix landed.`);
    return null;
  }

  const missing = (d.diff.paths || []).filter((p) => !paths.includes(p));
  if (missing.length) problems.push(`commit ${commit} does not touch ${missing.join(', ')} — the registered fix is not in this diff`);
  if (!d.diff.grep.test(body)) problems.push(`commit ${commit}'s diff never matches ${d.diff.grep} — verified by DIFF, never by subject line`);
  return `diff ${paths.length} file(s)`;
}

// ---------------------------------------------------------------------------
// RUNG 2 — THE THREE STRUCTURAL LEGS
//
// No YAML dependency (this file is spawned as a bare `node <path>`, with no package
// resolution to lean on), so the workflow is read with a deliberately narrow
// line parser over the `jobs:` block ALONE. Narrow is the point: everything it can
// see is a key at a KNOWN indent, so a `#` comment — at any indent, carrying any
// text — is structurally unreachable to it. That is the property leg 1 above lost.

// Parse `jobs:` into { <key>: { name, if, needs: [], matrix: bool } }.
// Both `needs:` spellings are handled, because both are legal and this repo uses one
// of each: the inline flow sequence (`needs: [a, b]`) and the block sequence
// (`needs:` then `  - a`). A bare scalar (`needs: changes`) is legal too.
function parseWorkflowJobs(src) {
  const lines = src.split('\n');
  let i = lines.findIndex((l) => /^jobs:\s*$/.test(l));
  if (i === -1) return null;
  const jobs = {};
  let cur = null;
  for (i += 1; i < lines.length; i++) {
    const line = lines[i];
    if (/^\S/.test(line)) break;                    // left the jobs: block
    const jobKey = line.match(/^ {2}([A-Za-z0-9_.-]+):\s*$/);
    if (jobKey) {
      cur = { key: jobKey[1], name: null, if: null, needs: [], matrix: false };
      jobs[cur.key] = cur;
      continue;
    }
    if (!cur) continue;
    // Only keys at EXACTLY four spaces are job-level keys. A comment line starts
    // with `#` after its indent and matches none of these patterns; a `run: |`
    // body lives at six spaces or deeper and cannot reach here either.
    const key = line.match(/^ {4}([A-Za-z0-9_-]+):(.*)$/);
    if (key) {
      const [, k, restRaw] = key;
      const rest = restRaw.replace(/\s+#.*$/, '').trim();
      if (k === 'name') cur.name = rest.replace(/^['"]|['"]$/g, '');
      else if (k === 'if') cur.if = rest;
      else if (k === 'strategy') cur.strategyAt = i;
      else if (k === 'needs') {
        const flow = rest.match(/^\[(.*)\]$/);
        if (flow) {
          cur.needs = flow[1].split(',').map((s) => s.trim().replace(/^['"]|['"]$/g, '')).filter(Boolean);
        } else if (rest) {
          cur.needs = [rest.replace(/^['"]|['"]$/g, '')];
        } else {
          for (let j = i + 1; j < lines.length; j++) {
            const item = lines[j].match(/^ {6}-\s*(.+?)\s*$/);
            if (!item) break;
            cur.needs.push(item[1].replace(/^['"]|['"]$/g, ''));
          }
        }
      }
      continue;
    }
    // `matrix:` nested under this job's `strategy:`
    if (cur.strategyAt !== undefined && /^ {6}matrix:\s*$/.test(line)) cur.matrix = true;
  }
  return jobs;
}

// A job's rendered check-run CONTEXT is its `name:` when it has one and the job key
// otherwise — and that equivalence holds ONLY for an unmatrixed job. A matrixed job
// publishes `name (27.0, 1.18.1)`, or the literal uninterpolated `${{ matrix.x }}` if
// it never started (honest-gates D20), so neither is a name anything can require.
const renderedContext = (job) => job.name || job.key;

// Leg A. Memoised, and read LAZILY: an entry whose workflow or job does not exist has
// already failed, and consulting branch protection to explain a measurement that is
// not there would replace a precise problem with a vague one.
let _requiredCache = null;
function requiredContexts(fixture) {
  if (_requiredCache) return _requiredCache;
  // FIXTURE-ONLY. A ledger fixture may stand in for branch protection exactly as
  // `landed` stands in for ancestry and `diffs` for the patch — otherwise every
  // clause-(a) fixture would inherit whatever the real branch happens to be
  // configured with today, and the clause-(a) suite would red for a clause-(b)
  // reason. It is unreachable on a live run: there is no flag for it, and `fixture`
  // is non-null only under `--ledger`.
  if (fixture && Array.isArray(fixture.requiredContexts)) {
    _requiredCache = { set: new Set(fixture.requiredContexts), branch: 'LEDGER FIXTURE', fromFixture: true };
    return _requiredCache;
  }
  const p = `${REPO}/.github/required-checks.json`;
  if (!existsSync(p))
    throw new Infra(`.github/required-checks.json does not exist under ${REPO}. Rung 2 asserts that a measurement can STOP A MERGE, and that claim is unreadable without the committed record of this branch's protection. Nothing is asserted about clause (b).`);
  let j;
  try { j = JSON.parse(readFileSync(p, 'utf8')); }
  catch (e) { throw new Infra(`.github/required-checks.json is not JSON (${String(e.message).slice(0, 90)}) — rung 2 cannot be evaluated, so nothing about clause (b) is claimed.`); }
  if (j.enforced !== true)
    throw new Infra(`.github/required-checks.json says enforced=${JSON.stringify(j.enforced)} — branch protection is NOT applied to ${j.branch || 'main'}. With no enforcing boundary, EVERY required context is decorative and "measured in CI" would certify a job nobody has to pass. REFUSING to evaluate rung 2 rather than claiming it.`);
  const checks = ((j.protection || {}).required_status_checks || {}).checks;
  if (!Array.isArray(checks))
    throw new Infra('.github/required-checks.json has no protection.required_status_checks.checks array — the required set is unreadable, so rung 2 is unevaluable.');
  _requiredCache = { set: new Set(checks.map((c) => c.context)), branch: j.branch || 'main', fromFixture: false };
  return _requiredCache;
}

// ---------------------------------------------------------------------------
// THE CLAUSE-(b) LADDER, lifted out of `main` UNCHANGED so that exactly one
// implementation serves both readers of it: the verdict path below, and
// `--ladder-only`, which reads it and claims nothing. Two copies would be two
// ladders, and the second would drift into a friendlier one.
function evaluateLadder(fixture, guardOverride, waivers) {
  const ladder = [];
  for (const d of KNOWN_DEFECTS) {
    const commit = (fixture && fixture.defectCommits && fixture.defectCommits[d.id] !== undefined)
      ? fixture.defectCommits[d.id] : d.commit;
    const problems = [];
    const notes = [];
    // A THIRD BUCKET, and the whole point of it is that it is NOT `problems`. A problem
    // is a claim about the PRODUCT; an unavailable is a claim about THIS CHECKOUT. Fold
    // them together and the instrument is back to reporting defect-shaped prose for a
    // condition that is only "I could not look".
    const unavailable = [];

    if (!commit) problems.push('NO COMMIT — defect is known and unlanded');
    else {
      // The note may claim "verified" ONLY if verifyCommit raised no problem of its
      // own. Printing `verified by ancestry + diff` beside a diff mismatch would be a
      // success line over a read that failed — this file's whole subject.
      const before = problems.length;
      const how = verifyCommit(d, commit, fixture, problems, unavailable);
      if (how && problems.length === before) notes.push(`commit ${commit} verified by ancestry + ${how}`);
      else if (how) notes.push(`commit ${commit} IS an ancestor of origin/main, but its DIFF did not verify — see below; nothing about this fix is certified`);
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
          // is owned by `hg-overflow-guard-refusal-exits-1` (CLOSED — its
          // die() paths are paid; the outer main().catch residual is not).
          throw new Infra(`guard ${d.guard} exited 2 for ${d.id} — that is a REFUSAL to measure (its own infra code), not a defect claim. Nothing is asserted about ${d.id}. The guard-side vocabulary fix was owned by hg-overflow-guard-refusal-exits-1 (closed; its main().catch residual is recorded at the comment above this throw), which this file names rather than duplicates.`);
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
      // Scoped to THIS rung's own problems: a commit-verification failure above must
      // not suppress the measurement report, or the output would go silent about the
      // very leg it did check.
      const mBefore = problems.length;
      const missing = d.measured_by.filter((p) => !existsSync(`${REPO}/${p}`));
      if (missing.length === d.measured_by.length)
        problems.push(`measured_by names ${missing.join(', ')} and NONE of them exist — the measurement is asserted, not present`);
      const { workflow, job } = d.measured_in_ci;
      const wf = `${REPO}/${workflow}`;
      let aggregator = null;
      let required = null;
      if (!existsSync(wf)) problems.push(`measured_in_ci names ${workflow}, which does not exist`);
      else {
        const jobs = parseWorkflowJobs(readFileSync(wf, 'utf8'));
        if (!jobs) problems.push(`${workflow} has no \`jobs:\` block — it is not a workflow this measurement can live in`);
        else if (!jobs[job])
          problems.push(`${workflow} has no job \`${job}\` — the CI leg of this measurement does not exist`);
        else {
          // ── Leg B: the aggregator, found by STRUCTURE. Not by name, not by a
          // convention, and never by a comment: the job that `needs:` this one AND
          // carries `if: always()` is the only job whose check run can be red when
          // this one is red. That is what "enforced" has to mean.
          const candidates = Object.values(jobs).filter(
            (j) => j.needs.includes(job) && /^always\(\)$/.test(String(j.if || '').trim()));
          const matrixed = candidates.filter((j) => j.matrix);
          const usable = candidates.filter((j) => !j.matrix);
          if (!usable.length) {
            problems.push(matrixed.length
              ? `${workflow}: the only job(s) aggregating \`${job}\` (${matrixed.map((j) => j.key).join(', ')}) carry a \`strategy.matrix\`, so their published check-run name is not their \`name:\` — it gains the matrix tuple, or the uninterpolated \`\${{ matrix.… }}\` template when the job never starts. A matrixed job cannot be a required context (D20), so \`${job}\` has no enforceable aggregator: rung 3.`
              : `${workflow}: NO job both \`needs:\` \`${job}\` and carries \`if: always()\`. Without such an aggregator the only check runs over \`${job}\` are \`${job}\` itself — which is matrixed and/or skippable — so nothing publishes a requirable name for it. This measurement cannot stop a merge: rung 3.`);
            rung = 3;
          } else {
            // ── Leg C: is that aggregator actually REQUIRED on this branch?
            //
            // More than one always()-aggregator over the same job is legal YAML, and
            // the question rung 2 asks is "does ANY of them stop a merge" — so the
            // registered one wins. Picking the first candidate blindly would have
            // reported rung 3 over a job that IS enforced, purely on job ordering.
            required = requiredContexts(fixture);
            const enforcedCandidate = usable.find((j) => required.set.has(renderedContext(j)));
            aggregator = renderedContext(enforcedCandidate || usable[0]);
            if (!required.set.has(aggregator)) {
              problems.push(`${workflow} job \`${job}\` is aggregated by ${usable.map((j) => `"${renderedContext(j)}"`).join(', ')}, and ${usable.length > 1 ? 'NONE of those names is' : `"${aggregator}" is NOT`} a required status check on ${required.branch} (required today: ${[...required.set].join(', ') || 'NONE'}). The job can go red and the PR still merges, so this measurement enforces nothing: rung 3, not rung 2. Register the name — cch-w9-register-console-and-cloud-gates owns that, via scripts/required-checks-apply.sh. Softening this leg would reinstate exactly the defect it removes.`);
              rung = 3;
            }
          }
        }
      }
      if (problems.length === mBefore)
        notes.push(`MEASURED-ELSEWHERE by ${d.measured_by.filter((p) => existsSync(`${REPO}/${p}`)).join(', ')}, run by ${workflow} job \`${job}\`, whose failure is enforced through the REQUIRED status check "${aggregator}" on ${required.branch}${required.fromFixture ? ' (REQUIRED-CONTEXT SET SUPPLIED BY LEDGER FIXTURE — not this branch\'s real protection)' : ' (READ FROM THE COMMITTED .github/required-checks.json, not from live GitHub — this program makes no network call; `scripts/required-checks-verify.sh` is what compares that record against the branch)'}. THIS RUN DID NOT EXECUTE IT — it verified that the test file exists, that the CI job exists, and that a merge cannot pass while that job is red.`);
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

    ladder.push({ id: d.id, rung, problems, notes, unavailable, stubbed, waived });
  }
  return ladder;
}

// The ladder's rendering, shared for the same reason the ladder is: a reading that
// printed a DIFFERENT shape from the verdict path would be a second dialect of the
// same fact, and the two would disagree the first time one of them was edited.
const RUNG_MARK = { 1: '✓', 2: '◐', 3: '·' };
function pushLadder(L, ladder) {
  for (const e of ladder) {
    const bad = e.problems.length > 0;
    // `?` is its own mark, deliberately not `✗`. An entry this checkout could not read is
    // not an entry that failed, and a reader scanning marks must be able to see the
    // difference without reading a sentence.
    const mark = bad ? '✗' : (e.unavailable.length ? '?' : RUNG_MARK[e.rung] || '·');
    L.push(`  ${mark} ${e.id}  (rung ${e.rung}${e.rung === 2 ? ' — MEASURED-ELSEWHERE' : ''})`);
    e.notes.forEach((n) => L.push(`        ${n}`));
    e.unavailable.forEach((u) => L.push(`        ${u}`));
    e.problems.forEach((p) => L.push(`        ${p}`));
  }
}

// ---------------------------------------------------------------------------
// `--ladder-only` — A READING. It evaluates clause (b)'s ladder and NOTHING else:
// no roster fetch (clause a), no gate resolution (bucket c), no successor of any
// kind. It therefore prints no `VERDICT:` line and emits neither SEAL nor NO-SEAL,
// and its token spells out which letters were never read. See the D83 boundary in
// the header: manufacturing a successor to force a verdict is forbidden; reading the
// ladder without claiming one is exactly how you avoid having to.
function ladderOnly(fixture, guardOverride, stamp, head) {
  const L = [];
  const waivers = new Set(fixture ? (fixture.unmeasuredWaivers || []) : []);
  const ladder = evaluateLadder(fixture, guardOverride, waivers);

  L.push(`=== SEAL PREDICATE — LADDER-ONLY READING, NO VERDICT — epic ${EPIC} ===`);
  L.push(`read at ${stamp}  (repo ${REPO}${head ? ` @ ${head}` : ''})`);
  L.push('This run evaluates CLAUSE (b) ONLY. Clause (a) and bucket (c) were NOT READ:');
  L.push('no roster was fetched, no successor was named, no gate was resolved. Nothing');
  L.push('here is a seal verdict, and this output carries no token that could be quoted');
  L.push('as one.');
  L.push('');
  L.push(`CLAUSE (b) known user-facing defects — ${KNOWN_DEFECTS.length} registered`);
  pushLadder(L, ladder);
  L.push('');

  const byRung = { 1: 0, 2: 0, 3: 0 };
  for (const e of ladder) byRung[e.rung] = (byRung[e.rung] || 0) + 1;
  // An entry this checkout could not READ is not one it read and found clean — the same
  // sentence wave 27 wrote for the roster and the root, pointed at clause (b)'s history.
  const clean = ladder.filter((e) => !e.problems.length && !e.unavailable.length).length;
  const flagged = ladder.filter((e) => e.problems.length);
  const unread = ladder.filter((e) => e.unavailable.length);

  L.push(`READING: rung1=${byRung[1]} (measured HERE by a committed guard)  rung2=${byRung[2]} (MEASURED-ELSEWHERE)  rung3=${byRung[3]} (neither)`);
  L.push(`         ${clean} of ${ladder.length} entr(ies) read clean; ${flagged.length} carr(y) a stated problem${flagged.length ? `: ${flagged.map((e) => e.id).join(', ')}` : ''}`);
  L.push(`         ${unread.length} of ${ladder.length} entr(ies) could not be read from THIS CHECKOUT${unread.length ? `: ${unread.map((e) => e.id).join(', ')}. Their history is absent here; no claim is made about the product for any of them` : ' — every registered commit was reachable and its patch renderable here'}`);
  L.push('');
  L.push('WHAT THIS READING IS NOT:');
  L.push('  1. NOT a verdict. A rung-3 entry above is a READING, not a failure of this');
  L.push('     run — which is why this exits 0 with rung-3 entries present. An instrument');
  L.push('     that reads and then exits 1 gets wired into CI as a gate, and a gate is a');
  L.push('     verdict again. The only non-zero here is an INFRA FAULT: nothing read,');
  L.push('     nothing reported.');
  L.push('  2. NOT clause (a) and NOT bucket (c). Both are printed a=NOT-READ c=NOT-READ');
  L.push('     below, in the token itself, so no reader can quote this run as the seal.');
  L.push('     D83 forbids MANUFACTURING A SUCCESSOR TO FORCE A VERDICT; it does not');
  L.push('     forbid reading the ladder without claiming one. This run manufactures');
  L.push('     nothing — it names no successor at all.');
  L.push('  3. NOT a read of the live branch. Rung 2 is Leg A + Leg B + Leg C over the');
  L.push('     COMMITTED RECORD ONLY — .github/required-checks.json and the workflow file');
  L.push('     under --repo. This program makes no network call BY DESIGN. So if a');
  L.push('     4-context spec is committed but the PUT never landed, or was reverted,');
  L.push('     every line above still says rung 2 while NOTHING enforces it.');
  L.push('     `scripts/required-checks-verify.sh` is the only instrument that catches');
  L.push('     that drift, and this one names it rather than covering for it.');
  L.push('  4. NOT a statement about the Console gate. Every rung-2 entry in the register');
  L.push('     names .github/workflows/cloud.yml job `test`; no entry references');
  L.push('     console-harness.yml. Registering the Console gate moves no line above.');
  L.push('     Clause (b) is blind to it, and this reading will not let anyone say');
  L.push('     otherwise.');
  L.push('  5. NOT a claim that the history it needed was HERE. `b-unavailable=N/M` in the');
  L.push('     token counts the register entries whose commit this checkout could not');
  L.push('     reach or whose patch it could not render — a depth-1 CI checkout reads');
  L.push('     M/M and says so, instead of printing M sentences about a product it never');
  L.push('     looked at. THIS PATH STILL EXITS 0 (charter D335): the condition is carried');
  L.push('     in LETTERS, never in an exit code. An instrument that reads and then exits');
  L.push('     1 gets wired in as a gate, and `console-unit` checks out at');
  L.push('     actions/checkout@v4\'s depth-1 default on every push to main — exit-1-on-read');
  L.push('     would leave the BLOCKING Console gate permanently red for an environment');
  L.push('     fact. The VERDICT path is where an unreadable history costs an exit code.');
  // `b-unavailable=` sits IMMEDIATELY AFTER `b-clean=` and before `a=`: readers (and this
  // file's own tests) anchor on the token's HEAD (`^… LADDER-ONLY b-rungs=…`) and on its
  // TAIL (`mode=live repo=… head=…`), so a new field belongs between the two b-fields and
  // nowhere else.
  L.push(`VERDICT-TOKEN: SEAL-PREDICATE LADDER-ONLY b-rungs=rung1:${byRung[1]},rung2:${byRung[2]},rung3:${byRung[3]} b-clean=${clean}/${ladder.length} b-unavailable=${unread.length}/${ladder.length} a=NOT-READ c=NOT-READ epic=${EPIC} mode=${fixture ? 'fixture' : 'live'} repo=${REPO} head=${head || 'NOT-READ'}`);
  console.log(L.join('\n'));
  return 0;
}

// ---------------------------------------------------------------------------
// PROVENANCE — IS `--repo` A ROOT THIS PROGRAM CAN READ AT ALL?
//
// FIVE clause-(b) legs resolve against REPO — ancestry, guard existence, `measured_by`,
// the workflow file, and the Leg A/B/C aggregator — and every one of them reports its
// own miss as a DEFECT SENTENCE. Point this program at a `git archive` extraction and
// it prints, verbatim and six times over, `commit <sha> is not an ancestor of
// origin/main`. Not one of those sentences is true: the tree simply has no `.git`, and
// the ancestry `catch` at the top of `verifyCommit` swallows not-a-git-repo, no
// origin/main, a shallow clone and an unknown sha into one identical claim about the
// PRODUCT. Measured on a real extraction before this guard existed: six ✗ rows,
// rung1=2 rung2=4 rung3=0, exit 0. Two consecutive waves quoted output of that shape
// as this epic's primary finding.
//
// A wrong root is an INFRA FAULT and never a verdict — nothing was measured, so nothing
// is claimed. Exactly the discipline Leg A already applies one clause over when
// `enforced !== true`.
//
// TWO LEGS, each the narrowest read that can tell "wrong tree" from "real gap":
//
//   LEG 1, ALWAYS — `.github/workflows/cloud.yml` exists under REPO. It is the landmark
//     every rung-2 entry in the register names, so a root without it cannot answer the
//     question rung 2 asks; `--repo <empty dir>` is a wrong root, not an unmeasured
//     defect. `.github/required-checks.json` is deliberately NOT also required here:
//     Leg A already refuses on its absence with a MORE precise sentence, and demanding
//     it up here would replace that precision with this blunter one.
//
//   LEG 2, LIVE PATH ONLY — REPO is the top level of a git work tree. Only the live
//     path asserts ANCESTRY; the fixture path stands `landed` in for it, and this
//     file's own rung-2 leg suite legitimately drives a SYNTHETIC, non-git root
//     through the fixture path. Requiring a work tree on both paths would red twelve
//     tests that are measuring something else entirely — and relaxing the refusal to
//     save them would put the defect straight back.
//
//     `git rev-parse --show-toplevel`, NEVER a `.git` stat. In a LINKED WORKTREE `.git`
//     is a ~75-byte FILE, so `statSync('.git').isDirectory()` refuses every worktree —
//     and this epic runs nearly all of its proofs from worktrees, which would make the
//     fix itself the next instrument manufacturing false findings. Both sides are
//     realpath'd because `/tmp` is a symlink to `/private/tmp` on macOS and a raw
//     string compare would refuse a correct root there.
//
// Returns the resolved HEAD sha on the live path (for the verdict token's `head=`), or
// null on the fixture path, where there is no tree to name.
function assertReadableRepoRoot(ledgerPath) {
  if (!existsSync(`${REPO}/.github/workflows/cloud.yml`))
    throw new Infra(
      `--repo ${REPO} carries no .github/workflows/cloud.yml, so it is not a checkout of this repository. `
      + 'Five clause-(b) legs resolve their paths under --repo and each reports its own miss as a defect sentence, '
      + 'so continuing from here would print INVENTED findings — "commit … is not an ancestor of origin/main", '
      + '"guard … is NOT COMMITTED", "measured_by names … and NONE of them exist" — for a pure wrong-root '
      + 'condition. Nothing is asserted about clause (b).',
      'UNREADABLE-REPO-ROOT');

  if (ledgerPath) return null;

  let top = null;
  try {
    top = execFileSync('git', ['-C', REPO, 'rev-parse', '--show-toplevel'],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch { top = null; }
  if (!top || realpathSync(top) !== realpathSync(REPO))
    throw new Infra(
      `--repo ${REPO} is not the top level of a git work tree (${top ? `git reports the top level as ${top}` : 'git could not resolve one'}). `
      + `A LIVE run asserts that ${KNOWN_DEFECTS.length} registered commits are ANCESTORS of origin/main, and that read is a git `
      + 'operation: without a work tree the ancestry check fails for every entry and prints "commit … is not an '
      + 'ancestor of origin/main" — a claim about the PRODUCT derived from a fact about the DIRECTORY. Measured on '
      + 'a `git archive` extraction: six such sentences, all false. Nothing is asserted about clause (b). A ledger '
      + 'fixture (--ledger) stands `landed` in for ancestry and is not subject to this leg.',
      'REPO-NOT-A-GIT-WORK-TREE');

  try {
    return execFileSync('git', ['-C', REPO, 'rev-parse', '--short', 'HEAD'],
      { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch { return null; }
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

  // BEFORE any clause, any refusal and any roster: is the tree under --repo one this
  // program can read at all? A wrong root is an infra fault, not a finding.
  const HEAD = assertReadableRepoRoot(ledgerPath);

  L.push(`=== SEAL PREDICATE — epic ${EPIC} ===`);
  L.push(`read at ${STAMP}${fixture ? '  (LEDGER FIXTURE — not live)' : '  (live ledger)'}  (repo ${REPO}${HEAD ? ` @ ${HEAD}` : ''})`);

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

  // ── `--ladder-only` diverts HERE: after R1 and R0 (which protect clause (b)
  // itself — an empty register certifies nothing, and a stubbed guard on a live run
  // certifies a stub), and BEFORE every successor refusal below. Those four refusals
  // exist to protect a VERDICT, and a reading claims none, so requiring a successor
  // to read the ladder is what made the ladder unreadable for four waves.
  if (LADDER_ONLY) return ladderOnly(fixture, guardOverride, STAMP, HEAD);

  // R7 — BUCKET (c) HAS NO CARDINALITY FLOOR EITHER. This is R1 and the EMPTY-ROSTER
  // floor pointed at the third population. With `PERMANENT_HUMAN_GATES = {}` the
  // BUCKET (c) section prints NOTHING AT ALL, `gateMissing` is the empty filter of an
  // empty list, and the token still reads `c=PASS` — a clause certified over zero rows.
  // Placed AFTER the `--ladder-only` divert on purpose: a reading never evaluates bucket
  // (c) and prints `c=NOT-READ` in its own letters, so a floor on the population it
  // deliberately does not read would refuse a run that claims nothing about it.
  if (Object.keys(PERMANENT_HUMAN_GATES).length === 0)
    throw new Refusal('EMPTY-GATE-TABLE',
      'PERMANENT_HUMAN_GATES is empty — bucket (c) would print no row at all and still certify c=PASS over zero gates. The bucket exists to DISCLOSE the rows no commit can ever close; disclosing none of them is not the same as there being none, and an unrun clause is not a passed clause.');

  // Trimmed BEFORE R4 compares it: `--successor " cloud-console-hardening-epic"` must
  // not slip past the self-successor refusal on a space.
  const SUCCESSOR_RAW = arg('--successor') || (fixture ? fixture.successor : null) || null;
  if (typeof SUCCESSOR_RAW !== 'string' || SUCCESSOR_RAW.trim() === '')
    throw new Refusal('NO-SUCCESSOR',
      `no successor named (--successor <id>, --successor ${TERMINAL}, or \`successor\` in the ledger fixture). Clause (a) certifies that residue has a forwarding address; with none there is nothing to forward TO, and with zero live rows the absence would otherwise cost nothing and seal.`);

  const SUCCESSOR = SUCCESSOR_RAW.trim();

  // R4 — forwarding to yourself is not forwarding. `forwarded` is the SUCCESSOR's own
  // roster, so a successor equal to the epic makes clause (a) structurally unfailable.
  if (SUCCESSOR === EPIC)
    throw new Refusal('SELF-SUCCESSOR',
      `the successor offered is the epic itself (${EPIC}). Forwarding to yourself is not forwarding: the forwarded set is fetchRoster(successor), which for the epic's own id contains every live row by construction, so clause (a) could never fail. Measured before this refusal existed: 83 live rows -> forwarded 79, orphans 0, a=PASS.`);

  const terminal = SUCCESSOR === TERMINAL;

  if (!terminal) {
    // The epic is passed in so R6 can walk the successor's parent chain: a successor
    // is legitimate only if it is OUTSIDE the epic it forwards out of.
    const resolution = resolveTask(SUCCESSOR, fixture, { epic: EPIC });
    if (!resolution.ok) {
      const code = resolution.code || 'UNRESOLVABLE-SUCCESSOR';
      const head = {
        'UNRESOLVABLE-SUCCESSOR': 'does not resolve to a published task',
        'DEAD-SUCCESSOR': 'resolves to a published task that is NOT LIVE',
        'SUCCESSOR-INSIDE-EPIC': `resolves to a live published task that is INSIDE ${EPIC}`,
      }[code];
      throw new Refusal(code,
        `the id offered as successor ${head} (${resolution.why}). Rejected id: ${SUCCESSOR}. It is NOT printed as a forwarding address, because it is not one.`);
    }
  }

  // ── from here the successor is real (or TERMINAL), and may be named ─────────
  const children = fixture ? fixture.children : fetchRoster(EPIC);
  if (!Array.isArray(children)) throw new Infra('roster is not an array of documents', 'ROSTER-NOT-AN-ARRAY');

  // ── CLAUSE (a)'s CARDINALITY FLOOR — THE FAIL-OPEN, AND IT IS THE WORSE HALF.
  //
  // Everything below counts residue WITHIN the roster, and nothing anywhere asked
  // whether the roster is a roster at all. With `ok = orphans.length === 0 && …`, an
  // epic id that resolves to NOTHING scores a perfect clause (a) by having no rows left
  // to fail on. Measured before this refusal existed: `--epic
  // cloud-console-hardening-epicc` — one doubled letter — exited 0 with `VERDICT: SEAL`,
  // `a=PASS b=PASS c=PASS orphans=0 … mode=live`, no stub and no waiver, and printed its
  // own fabrication in the SCOPE paragraph: "Sealed 0 children of
  // cloud-console-hardening-epicc".
  //
  // BUCKET (c) CANNOT STOP IT, which is why this has to be its own refusal: the three
  // permanent human gates are fetched by hardcoded `_id` INDEPENDENTLY of --epic, so
  // they resolve for any epic string whatsoever. The run even prints
  // `in-epic-roster=false` on all three and acts on none of it.
  //
  // This is R1 (EMPTY-DEFECT-REGISTER) applied to the population it was written for and
  // never pointed at: an unrun clause is not a passed clause. Clause (b) has had that
  // floor since wave 6; clause (a) has never had one.
  //
  // LIVE ONLY. A ledger fixture may legitimately carry any roster it likes — the fixture
  // path certifies this program's own logic, never an epic — and applying the floor
  // there would turn a mutation control into a refusal.
  //
  // THE FLOOR IS ONE, NOT SOME LARGER "implausibly short" NUMBER. Any N above one is a
  // threshold nobody can derive, and a bar re-derived after seeing a result is not a
  // bar. Zero-versus-nonzero is the only cardinality claim this program can defend from
  // its own inputs.
  if (!fixture && children.length === 0)
    throw new Refusal('EMPTY-ROSTER',
      `the live roster of ${EPIC} is EMPTY — zero children of any lifecycle_status. Clause (a) certifies that residue has a forwarding address, and over zero rows it cannot fail: orphans=0 is arithmetic, not evidence. An epic with no children is either a typo in --epic or a ledger this program could not read, and both are indistinguishable from a clean sweep once the count reaches the verdict line. Bucket (c) does not catch it either: the permanent human gates are fetched by hardcoded id INDEPENDENTLY of --epic, so they resolve for any epic string at all. An unrun clause is not a passed clause.`,
      'after the roster read, before any clause was evaluated');

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
  const ladder = evaluateLadder(fixture, guardOverride, waivers);
  const defectFails = ladder.filter((e) => e.problems.length);
  // PER-DEFECT, NEVER PROCESS-LEVEL (charter D335). An entry whose history this checkout
  // could not read blocks the seal — an unrun clause is not a passed clause — but it does
  // so as b's OWN LETTER at exit 1, with clauses (a) and (c) still evaluated and still
  // printed. A process-level exit-2 INFRA-FAULT would print `a=UNKNOWN b=UNKNOWN
  // c=UNKNOWN` and throw away two clause readings that were perfectly available.
  const defectUnread = ladder.filter((e) => e.unavailable.length);

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
  pushLadder(L, ladder);
  L.push('');

  const gateMissing = gateReport.filter((g) => !g.resolved);
  const ok = orphans.length === 0 && defectFails.length === 0 && gateMissing.length === 0
    && defectUnread.length === 0;
  // FAIL outranks HISTORY-UNAVAILABLE: a defect this run DID measure and found unpaid is
  // a louder fact than one it could not look at, and `b-unavailable=` below carries the
  // second condition either way, so nothing is hidden by the precedence.
  const bLetter = defectFails.length ? 'FAIL' : (defectUnread.length ? 'HISTORY-UNAVAILABLE' : 'PASS');
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
    if (defectUnread.length) {
      L.push(`  - ${defectUnread.length} known user-facing defect(s) could NOT BE READ from this checkout (clause b, HISTORY-UNAVAILABLE): ${defectUnread.map((e) => e.id).join(', ')}`);
      L.push('    THIS IS NOT A DEFECT CLAIM. Their history is absent HERE — a depth-1 or');
      L.push('    pull_request checkout has no origin/main history to compare against — so this');
      L.push('    run makes no statement about whether those fixes landed. Re-run from a');
      L.push('    checkout with full history (`git fetch --unshallow`) to get an answer.');
    }
    if (gateMissing.length) L.push(`  - ${gateMissing.length} hardcoded human gate(s) failed to resolve (bucket c)`);
    L.push('  This is an acceptable, pre-committed outcome. The named successor is the honest handoff.');
  }
  // EVERY VERDICT LINE NAMES ITS POPULATION. `orphans=0` is a ratio with an unstated
  // denominator: it reads identically over a 123-row roster with every row forwarded
  // and over a roster of nobody. `roster=` states the denominator; `repo=`/`head=` state
  // the tree the clause-(b) legs actually read, which this predicate was proven to be
  // sensitive to (the same command printed b=FAIL from a stale primary checkout and
  // b=PASS from a clean worktree). No future wave can quote a seal run without also
  // quoting the tree and the population it was taken from.
  // `b-unavailable=` is APPENDED AFTER `head=` and ONLY WHEN NON-ZERO. Appended, because
  // the clause letters' run (`a=… b=… c=… orphans=…`) is anchored by readers and by this
  // file's own tests. Only when non-zero, because a run over a checkout with whole history
  // must stay BYTE-IDENTICAL to the token this predicate emitted before the discrimination
  // existed — a new field on every green would make every previously-quoted token
  // unmatchable for a condition that did not occur.
  L.push(`VERDICT-TOKEN: SEAL-PREDICATE ${ok ? 'SEAL' : 'NO-SEAL'} a=${orphans.length === 0 ? 'PASS' : 'FAIL'} b=${bLetter} c=${gateMissing.length === 0 ? 'PASS' : 'FAIL'} orphans=${orphans.length} considering=${considering.length} successor=${SUCCESSOR} epic=${EPIC} mode=${fixture ? 'fixture' : 'live'} stubbed=${stubbedCount} waived=${waivedCount} roster=${children.length} repo=${REPO} head=${HEAD || 'NOT-READ'}${defectUnread.length ? ` b-unavailable=${defectUnread.length}/${ladder.length}` : ''}`);
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
    // A refusal is NOT a verdict — nothing was measured, so nothing about SEAL or
    // NO-SEAL is claimed. It used to exit 1, the SAME code `main()` returns for a real
    // measured NO-SEAL, which made "checked and found wanting" and "declined to check
    // anything (e.g. an empty roster)" indistinguishable to any caller reading the exit
    // code alone — precisely the ambiguity this module's own `Infra` branch below exists
    // to avoid for infra faults, and the ambiguity this module's own doctrine two lines
    // up rejects: "a predicate that prints an honest sentence and still exits 0 is the
    // same defect as one that lies" applies just as much to a refusal borrowing the
    // finding's exit code. Exit 3 is its own lane — distinct from 0 (SEAL), 1 (measured
    // NO-SEAL) and 2 (INFRA FAULT, an unexpected failure) — so `scripts/seal-run.sh` (and
    // any other consumer reading the exit code) can tell "REFUSED — nothing measured"
    // from a genuine measured NO-SEAL without parsing prose.
    console.log(`REFUSED at ${stamp}, ${e.stage}: ${e.message}`);
    console.log('VERDICT: NO SEAL — REFUSED');
    console.log('  Nothing was certified. This is a pre-committed outcome: a predicate that prints an');
    console.log('  honest sentence and still exits 0 is the same defect as one that lies — and exiting');
    console.log('  the SAME code as a genuine measured NO-SEAL is the same defect one code over.');
    // `repo=` is APPENDED AFTER `epic=` on both tokens below, never inserted before the
    // clause letters: readers (and this file's own tests) anchor on the
    // `a=… b=… c=… epic=…` run, and widening it in the middle breaks them for no gain.
    console.log(`VERDICT-TOKEN: SEAL-PREDICATE REFUSED reason=${e.code} a=UNEVALUATED b=UNEVALUATED c=UNEVALUATED epic=${EPIC} repo=${REPO}`);
    code = 3;
  } else {
    console.log(`INFRA FAULT at ${stamp}: ${e instanceof Infra ? e.message : `unexpected ${e.name}: ${e.message}`}`);
    console.log('  This is NOT a verdict. Nothing was measured, so nothing is claimed — the whole point');
    console.log('  of a third exit code is that this can never be read as NO SEAL.');
    console.log(`VERDICT-TOKEN: SEAL-PREDICATE INFRA-FAULT a=UNKNOWN b=UNKNOWN c=UNKNOWN epic=${EPIC} code=${(e instanceof Infra && e.code) || 'UNSPECIFIED'} repo=${REPO}`);
    code = 2;
  }
}
// `process.exitCode`, never `process.exit()`: on a PIPE stdout is async, and an
// immediate exit truncates the verdict mid-sentence — a reader piping this into
// `head`/`tee` would see a report that stops before its own VERDICT line.
process.exitCode = code;
