#!/usr/bin/env node
// THE SEAL PREDICATE FOR `truth-grip-epic`, MADE MECHANICAL.
//
//   exit 0 = the predicate HOLDS.   exit 1 = NOT YET.   exit 2 = INFRA FAULT.
//
// Three exit codes, not two, because the prior art this ports from
// (`cloud/priv/static/__preview__/seal-predicate.mjs`) lets exit 1 mean BOTH "no
// seal" and "a non-JSON HTTP response threw at :116". An exit code that carries
// two meanings is a green nobody can read, so infra gets its own code AND its
// own machine-readable verdict token (`VERDICT-TOKEN:` below).
//
// ── WHAT IT EVALUATES ───────────────────────────────────────────────────────
// Charter D94 writes the seal in ENGLISH, adjudicated by whoever types met:true
// into four evidence fields. D94 has THREE clauses — (a), (b), (c). There is no
// clause (d). The FOURTH clause printed here is (b'), D108's amendment, added
// because D94(b) ("zero claimable rows in the namespace") and D94(c) ("the root
// closes LAST") are mutually unsatisfiable as written: the root is itself a row
// in the live ready pool.
//
//   (a)  every root acceptance criterion carries evidence with a literal rerun
//        command AND A DECLARED POLARITY, adjudicated by grip itself. A
//        pass-shaped fact must satisfy admitsPassClaim; an absence-shaped fact
//        must satisfy admitsAbsenceClaim. No declared polarity = FAILS CLOSED.
//   (b)  the tgw*/truth-grip* namespace MINUS the root has zero claimable rows
//        in a live ready pool.
//   (b') the ROOT ITSELF is still claimable at check time — POOL MEMBERSHIP,
//        never `claim == null` (the root's claim is expired and it is pooled
//        anyway). Without this, root-exclusion silently deletes (c)'s only
//        enforcement, which is D108's named amendment-into-vacuity.
//   (c)  the root has not closed yet, read from the root document's own
//        lifecycle_status. A root already closed makes the predicate RED: this
//        command refuses to rubber-stamp an out-of-order seal retroactively.
//
// The word SEALED does not appear in this program's output. That is a WAVE RULE
// EXTENDING D94(c) — D94(c) itself binds four artifact classes (wave-log entry,
// Paper, memory note, commit message) and a program's stdout is none of them.
// Cited honestly rather than over-cited, per D122.
//
// ── WHY THE LENS IS A UNION AND NOT A QUERY ─────────────────────────────────
// D94(b) forbids the prior art's shape BY NAME: `fetchRoster(EPIC)` is a
// direct-`parent_id` census. Measured live while writing this file:
//
//   transitive parent_id closure from the root, root excluded ... 151
//   id-prefix tgw*/truth-grip*, fenced to _type == "task" ....... 149
//   filter[parent_id] == truth-grip-epic (the prior art) ........ 135
//   UNION ....................................................... 151
//
// Union == closure TODAY. That is a MEASUREMENT, not an invariant — one tgw*-named
// row filed outside the tree breaks it — so the union is computed, not assumed.
// The direct lens drops 16 rows, all children of `tgw1-workflow-gate-wiring`
// (itself done), one of which (`tgw2-verify-writes-back`) is OPEN and pooled: it
// reports 32 claimable where the truth is 33. The prefix lens drops two hash-id
// direct children, and unfenced it would sweep PAPERS (which carry no
// lifecycle_status and would flatter clause (b)); the fence here is both the
// `/production/task` path and a per-row `_type === "task"` assertion.
//
// ── WHY THE WALK IS EXPLICIT ────────────────────────────────────────────────
// `--limit` is SILENTLY clamped at 1000 (query_controller.ex:29 `|> min(1000)`,
// tasks_controller.ex:248) with no truncation flag, no total and no has_more —
// and `count` is the PAGE size, not the corpus size. A single-call lens sees a
// fraction of the namespace while often reporting the right claimable number,
// because open rows sort onto the first page: green for the wrong reason. So the
// row count, not the claimable count, is what is asserted. Both walks page
// explicitly, assert every full page came back at exactly the requested size,
// dedupe by id, and — for the pool — reconcile the walk against `--all` ON THE
// SET, not on the totals (see `reconcilePool`: equal totals are not an equal
// set, and the clamp guard belongs on PAGE, not on the pool size).
//
// `GET /v1/data/query/production/task` is PINNED BY NAME. `/v1/tasks` silently
// ignores `parent_id` — a real parent, an absent one and a nonexistent one all
// return the identical set.
//
// ── THE LAUNDER THIS REFUSES TO INHERIT ─────────────────────────────────────
// seal-predicate.mjs reads `r.status !== 0` at :171 AND :176 (byte-identical;
// :171 is the `--guard-cmd` branch every prior mutation proof of that file
// actually drove) and prints "the defect is still measurable at origin/main".
// `spawnSync` returns `status === null` on timeout, on signal and on ENOENT for
// a direct spawn — all three satisfy `!== 0`, so a probe that NEVER RAN is
// reported as a probe that RAN AND FAILED. That is NULL-READ laundered into
// FAILED, the exact distinction rerun.mjs:590 exists to make.
// The fix is a CLASSIFIER, not a sed: `classifyRun` maps every subprocess to one
// of four distinct words and is used by BOTH of this file's spawn sites (the
// query walk and the pool walk) plus the repo assertion.
//
//   --ledger <file>   inject a fixture instead of live HTTP (mutation proofs)
//   --repo <path>     repo root; asserted to BE a git repo (see below)
//   --server <url>    Barkpark server (default https://guerrilla.barkpark.cloud)
//
// `opts.root` IS the execution cwd since the rerun-root-is-cwd fix — rerun.mjs's
// shell() now spawns /bin/sh -c under the derived root, so the library path
// (adjudicateCriterion from any cwd) rules identically to this CLI. The chdir +
// repo assertion below stays as belt-and-braces for everything OUTSIDE runRerun
// (the git rev-parse probes, relative --ledger paths), and still refuses
// (exit 2) rather than manufacture a finding from a scratch directory.

import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { screenedRerun } from "./adjudicate.mjs";
import { admitsAbsenceClaim, admitsPassClaim } from "./rerun.mjs";
import { deriveLevel } from "./level.mjs";
import { screenCommand } from "./screen.mjs";

export const ROOT_ID = "truth-grip-epic";
export const NAMESPACE_RE = /^(tgw|truth-grip)/;
// validation.ex:31 — @claimable_statuses is ~w(open blocked). `considering` is a
// legitimate third disposition that leaves the pool without a false-done close.
export const CLAIMABLE_STATUSES = new Set(["open", "blocked"]);
// validation.ex:24 — the full ladder is open|in_progress|blocked|done|cancelled|
// considering|researching. Exactly two of those are CLOSED, and clause (c) asks
// only whether the root has closed. Reading (c) as "claimable" instead would
// make it a duplicate of (b') AND print "the root already closed" for a root
// that is merely `in_progress` — a false statement in the one program whose
// entire job is refusing false statements. The verdict is unchanged either way
// (a non-claimable root is absent from the ready pool, so (b') fails), so this
// costs no strictness and buys an honest failure line.
export const CLOSED_STATUSES = new Set(["done", "cancelled"]);
export const PAGE = 500; // deliberately under the silent 1000 clamp
export const CLAUSES = ["(a)", "(b)", "(b')", "(c)"]; // never "(d)" — D122

// ── THE FOUR-WAY CLASSIFIER ─────────────────────────────────────────────────
// One helper, four distinct words, used by every spawn site in this file.
export const RUN_CLASS = Object.freeze({
  CLEAN: "RAN-CLEAN",
  FAILED: "RAN-AND-FAILED",
  NEVER_RAN: "NEVER-RAN",
  INFRA: "INFRA-FAULT",
});

/** Classify a spawnSync result. `status === null` is NEVER-RAN, never FAILED. */
export function classifyRun(r) {
  if (!r) return { klass: RUN_CLASS.INFRA, detail: "no spawn result at all" };
  if (r.error) return { klass: RUN_CLASS.NEVER_RAN, detail: `spawn error ${r.error.code || r.error.message}` };
  if (r.status === null) return { klass: RUN_CLASS.NEVER_RAN, detail: `no exit status (timeout or signal ${r.signal || "?"})` };
  if (r.status !== 0) return { klass: RUN_CLASS.FAILED, detail: `exited ${r.status}` };
  return { klass: RUN_CLASS.CLEAN, detail: "exited 0" };
}

/** Parse JSON from a classified run. A non-JSON body is INFRA, never a red clause. */
export function classifyJson(run, body) {
  if (run.klass !== RUN_CLASS.CLEAN) return { ...run, json: null };
  try {
    return { klass: RUN_CLASS.CLEAN, detail: run.detail, json: JSON.parse(body) };
  } catch (e) {
    return { klass: RUN_CLASS.INFRA, detail: `response is not JSON (${String(e.message).slice(0, 60)})`, json: null };
  }
}

class Infra extends Error {}
const fail = (what, c) => { throw new Infra(`${what}: ${c.klass} — ${c.detail}`); };

// Bounded retry: the server 500s intermittently, and a transient 500 must be
// retried a fixed number of times and then reported LOUDLY — never caught and
// continued. A caught empty roster is a catastrophic false pass.
function runJson(file, args, what, attempts = 3) {
  let last = null;
  for (let i = 0; i < attempts; i++) {
    const r = spawnSync(file, args, { encoding: "utf8", maxBuffer: 128 * 1024 * 1024, timeout: 60000 });
    last = classifyJson(classifyRun(r), r.stdout || "");
    if (last.klass === RUN_CLASS.CLEAN && last.json && !last.json.error) return last.json;
    if (last.json && last.json.error) last = { klass: RUN_CLASS.INFRA, detail: `server said ${last.json.error.code || "error"}` };
  }
  return fail(what, last);
}

// ── LIVE READS ──────────────────────────────────────────────────────────────
const qArgs = (server, params) => {
  const a = ["-sS", "-G", `${server}/v1/data/query/production/task`];
  for (const [k, v] of params) a.push("--data-urlencode", `${k}=${v}`);
  return a;
};

/** Offset-walk the published task corpus. Returns {rows, pages, duplicates}. */
export function walkCorpus(server) {
  const rows = new Map(); const pages = []; let duplicates = 0; let offset = 0;
  for (;;) {
    const j = runJson("curl", qArgs(server, [["limit", PAGE], ["offset", offset],
      ["fields", "_id,_type,lifecycle_status,parent_id,_draft"]]), `corpus walk at offset ${offset}`);
    const docs = j.result?.documents;
    if (!Array.isArray(docs)) fail(`corpus walk at offset ${offset}`, { klass: RUN_CLASS.INFRA, detail: "no result.documents array" });
    if (docs.length > PAGE) fail(`corpus walk at offset ${offset}`, { klass: RUN_CLASS.INFRA, detail: `page returned ${docs.length} > limit ${PAGE}` });
    pages.push(docs.length);
    for (const d of docs) {
      if (d._type !== "task") fail("corpus walk", { klass: RUN_CLASS.INFRA, detail: `_type ${d._type} on the task path` });
      if (d._draft === true) continue; // published perspective only
      if (rows.has(d._id)) duplicates++;
      rows.set(d._id, d);
    }
    if (docs.length < PAGE) break;
    offset += PAGE;
    if (offset > 100000) fail("corpus walk", { klass: RUN_CLASS.INFRA, detail: "walk did not terminate" });
  }
  return { rows, pages, duplicates };
}

/** Offset-walk `bp task ready`, then reconcile against `--all`. */
export function walkPool() {
  const ids = new Set(); const pages = []; let offset = 0; let duplicates = 0;
  for (;;) {
    const j = runJson("bp", ["task", "ready", "--limit", String(PAGE), "--offset", String(offset), "-o", "json"], `ready walk at offset ${offset}`);
    const docs = j.docs || [];
    if (docs.length > PAGE) fail(`ready walk at offset ${offset}`, { klass: RUN_CLASS.INFRA, detail: `page returned ${docs.length} > limit ${PAGE}` });
    pages.push(docs.length);
    for (const d of docs) { if (ids.has(d.doc_id)) duplicates++; ids.add(d.doc_id); }
    if (docs.length < PAGE) break;
    offset += PAGE;
  }
  const all = (runJson("bp", ["task", "ready", "--all", "-o", "json"], "ready --all").docs || []).map((d) => d.doc_id);
  const allIds = new Set(all);
  const walked = pages.reduce((a, b) => a + b, 0);
  return {
    ids, pages, walked, duplicates,
    allIds, allCount: all.length, allUnique: allIds.size,
    allDuplicates: all.length - allIds.size,
  };
}

/**
 * Reconcile the offset walk against `--all` — ON THE SET, never on the totals.
 *
 * The merged version of this file asserted `allUnique === allCount` and faulted
 * on any repeated doc_id. That made the command PERMANENTLY INERT against the
 * live ledger: `bp task ready --all` serves `akbr-feedback-2026-08-epic` twice
 * (one doc_id under two row UUIDs) — the exact condition this slice's own brief
 * told the walk to DEDUPE ("dedupe on doc_id — `ls --all` carries a duplicate id
 * under two UUIDs"). Every live run exited 2 with a=UNKNOWN, so no clause was
 * ever evaluated. A probe that refuses a true claim is not strictness; it is a
 * broken instrument that FEELS like strictness because refusing looks careful.
 *
 * A repeated doc_id in the SERVER's listing is a property of the listing, not of
 * this measurement, so it is deduped, counted and PRINTED — loudly, on every
 * run, pass included. What is still fatal is a disagreement about WHICH rows the
 * two reads saw, which is the only thing that could make clause (b) read a
 * partial pool. Sizes are compared too, but sizes alone cannot catch a walk that
 * skips one row and duplicates another: two opposite errors cancel and both
 * totals AGREE. That is not hypothetical — the mutation proof for this change
 * dropped one id from the walk and both reads still totalled the same number,
 * so only the set difference reported it. So the sets are differenced, and the
 * missing/extra ids are NAMED.
 *
 * The `allCount >= 1000` guard is REPLACED, not dropped. Its purpose was "clause
 * (b) must never silently read a truncated pool", and it expressed that as a cap
 * on the POOL — which fires on every live pool today (~3010 rows on 2026-08-22)
 * even when that pool was walked correctly in 7 pages. The truncation risk lives
 * in the PAGE SIZE instead (the server clamps a
 * single request at 1000 with no flag, no total and no has_more), so the guard
 * now sits on PAGE, where a future edit raising it is what actually reintroduces
 * the hazard.
 */
export function reconcilePool(r) {
  if (!r) return { ok: false, detail: "no pool report at all" };
  if (PAGE >= 1000)
    return { ok: false, detail: `PAGE=${PAGE} is at or above the server's silent 1000 clamp — a page could come back truncated with no flag, no total and no has_more` };
  if (r.walked !== r.allCount)
    return { ok: false, detail: `offset walk returned ${r.walked} row(s), --all returned ${r.allCount} — the pool moved under the read, or one of them truncated` };
  const missing = [...r.allIds].filter((id) => !r.ids.has(id));
  const extra = [...r.ids].filter((id) => !r.allIds.has(id));
  if (missing.length || extra.length)
    return {
      ok: false,
      detail: `the two reads agree on the TOTAL (${r.walked}) but not on the SET: ` +
        `the walk misses ${missing.length} (${missing.slice(0, 5).join(", ") || "-"}), ` +
        `and carries ${extra.length} that --all does not list (${extra.slice(0, 5).join(", ") || "-"})`,
    };
  return {
    ok: true,
    detail: `${r.walked} row(s) both ways, ${r.ids.size} unique — the offset walk and --all agree on the SET, not merely the count` +
      (r.allDuplicates || r.duplicates
        ? `; ${r.allDuplicates} duplicate doc_id(s) in --all and ${r.duplicates} in the walk, DEDUPED (a repeated doc_id is the server's listing, not a partial read)`
        : "; no duplicate doc_id in either read"),
  };
}

/** The pinned direct-children query — kept ONLY to show what it would have missed. */
export function fetchDirect(server, parentId) {
  const j = runJson("curl", qArgs(server, [["filter[parent_id]", parentId], ["limit", PAGE], ["fields", "_id"]]), "direct-children query");
  return new Set((j.result?.documents || []).map((d) => d._id));
}

// ── THE LENS ────────────────────────────────────────────────────────────────
/** Three lenses over a walked corpus, plus their union. The root is excluded from all four. */
export function buildLenses(rows, rootId, directIds) {
  const kids = new Map();
  for (const r of rows.values()) {
    if (!r.parent_id) continue;
    if (!kids.has(r.parent_id)) kids.set(r.parent_id, []);
    kids.get(r.parent_id).push(r._id);
  }
  const closure = new Set(); const stack = [rootId];
  while (stack.length) {
    const id = stack.pop();
    for (const c of kids.get(id) || []) if (!closure.has(c) && c !== rootId) { closure.add(c); stack.push(c); }
  }
  const prefix = new Set([...rows.keys()].filter((id) => NAMESPACE_RE.test(id) && id !== rootId));
  const direct = new Set([...(directIds || kids.get(rootId) || [])].filter((id) => id !== rootId));
  const union = new Set([...closure, ...prefix, ...direct]);
  return { closure, prefix, direct, union, corpusDepth1: new Set(kids.get(rootId) || []) };
}

const claimableIn = (lens, rows, pool) =>
  [...lens].filter((id) => pool.has(id) && CLAIMABLE_STATUSES.has(rows.get(id)?.lifecycle_status ?? "open")).sort();

// ── CLAUSE (a): THE FROZEN CRITERIA TABLE ───────────────────────────────────
// Frozen here, in code, so the bar cannot be re-derived after seeing a result.
// `polarity` is REQUIRED. `covers` records whether the rerun covers the WHOLE
// stored criterion; a rerun that covers half of it is honest evidence for half a
// criterion and fails closed for the criterion.
export const FROZEN_CRITERIA = [
  {
    index: 0, polarity: "pass", covers: true,
    criterion: "tooling/grip/ ships an LLM-free adjudicator that derives an authority level from a rerun command and refuses to raise it on the author's claim",
    rerun: "git show origin/main:tooling/grip/level.mjs | grep -n checkCeiling",
  },
  {
    index: 1, polarity: null, covers: false,
    criterion: "Every rejection class is demonstrated FIRING by mutation against a frozen adversarial fixture, and a control that does not fire is its own third outcome class",
    rerun: "",
    why: "UNMEASURED, FAIL-CLOSED: the fact is LOCAL EXECUTION and `node` is a REFUSED head (screen.mjs:1096), so it has no storable rerun at all until grip CI exists (tgw6-bl-grip-suite-has-no-ci, D114). D95's 2b is owned by tgw2-acceptance-suite. Never green.",
  },
  {
    index: 2, polarity: "pass", covers: false,
    criterion: "SURVEY_SCHEMA and VERIFY_SCHEMA carry the rerun provenance field in BOTH workflow files, and the gate runs over every returned fact",
    rerun: "git show origin/main:.claude/workflows/bp-epic-cycle.workflow.js | grep -c VERIFY_SCHEMA",
    why: "the rerun covers the POSITIVE HALF only. D97: the stored wording's BOTH-workflow-files clause is UNSATISFIABLE (wild-bulk-cycle.workflow.js has no verify phase, so grep -c returns 0 there and no amount of building changes it), and the reword's clause (c) is stamped on tgw9-s7's merge. Half a criterion fails closed.",
  },
  {
    index: 3, polarity: "absence", covers: true,
    criterion: "Wave 1 stores NOTHING durably — the anti-goal held, verified by the absence of any new persisted corpus",
    rerun: "gh api repos/FRIKKern/barkpark/commits/1514f52cb --jq .files[].filename | grep -c tooling/grip/ledger/",
  },
];

// D65: a purely LOCAL grep whose search STRING mentions a remote form was
// PROMOTED to L2 and screened ADMITTED, so grip's level derivation alone would
// rubber-stamp charter prose as remote authority. An EXPLICIT PATH RULE, not a
// level test, is what refuses it (D96's closing clause: no criterion evidence
// may be a local grep of the charter).
//
// `tgw5-bl-level-mention-promotion` ships in this same wave and closes the
// promotion at its source — the same command re-derives L3 once that branch is
// on main. This rule STAYS, and stays independent of it: the path rule is the
// second layer, and a defence that only works while the first layer is broken
// is not defence in depth. Nothing here asserts the level; the run prints
// whatever the grammar says today.
export const CHARTER_PATH_RE = /(charter|CHARTER)[^\s]*\.md/;
export const CHARTER_GREP_SPECIMEN = 'grep -n "git show origin/main:" .claude/workflows/bp-truth-grip-charter.md';
export function refusesAsCharterGrep(command) {
  const c = String(command ?? "");
  return /^\s*(grep|rg|ag)\b/.test(c) && CHARTER_PATH_RE.test(c);
}

/**
 * Adjudicate one frozen criterion through the REAL screenedRerun path.
 * Never a hand-built or stubbed result: `admitsAbsenceClaim({verdict:"FAILED"})`
 * returns TRUE for a literal with no absenceEligible key, so a stub would make
 * the D50 veto silently absent.
 * Polarity is read via the TOTAL helpers admitsPassClaim / admitsAbsenceClaim,
 * which are correct for null, undefined and the undecorated 6-key refusal
 * literal `screenedRerun` hand-builds at adjudicate.mjs:122-134 — the seam owned
 * by open task `tgw4-absence-veto-stops-at-the-rerun-seam`, cited here, not
 * re-solved. Reading `ruling.rerun.admits.absence` directly TypeErrors on every
 * REFUSED command, including this file's own ceiling probe.
 */
export function adjudicateCriterion(c, repo, run = screenedRerun) {
  if (!c.polarity) return { ...c, ok: false, failCode: "NO-POLARITY", verdict: "NOT-RUN", level: null, reason: c.why || "no declared polarity — fails closed (D109)" };
  if (!c.rerun) return { ...c, ok: false, failCode: "NO-RERUN", verdict: "NOT-RUN", level: null, reason: "no literal rerun command — fails closed" };
  if (refusesAsCharterGrep(c.rerun)) return { ...c, ok: false, failCode: "CHARTER-GREP", verdict: "REFUSED", level: deriveLevel(c.rerun), reason: "a local grep of the charter is not remote authority (D65 promotes it to L2; D96 forbids it)" };
  const r = run(c.rerun, { root: repo });
  const admits = c.polarity === "absence" ? admitsAbsenceClaim(r) : admitsPassClaim(r);
  const ok = admits && c.covers === true;
  return {
    ...c, ok, verdict: r.verdict, level: deriveLevel(c.rerun), admits,
    absenceEligible: r.absenceEligible,
    failCode: ok ? null : (admits ? "PARTIAL-COVERAGE" : "NOT-ADMITTED"),
    reason: !admits
      ? `the rerun came back ${r.verdict} — it does not admit ${c.polarity === "absence" ? "an" : "a"} ${c.polarity}-shaped claim (${(r.reason || "").slice(0, 90)})`
      : (c.covers ? `admitted as ${c.polarity}-shaped evidence: ${(r.reason || "").slice(0, 90)}` : c.why || "the rerun does not cover the whole criterion"),
  };
}

// The four shapes that prove "just accept FAILED" would be a SOFTENING: shapes 1
// and 3 BOTH read FAILED, and only shape 1 may support an absence claim.
export const POLARITY_SPECIMENS = [
  ["honest no-match", "git show origin/main:tooling/grip/record.mjs | grep -c mkdirSync"],
  ["dead host", "curl -s -o /dev/null http://127.0.0.1:9/"],
  ["diff rc1 WITH content", "diff tooling/grip/record.mjs tooling/grip/provenance.mjs"],
  ["tool error", "grep -n checkCeiling tooling/grip/NO-SUCH-FILE.mjs"],
];

// The honest L3 ceiling, stated mechanically. Every route out is closed.
export const CEILING_PROBES = [
  ["the seal's own execution", "node tooling/grip/seal.mjs", "screen.mjs:1096 — node executes arbitrary JavaScript"],
  ["the seal's own data fetch", "curl -sG https://guerrilla.barkpark.cloud/v1/data/query/production/task", "screen.mjs:129 host bound (and :490 refuses --data-urlencode as a write even under -G)"],
  ["the shape grip ADMITS", "bp task list -o json", "an UNEARNED admission: bp reads the same server from ~/.config/barkpark/config.json while NAMING no host"],
  ["the same read, host DECLARED", "bp -s https://guerrilla.barkpark.cloud task list", "screen.mjs:129 — declaring the host flips the identical read to refused"],
];

// ── MAIN ────────────────────────────────────────────────────────────────────
function argOf(argv, n) { const i = argv.indexOf(n); return i === -1 ? null : argv[i + 1]; }

export function main(argv = process.argv.slice(2), out = console.log) {
  const L = []; const say = (s = "") => L.push(s);
  const fixturePath = argOf(argv, "--ledger");
  const server = argOf(argv, "--server") || process.env.BP_SERVER || "https://guerrilla.barkpark.cloud";
  const repo = argOf(argv, "--repo") || process.cwd();
  const stamp = new Date().toISOString();
  let code = 2;
  try {
    // cwd assertion FIRST. A refusal here is exit 2, never a manufactured finding.
    const rp = spawnSync("git", ["-C", repo, "rev-parse", "--show-toplevel"], { encoding: "utf8" });
    const rpc = classifyRun(rp);
    if (rpc.klass !== RUN_CLASS.CLEAN) fail(`repo assertion on ${repo}`, rpc);
    const top = rp.stdout.trim();
    process.chdir(top);
    const head = spawnSync("git", ["-C", top, "rev-parse", "--short", "HEAD"], { encoding: "utf8" });
    const sha = classifyRun(head).klass === RUN_CLASS.CLEAN ? head.stdout.trim() : "(unknown)";

    let fx = null;
    if (fixturePath) {
      try { fx = JSON.parse(readFileSync(fixturePath, "utf8")); }
      catch (e) { fail(`--ledger ${fixturePath}`, { klass: RUN_CLASS.INFRA, detail: String(e.message).slice(0, 90) }); }
      // THE FIXTURE FLOOR. `(fx.namespace || [])` and `(fx.criteria || [])` used
      // to turn a missing or empty key into a LEGAL zero-length corpus: clause
      // (a) is an Array.prototype.every over zero items (true by definition) and
      // clause (b) walks zero rows, so an empty fixture printed 0 published task
      // rows and still exited 0 with THE PREDICATE HOLDS. Refused here, INFRA —
      // the same class the JSON-parse failure above already uses — naming the
      // offending key and the fixture path, never a verdict.
      for (const key of ["namespace", "criteria"]) {
        if (!Array.isArray(fx[key]) || fx[key].length === 0) {
          fail(`--ledger ${fixturePath}`, { klass: RUN_CLASS.INFRA, detail: `fixture key "${key}" is missing or empty — a zero-length corpus makes every clause pass vacuously` });
        }
      }
    }
    let rows, pages, duplicates, pool, poolReport, direct, rootDoc, criteria;
    if (fx) {
      rows = new Map(fx.namespace.map((r) => [r._id, r]));
      pages = ["(fixture)"]; duplicates = 0;
      pool = new Set(fx.pool || []);
      poolReport = { pages: ["(fixture)"], walked: pool.size, ids: pool, allIds: pool, allCount: pool.size, allUnique: pool.size, duplicates: 0, allDuplicates: 0 };
      direct = new Set(fx.direct_children || []);
      // rootDoc is derived from the loaded corpus, never trusted off a separate
      // `fx.root_doc` field — a fixture could otherwise name a root that is not
      // in its own namespace, and nothing would cross-check it.
      rootDoc = rows.get(ROOT_ID) || null;
      criteria = fx.criteria;
    } else {
      const walk = walkCorpus(server);
      rows = walk.rows; pages = walk.pages; duplicates = walk.duplicates;
      direct = fetchDirect(server, ROOT_ID);
      poolReport = walkPool();
      pool = poolReport.ids;
      rootDoc = rows.get(ROOT_ID) || null;
      criteria = FROZEN_CRITERIA;
    }
    if (!rootDoc) fail("root document", { klass: RUN_CLASS.INFRA, detail: `${ROOT_ID} is not in the walked corpus` });
    const recon = reconcilePool(poolReport);
    if (!recon.ok) fail("ready pool", { klass: RUN_CLASS.INFRA, detail: recon.detail });

    const lens = buildLenses(rows, ROOT_ID, direct.size ? direct : null);
    if (!fx && direct.size !== lens.corpusDepth1.size)
      fail("lens reconciliation", { klass: RUN_CLASS.INFRA, detail: `pinned filter[parent_id] returned ${direct.size} but the walked corpus holds ${lens.corpusDepth1.size} depth-1 children` });

    const blocking = claimableIn(lens.union, rows, pool);
    const rulings = criteria.map((c) => adjudicateCriterion(c, top));

    const a = rulings.every((r) => r.ok);
    const b = blocking.length === 0;
    const bPrime = pool.has(ROOT_ID);
    const rootStatus = rootDoc.lifecycle_status;
    const c = !CLOSED_STATUSES.has(rootStatus);
    const holds = a && b && bPrime && c;

    // ── output ──
    say("=== SEAL PREDICATE — truth-grip-epic (D94 as amended by D108) ===");
    say(`walked at ${stamp}  repo ${top} @ ${sha}${fx ? `  [LEDGER FIXTURE ${fixturePath} — NOT LIVE]` : "  [live ledger]"}`);
    say(`corpus walk pages: ${pages.join("+")} = ${rows.size} published task rows, ${duplicates} duplicate id(s) deduped`);
    say(`ready pool walk  : ${poolReport.pages.join("+")} = ${poolReport.walked} (PAGE=${PAGE}, under the silent 1000 clamp)`);
    say(`      reconciliation : ${recon.detail}`);
    say(`lens: closure ${lens.closure.size} / prefix(_type==task) ${lens.prefix.size} / filter[parent_id] ${lens.direct.size} / UNION ${lens.union.size}`);
    say(`      claimable per lens: closure ${claimableIn(lens.closure, rows, pool).length}` +
        ` / prefix ${claimableIn(lens.prefix, rows, pool).length}` +
        ` / direct ${claimableIn(lens.direct, rows, pool).length}` +
        ` / union ${blocking.length}`);
    const missedByDirect = [...lens.union].filter((id) => !lens.direct.has(id));
    const missedPooled = missedByDirect.filter((id) => pool.has(id));
    say(`      the prior art's direct lens would MISS ${missedByDirect.length} row(s), ${missedPooled.length} of them pooled: ${missedPooled.join(", ") || "-"}`);
    say(`      the prefix lens would MISS ${[...lens.union].filter((id) => !lens.prefix.has(id)).join(", ") || "-"}`);
    say("");
    say(`CLAUSE (a) polarity-declared evidence on the root's ${rulings.length} acceptance criteria`);
    for (const r of rulings) {
      say(`  ${r.ok ? "PASS" : "FAIL"} [${r.index}] polarity=${r.polarity || "NONE"} level=${r.level || "-"} verdict=${r.verdict}${r.failCode ? ` fail=${r.failCode}` : ""}`);
      say(`       ${r.criterion.slice(0, 96)}`);
      say(`       ${r.reason}`);
    }
    say(`  => (a) ${a ? "PASS" : `FAIL — ${rulings.filter((r) => !r.ok).length} of ${rulings.length} criteria are not adjudicated`}`);
    say("");
    say(`CLAUSE (b) namespace MINUS the root has zero claimable rows in a live pool`);
    say(`  ${blocking.length} claimable row(s) block the seal:`);
    blocking.forEach((id) => say(`       x ${id}  (${rows.get(id)?.lifecycle_status ?? "open"})`));
    say(`  => (b) ${b ? "PASS" : `FAIL — by ${blocking.length} row(s)`}`);
    say("");
    say(`CLAUSE (b') the ROOT ITSELF is still claimable at check time — asserted on POOL MEMBERSHIP`);
    say(`  pool.has("${ROOT_ID}") = ${bPrime}   (never claim == null: the root's claim is expired and it is pooled anyway)`);
    say(`  => (b') ${bPrime ? "PASS" : "FAIL — the root has left the pool, so (c)'s only enforcement is gone"}`);
    say("");
    say(`CLAUSE (c) the root closes LAST — it has not closed yet`);
    say(`  ${ROOT_ID}.lifecycle_status = ${rootStatus}  (closed = ${[...CLOSED_STATUSES].join("|")}; every other status is "not closed yet")`);
    say(`  => (c) ${c ? "PASS" : `FAIL — the root is already ${rootStatus}; this predicate will not bless an out-of-order close retroactively`}`);
    say("");
    say("POLARITY, MEASURED — why \"just accept FAILED\" would be a SOFTENING:");
    for (const [label, cmd] of POLARITY_SPECIMENS) {
      const r = screenedRerun(cmd, { root: top });
      say(`  ${label.padEnd(22)} verdict=${String(r.verdict).padEnd(17)} absenceEligible=${String(r.absenceEligible)}  admitsAbsence=${admitsAbsenceClaim(r)}`);
    }
    say("  two of those read FAILED; only one may support an absence claim.");
    say("");
    say("HONEST CEILING — grip CANNOT adjudicate its own execution (D96), stated by file:line:");
    for (const [what, cmd, why] of CEILING_PROBES) {
      const s = screenCommand(cmd);
      say(`  ${s.ok ? "ADMITTED" : "REFUSED "} ${what}: ${deriveLevel(cmd)}  ${why}`);
    }
    say("  The screen REWARDS CONCEALING the host and PUNISHES DECLARING it. That asymmetry is");
    say("  more informative than any wrapper, and no L2 wrapper is manufactured here.");
    say(`  D65's charter-grep shape, adjudicated by PATH regardless of level (tgw5 closes the promotion itself):`);
    say(`  deriveLevel(${JSON.stringify(CHARTER_GREP_SPECIMEN)})`);
    say(`  = ${deriveLevel(CHARTER_GREP_SPECIMEN)} and screenCommand admits it (${screenCommand(CHARTER_GREP_SPECIMEN).ok}). refusesAsCharterGrep rejects it anyway: ${refusesAsCharterGrep(CHARTER_GREP_SPECIMEN)}.`);
    say("");
    say("NOT ASSERTED by this run:");
    say("  1. The union of three lenses equalling the closure is TODAY's measurement, not an");
    say("     invariant. A tgw*-named row filed outside the tree breaks it; that is why the union");
    say("     is computed rather than assumed.");
    say(`  2. This command adjudicates the ROOT's ${rulings.length} criteria only. Child-task criteria are the`);
    say("     children's own ledger rows and are reached here only through clause (b)'s pool test.");
    say("  3. Its own execution is L3 and unadjudicable, by design and permanently.");
    if (fx) say("  4. Under --ledger NOTHING live is read: clause (b)/(b')/(c) are fixture rows. A green");
    if (fx) say("     here is a MUTATION CONTROL, never evidence about the live ledger.");
    say("");
    if (holds) {
      say("VERDICT: THE PREDICATE HOLDS — all four clauses pass. The root may close, LAST.");
    } else {
      say("VERDICT: NOT YET.");
      if (!a) say(`  - clause (a) fails: ${rulings.filter((r) => !r.ok).map((r) => `[${r.index}] ${r.failCode}`).join(", ")}`);
      if (!b) say(`  - clause (b) fails by ${blocking.length} claimable row(s)`);
      if (!bPrime) say("  - clause (b') fails: the root is not in the ready pool");
      if (!c) say(`  - clause (c) fails: the root is already ${rootStatus}`);
      say("  This is a pre-authorised, honest outcome (D93). The named failing clauses are the handoff.");
    }
    say(`VERDICT-TOKEN: SEAL-PREDICATE ${holds ? "HOLDS" : "NOT-YET"} a=${a ? "PASS" : "FAIL"} b=${b ? "PASS" : "FAIL"} b'=${bPrime ? "PASS" : "FAIL"} c=${c ? "PASS" : "FAIL"} blocking=${blocking.length}`);
    code = holds ? 0 : 1;
  } catch (e) {
    // EXIT 1 MEANS NOT YET AND NOTHING ELSE. An unexpected throw is still an
    // infra fault, never a verdict — that is the whole reason for a third code.
    say("=== SEAL PREDICATE — truth-grip-epic ===");
    say(`INFRA FAULT at ${stamp}: ${e instanceof Infra ? e.message : `unexpected ${e.name}: ${e.message}`}`);
    say("  This is NOT a verdict on the predicate. Nothing was measured, so nothing is claimed —");
    say("  the whole point of a third exit code is that this can never be read as NOT YET.");
    say("VERDICT-TOKEN: SEAL-PREDICATE INFRA-FAULT a=UNKNOWN b=UNKNOWN b'=UNKNOWN c=UNKNOWN blocking=UNKNOWN");
    code = 2;
  }
  out(L.join("\n"));
  return code;
}

if (import.meta.url === `file://${process.argv[1]}`) process.exit(main());
