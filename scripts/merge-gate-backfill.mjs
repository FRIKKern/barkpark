#!/usr/bin/env node
// merge-gate-backfill.mjs — ENUMERATE the merge-gate residue by a STABLE KEY.
//
// WHAT THIS REPLACES, AND WHY IT IS NOT A STYLE CHANGE.
// The 2026-08-23 residue pass enumerated with
//   bp doc query task --filter lifecycle_status=open --limit 200 --offset N
// over a collection concurrent writers were mutating. Offset paging has NO
// ordering key of its own: a row whose `_updatedAt` changes mid-sweep moves
// between pages and is SKIPPED or DOUBLE-COUNTED. Two such sweeps taken minutes
// apart disagreed on 26 rows — 6 present only in the second, 20 only in the
// first. `jpf-w1-builder-identity` (criterion 5, verbatim "PR merged (lead
// closes)") is a month-old, unclaimed, perfectly-phrased gate that sweep 1
// never returned; it surfaced only because a THIRD sweep was taken and unioned.
// Every pass therefore left a RANDOM residue, and re-running the pass could not
// converge because the enumerator itself was the leak.
//
// ── THE STABLE KEY ───────────────────────────────────────────────────────────
// `_createdAt` is IMMUTABLE. It is the only ordering key this server honours
// that a concurrent write cannot move. Measured against the live server
// 2026-09-15:
//
//   --order _id:asc        -> 400 validation_failed: "unrecognised order spec"
//   --order doc_id:asc     -> 200, and IDENTICAL to --order doc_id:desc
//   --order bogusfield:asc -> 200, and IDENTICAL to both of the above
//   --order _createdAt:asc -> 200, and DIFFERENT from _createdAt:desc
//
// Read the third line twice. An order spec naming a JSONB content path that
// does not exist is SILENTLY IGNORED — it is not a 400 — so `--order doc_id`
// looks like keyset ordering and is in fact the server's default arbitrary
// order. The `bogusfield` row is the control that proves it: any believer in
// `--order doc_id:asc` is enumerating unordered and cannot tell.
// `_createdAt:asc` is the only spelling with a control that DISCRIMINATES.
//
// Keyset, not offset: each page asks for `_createdAt >= <last seen>` and drops
// ids already seen. `>=` (not `>`) is deliberate — two rows sharing a
// microsecond timestamp would be silently skipped by `>`. The overlap costs one
// duplicated row per page and can never lose one. A page whose rows ALL share
// one timestamp cannot advance the cursor; that is detected and raised, never
// looped on.
//
// ── A FULL PAGE IS A TRUNCATION WARNING, NOT A COUNT ─────────────────────────
// `bp` itself says so on stderr: "result page filled your --limit of N exactly;
// more may be available". 937 of 1000 is a total; 200 of 200 is not. This
// module NEVER terminates on a full page. It terminates only on a SHORT page —
// and then re-probes from the cursor once, because the server is known to cap
// `--limit` silently above 200: under a cap, EVERY page is short, and a sweep
// that trusted shortness would stop at page one and call it the whole ledger.
// If the confirming probe returns rows, the short page was a cap and the sweep
// continues (recording the effective page size in the report).
//
// ── DRY RUN IS THE DEFAULT ───────────────────────────────────────────────────
// This module's job is the ENUMERATOR. Applying `merge_gate: true` to live rows
// is a DIFFERENT piece of work (bl-merge-gate-flag-backfill-two-directions) and
// needs its own authority. `--apply` exists, refuses without
// `--i-am-the-flag-backfill-owner`, and is not exercised by any test here.
//
// ── UNWRITABLE IS A CATEGORY, NEVER A SUCCESS ────────────────────────────────
// Four rows refuse any patch+publish for reasons unrelated to merge_gate. A
// pass that does not name them reports a clean sweep over rows it never
// changed. They are carried below BY ID with their measured reason, and the
// report re-checks each against the live ledger rather than trusting the table.
//
// ── SOUND PAGING IS NOT A SOUND POPULATION ───────────────────────────────────
// The keyset walk above fixed HOW rows are enumerated. It did not fix WHICH.
// Until 2026-09-16 this module swept `lifecycle_status=open` only, and reported
// that as "the residue". Measured live that day over all five NON-TERMINAL
// statuses (considering, researching, open, in_progress, blocked):
//
//   considering  270 rows   13 stamp-blocked criteria
//   researching    0 rows    0
//   open         878 rows   13
//   in_progress   18 rows    1
//   blocked       14 rows    0
//
// 14 of the 27 sat OUTSIDE `open` — the open-only sweep saw HALF the residue
// and called it the whole of it. A `considering` row refuses a builder's stamp
// exactly as hard as an `open` one; nothing in the stamp guard reads
// lifecycle_status. An enumeration is a snapshot: a perfectly stable walk over
// the wrong filter is still a snapshot of the wrong thing.
//
// ── THE NAG'S REGEX IS NOT THE REGEX THAT BLOCKS A STAMP ─────────────────────
// `MARKER_LEADING` is the AUTHORING nag's view and is reported as
// `newly_flaggable` because criterion 4 asks what the nag SEES. It is NOT what
// a blocked builder collides with. `bp task stamp` is refused by
// `Barkpark.Tasks.Criteria.merge_gated?/1`, whose fallback is the UNANCHORED
// `STAMP_GUARD` below — copied verbatim from criteria.ex `@merge_gate_worded`.
// A criterion matching STAMP_GUARD, carrying no `merge_gate` key, and still
// unmet is a criterion NOBODY CAN STAMP: the wide arm refuses the builder and
// the strict arm (close.ex `merge_gate_synthetics/3`, flag-only) will not
// autostamp it for the lead. That set — `stamp_blocked` — is the population
// bl-merge-gate-flag-backfill-two-directions is about, and it is reported
// separately from `newly_flaggable` because the two predicates disagree.
//
// USAGE
//   node scripts/merge-gate-backfill.mjs --out sweep-a.json
//   node scripts/merge-gate-backfill.mjs --out sweep-b.json
//   node scripts/merge-gate-backfill.mjs --compare sweep-a.json sweep-b.json
//   node scripts/merge-gate-backfill.mjs --selftest

import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { createHash } from "node:crypto";

// ─── The four UNWRITABLE specimens, measured 2026-08-23 ──────────────────────
// Each refuses patch+publish for a PRE-EXISTING content defect that has nothing
// to do with merge_gate. Counting any of these as "applied" is the exact lie
// this table exists to prevent.
export const UNWRITABLE = Object.freeze({
  "cch-w28-bl-overflow-guard-clipper-blames-the-wrong-panel": {
    reason: "off-vocabulary `surface` value (prose, not a term)",
    detail: 'surface reads as a sentence beginning "cannot be filed under cloud-console-hardening-epic as ..."',
  },
  "cch-w28-bl-w22s7-split-stamps-never-landed-and-c9-kill-is-refuted": {
    reason: "off-vocabulary `surface` value (prose, not a term)",
    detail: 'surface reads as a sentence beginning "cannot be filed under cloud-console-hardening-epic as ..."',
  },
  "gr-backlog-d24-statusmeta-sweep": {
    reason: "off-vocabulary `surface` value (prose, not a term)",
    detail: 'surface reads as a sentence beginning "cannot be filed under cloud-console-hardening-epic as ..."',
  },
  "tgw11-bl-screen-classifysafety-global-option-launder": {
    reason: "stale-draft claim divergence",
    detail: "the drafts perspective carries a claim the published row does not; publish is refused on the divergence",
  },
});

// ─── Criterion classification ────────────────────────────────────────────────

// The AUTHORING nag's regex, copied VERBATIM from
// api/lib/barkpark/plugins/tasks.ex `@merge_gate_lead`. Copied, not widened:
// this module reports what the nag SEES so the gap is measurable. Widening the
// nag is an api/ change and a deliberate owner call — see PHRASING_FAMILY.
export const MARKER_LEADING = /^\s*[[(]?\s*\*{0,2}\s*MERGE[-\s]GATED\b/i;

// THE PHRASING FAMILY the leading-anchored nag cannot see. 99 of the 135
// unflagged rows the 2026-08-23 pass found (73%) are this shape: the gate is
// stated as an OUTCOME ("PR merged (lead closes on merge)") rather than as a
// leading marker. This regex is used for REPORTING ONLY and is never applied to
// a write: the nag's own in-tree comment forbids widening it, because a census
// of 1845 marker-bearing criteria found 54 that merely MENTION merge-gating,
// and position and prose misclassify in OPPOSITE directions. See the
// `--compare` report's `phrasing_family` bucket, which is the measurement that
// decision has to be made against.
export const PHRASING_FAMILY = /\bPR\s+(?:is\s+)?merged\b[^\n]{0,120}?\blead\s+closes\b/i;

// THE STAMP REFUSAL PREDICATE, copied VERBATIM from
// api/lib/barkpark/tasks/criteria.ex `@merge_gate_worded`. UNANCHORED, and
// deliberately wider than both regexes above: it is the fallback
// `Criteria.merge_gated?/1` uses when a criterion carries no `merge_gate` key,
// so it — not MARKER_LEADING — decides whether `bp task stamp --met` is
// refused. Copied, never widened; if criteria.ex changes, this must follow.
export const STAMP_GUARD = /MERGE[-\s]GATED|MERGE[-\s]GATE\b/i;

// THE NON-TERMINAL LIFECYCLE SET — the population, not just `open`.
// `Barkpark.Tasks.Transitions` @statuses is
//   considering researching open in_progress blocked done cancelled
// and the last two are terminal. Everything else can still be worked, so
// everything else can still be stamp-blocked. Sweeping `open` alone is the
// population defect this constant exists to prevent re-introducing; the
// selftest's POPULATION arm reds if it narrows back.
export const NON_TERMINAL = Object.freeze(["considering", "researching", "open", "in_progress", "blocked"]);
export const TERMINAL = Object.freeze(["done", "cancelled"]);

// ─── THE RE-ARM: quoting a retired gate puts the marker back ─────────────────
// THE MECHANISM, written down because it defeated its own authors. Six
// `jf-w1-*` criteria were CORRECTED on 2026-08-20 to RETIRE a merge gate that
// could never be met. Each correction quotes the retired wording verbatim —
// `ORIGINAL WORDING, verbatim: "... (merge-gated; the lead closes this ...)"` —
// so `STAMP_GUARD` still matches the criterion, `Criteria.merge_gated?/1` still
// returns true, and the builder still cannot stamp. The retraction RE-ARMED the
// tripwire it was undoing. A retraction quotes what it retracts, so it matches
// its own retraction.
//
// THE RULE, NOT THE LIST. The six are a snapshot (five have since closed; only
// `jf-w1-revendor-honest-media#4` is still non-terminal as of 2026-09-17). The
// durable form is a PREDICATE: a criterion whose marker appears ONLY inside a
// quoted span is quoting a gate, not declaring one. Strip the quotations; if the
// guard no longer matches, every match it had was borrowed from the quote.
//
// THE FIX IS THE FLAG, NEVER A REWORD. Do not paraphrase the quote to dodge the
// regex — the verbatim quote is the evidence the correction exists for, and a
// reworded quote is a falsified record. Set `"merge_gate": false` on the
// criterion: it is the documented one-field veto (criteria.ex:77-81), it wins
// over the prose arm outright, and it leaves the quotation byte-identical.
const QUOTED_SPAN = /"[^"]*"|“[^”]*”|'[^'\n]*'/g;

/** Text with every quoted span removed. */
export function stripQuoted(text) {
  return typeof text === "string" ? text.replace(QUOTED_SPAN, " ") : "";
}

/**
 * True when the merge-gate marker appears ONLY inside a quotation — the
 * signature of a criterion that QUOTES a retired gate rather than declaring one.
 * These are MENTIONs: they belong on the `merge_gate: false` side of the
 * two-directional backfill.
 */
export function quotesRetiredGateOnly(text) {
  if (typeof text !== "string" || !STAMP_GUARD.test(text)) return false;
  return !STAMP_GUARD.test(stripQuoted(text));
}

// ─── THE HAND CLASSIFICATION (2026-09-17, gates-r21-w4) ──────────────────────
// `stamp_blocked` is ONE set with TWO remedies, and no text rule separates them
// — that is this row's central finding, and the reason a one-directional
// backfill is refused: `merge_gate: true` on a mere MENTION makes an innocent
// criterion permanently lead-only, and `met` has no un-stamp.
//
//   GATE    → write `merge_gate: true`   (a real lead-only gate missing its flag)
//   MENTION → write `merge_gate: false`  (a row whose SUBJECT is merge-gating)
//
// Classified BY HAND against the full stored wording of all 25, read live.
// Re-derived at execution time, NOT inherited: the row records 55 criteria
// across 46 rows (2026-08-24) split 19 GATE / 36 MENTION. Live today: 25 across
// 24 rows, split 19 GATE / 6 MENTION. The population DRAINED — all seven rows
// the filing named as "structurally stuck" have since closed (4 done, 3
// cancelled). The 19 matching the recorded 19 is a COINCIDENCE of drainage; it
// is not the same 19.
//
// THIS TABLE IS A SNAPSHOT AND IS GUARDED AS ONE. `--plan` refuses loudly on any
// live stamp-blocked criterion missing from it, and reports every entry that has
// since drained. It is never consulted without that reconciliation.
// A SECOND READER (gates-r21d-w11, 2026-09-18) asked a DIFFERENT question of the
// same 22 live criteria than the first pass did. The first pass asked "is this
// criterion the LEAD's to close?"; the second asked "is the thing this criterion
// ASSERTS genuinely `this PR merged with its required contexts green`?". Those
// questions agree on 20 of 22 and diverge on exactly the shape where the merge
// is a CONJUNCT or a MARKER rather than the whole assertion — which is the
// fabrication direction this row exists to prevent, because `merge_gate:true`
// makes `merge_gate_synthetics/3` autostamp the WHOLE criterion on a lead merge
// close, including the half no merge proves. HOLD is the third verdict those two
// need: classified (so the staleness guard stays satisfied and cannot rot into
// silence), but NEVER planned as a write in either direction. An unflagged
// criterion is merely inconvenient; a wrongly-permitted one is a fabricated done.
export const VERDICT = Object.freeze({ GATE: "GATE", MENTION: "MENTION", HOLD: "HOLD" });

export const CLASSIFICATION = Object.freeze({
  // ── GATE (19): the criterion IS this row's merge gate.
  "tgw-bl-l4-artifact-inventory#3":               [VERDICT.GATE, "declares the gate: PR merged to main, gates green"],
  "tgw3-decide-stages-foreign-rows#3":            [VERDICT.GATE, "declares the gate: PR merged to origin/main"],
  "tgw4-bl-plainrule-flag-audit#6":               [VERDICT.GATE, "declares the gate: PR merged to origin/main"],
  "tgw-census-reach-triage#3":                    [VERDICT.GATE, "declares the gate: PR merged to origin/main"],
  "hgw4-bl-automerge-artifact-side-head-recheck#3":[VERDICT.GATE, "LEAD closes: PR merged, or declined with the decision recorded"],
  "connectors-telegram-webhook-wire#2":           [VERDICT.GATE, "declares the gate: PR merged; connectors.yml green"],
  "task-e7bd4b127aaee4fc#2":                      [VERDICT.GATE, "THE LEAD CLOSES THIS: PR merged with the merge SHA recorded"],
  "pds-bl-guerrilla-stale-build-prod-trap#3":     [VERDICT.GATE, "declares the gate: PR merged to origin/main"],
  "tgw-bl-wild-bulk-roster-floor#3":              [VERDICT.GATE, "declares the gate: PR merged to main, gates green"],
  "tgw-bl-fanout-floor-harness#3":                [VERDICT.GATE, "declares the gate: PR merged to main, gates green"],
  "tgw-bl-epic-cycle-minitems-comment#2":         [VERDICT.GATE, "declares the gate: PR merged to main, gates green"],
  "task-97750fc8b61c45cc#6":                      [VERDICT.GATE, "lead-owned: merge-base --is-ancestor against origin/main"],
  "task-6f12ce2edd4be65a#4":                      [VERDICT.GATE, "declares the gate: merged to main with its gates green"],
  "wbt-jwt-bl-wire-p7-doc-gates#4":               [VERDICT.GATE, "THE LEAD closes, never the builder: PR merged with the Task: trailer"],
  "tgw9-bl-epic-cycle-digest-demotion-prose#2":   [VERDICT.GATE, "THE LEAD closes: the PR is merged to main"],
  "task-c7e10834d493da6f#2":                      [VERDICT.GATE, "THE LEAD closes: PR merged to main"],
  "task-5753ff3072d00b67#4":                      [VERDICT.GATE, "THE LEAD closes: PR merged, required contexts green"],

  // ── MENTION (6): the row's SUBJECT is the merge-gate machinery.
  // The first is derived, not asserted: `quotesRetiredGateOnly` returns true for
  // it, and the `--plan` cross-check reds if that ever stops being so.
  "jf-w1-revendor-honest-media#4":                [VERDICT.MENTION, "RETIRED gate quoted verbatim inside a 2026-08-20 correction; the quote re-arms the prose arm"],
  "cchi-w46-bl-lapsed-claim-arrears-close-path#1":[VERDICT.MENTION, "describes HOW to stamp merge-gated rows; not itself gated"],
  "cchi-w46-bl-lapsed-claim-arrears-close-path#2":[VERDICT.MENTION, "requires per-row verification of OTHER rows' merge gates; not itself gated"],
  "task-0ed428e843b83382#0":                      [VERDICT.MENTION, "about the CREATE path setting merge_gate:true; meta"],
  "task-616789a3afe59364#1":                      [VERDICT.MENTION, "about merge-gate-autostamp-liveness.sh exiting 0; meta"],
  "task-60703ce4dd41a5a0#3":                      [VERDICT.MENTION, "about hand-classifying worded-but-unflagged criteria; meta"],

  // -- HOLD (2): merge-SHAPED but not merge-EXHAUSTED. Both were GATE in the
  // first pass. Neither is written in either direction; both are the owner's call.
  "pds-w20-crown-collect-and-seal#5":             [VERDICT.HOLD, "marker says LEAD-closes, but the ASSERTION is 'the crown seals 12/12 under one RUN_ID, OR a named refusal is recorded in the wave paper' — a merge proves neither disjunct, so merge_gate:true would autostamp a crown that never sealed"],
  "task-f56d553a70a4bba8#4":                      [VERDICT.HOLD, "a CONJUNCTION: 'the atomic PR is merged to main with all required contexts green, AND the first five post-flip campaign PRs render five required contexts in pr-required.sh (5/5)'. The merge proves the first conjunct only; merge_gate:true would autostamp the 5/5 half no merge can witness"],
});

// The two blind-sample MENTIONs main's 2026-09-07 deferral named by hand
// (`cchi-w46-…#1` and `#2`) are both present above with the same verdict — an
// independent reader reaching the same call on the same two criteria.

export const CATEGORY = Object.freeze({
  FLAGGED: "FLAGGED",                 // merge_gate === true — already machine-readable
  VETOED: "VETOED",                   // merge_gate === false — an explicit author veto, never touched
  FLAGGABLE: "FLAGGABLE",             // leading MERGE-GATED marker, no flag — the nag sees this
  PHRASING_FAMILY: "PHRASING-FAMILY", // the 73% the nag cannot see — reported, never auto-written
  UNWRITABLE: "UNWRITABLE",           // a known content defect refuses the write — NEVER "applied"
  CLEAN: "CLEAN",                     // no merge-gate signal of any kind
});

/** Classify one row. Pure — no I/O, so the selftest can drive it directly. */
export function classifyRow(row) {
  const id = row._id;
  const crits = Array.isArray(row.acceptance_criteria) ? row.acceptance_criteria : [];
  const hits = { flagged: [], vetoed: [], flaggable: [], phrasing: [], stamp_blocked: [] };

  crits.forEach((c, idx) => {
    if (!c || typeof c !== "object") return;
    const text = typeof c.criterion === "string" ? c.criterion : "";
    // STAMP-BLOCKED is measured FIRST and INDEPENDENTLY of the category ladder:
    // a criterion can be both FLAGGABLE (the nag sees it) and stamp-blocked,
    // and the two sets are reported separately because they answer different
    // questions. `met:true` is excluded — a criterion already stamped cannot be
    // blocked from being stamped, whatever its wording says.
    if (c.merge_gate === undefined && c.met !== true && STAMP_GUARD.test(text)) {
      hits.stamp_blocked.push(idx);
    }
    if (c.merge_gate === true) return hits.flagged.push(idx);
    if (c.merge_gate === false) return hits.vetoed.push(idx);
    if (MARKER_LEADING.test(text)) return hits.flaggable.push(idx);
    if (PHRASING_FAMILY.test(text)) return hits.phrasing.push(idx);
  });

  // UNWRITABLE outranks every writeable verdict: a row we cannot write is not a
  // row we are about to fix, whatever its text says.
  if (Object.prototype.hasOwnProperty.call(UNWRITABLE, id) &&
      (hits.flaggable.length || hits.phrasing.length)) {
    return { id, category: CATEGORY.UNWRITABLE, hits, unwritable: UNWRITABLE[id] };
  }
  if (hits.flaggable.length) return { id, category: CATEGORY.FLAGGABLE, hits };
  if (hits.phrasing.length) return { id, category: CATEGORY.PHRASING_FAMILY, hits };
  if (hits.flagged.length) return { id, category: CATEGORY.FLAGGED, hits };
  if (hits.vetoed.length) return { id, category: CATEGORY.VETOED, hits };
  return { id, category: CATEGORY.CLEAN, hits };
}

// ─── The keyset enumerator ───────────────────────────────────────────────────

export const PAGE_SIZE = 200;

/**
 * Keyset-paginate the open task collection by the immutable `_createdAt`.
 *
 * `fetchPage({ since, limit })` must return the rows with `_createdAt >= since`
 * ordered `_createdAt:asc`, at most `limit` of them. Injected so the selftest
 * can drive a server that mutates between pages and a server that silently
 * caps `limit` — both of which are the real failures this replaces.
 */
export async function enumerateKeyset(fetchPage, { pageSize = PAGE_SIZE, since = "1970-01-01T00:00:00Z" } = {}) {
  const seen = new Map();
  const notes = [];
  let cursor = since;
  let pages = 0;
  let limit = pageSize;
  let effectivePageSize = pageSize;
  const TIE_CEILING = pageSize * 64;

  for (;;) {
    const rows = await fetchPage({ since: cursor, limit });
    pages += 1;
    if (rows.length > limit) {
      throw new Error(`page ${pages} returned ${rows.length} rows for a --limit of ${limit}`);
    }

    for (const r of rows) if (!seen.has(r._id)) seen.set(r._id, r);
    const last = rows.length ? rows[rows.length - 1]._createdAt : null;

    if (rows.length === limit) {
      // A FULL PAGE IS NEVER AN END. It is bp's own truncation warning.
      if (last === cursor) {
        // The whole page sits inside ONE timestamp, so the cursor cannot
        // advance without skipping a tied row. Widen the window instead of
        // stepping over it — `>` would have dropped them silently.
        if (limit >= TIE_CEILING) {
          throw new Error(
            `${limit} consecutive rows share the timestamp ${cursor}; ` +
            `_createdAt is not selective enough to page this collection`);
        }
        limit *= 2;
        notes.push(`timestamp tie at ${cursor}: widened the page window to ${limit}`);
        continue;
      }
      cursor = last;
      limit = pageSize;
      continue;
    }

    // A SHORT PAGE MIGHT BE A SILENT --limit CAP, NOT THE END. Probe once from
    // the cursor before believing it. Under a cap every page is short and a
    // credulous sweep stops at page one.
    if (rows.length > 0 && rows.length < limit) {
      const probe = await fetchPage({ since: last, limit });
      const unseen = probe.filter((r) => !seen.has(r._id));
      if (unseen.length > 0) {
        if (effectivePageSize === pageSize) {
          effectivePageSize = rows.length;
          notes.push(
            `server capped --limit ${limit} to ${rows.length}; a short page is NOT the end here`);
        }
        for (const r of probe) if (!seen.has(r._id)) seen.set(r._id, r);
        cursor = probe[probe.length - 1]._createdAt;
        pages += 1;
        continue;
      }
    }
    break;
  }

  return { rows: [...seen.values()], pages, effectivePageSize, notes };
}

// ─── The live bp adapter ─────────────────────────────────────────────────────

function bpQuery(args) {
  const out = execFileSync("bp", args, {
    encoding: "utf8",
    maxBuffer: 256 * 1024 * 1024,
    env: { ...process.env, BARKPARK_TOKEN: undefined },
    stdio: ["ignore", "pipe", "pipe"], // stderr is bp's ADVISORY channel — never merged into stdout
  });
  const body = JSON.parse(out);
  // `bp doc query` returns `.documents`; every `bp task` verb returns `.docs`.
  // Reading the wrong key yields a silent ZERO indistinguishable from an empty
  // result, so name the keys we actually got when the expected one is absent.
  if (!Array.isArray(body.documents)) {
    throw new Error(`bp doc query returned no .documents; keys were: ${Object.keys(body).join(", ")}`);
  }
  return body.documents;
}

function livePageFor(status) {
  return ({ since, limit }) => bpQuery([
    "doc", "query", "task",
    "--filter", `lifecycle_status=${status}`,
    "--filter", `_createdAt>=${since}`,
    "--order", "_createdAt:asc",
    "--limit", String(limit),
    "--fields", "acceptance_criteria,title,lifecycle_status",
    "-o", "json",
  ]);
}

/**
 * Sweep the WHOLE non-terminal population, one keyset walk per status, unioned
 * by `_id`. One walk per status rather than one walk over everything because
 * `lifecycle_status` is the only filter this endpoint honours for the task
 * collection — and because a per-status row count is the evidence that the
 * open-only sweep was seeing a fraction. `pageFor` is injected so the selftest
 * can drive a fake multi-status server.
 */
export async function sweepNonTerminal(pageFor, { pageSize = PAGE_SIZE, statuses = NON_TERMINAL } = {}) {
  const seen = new Map();
  const perStatus = {};
  const notes = [];
  let pages = 0;
  let effectivePageSize = pageSize;
  for (const status of statuses) {
    const res = await enumerateKeyset(pageFor(status), { pageSize });
    perStatus[status] = res.rows.length;
    pages += res.pages;
    effectivePageSize = Math.min(effectivePageSize, res.effectivePageSize);
    for (const n of res.notes) notes.push(`[${status}] ${n}`);
    for (const r of res.rows) if (!seen.has(r._id)) seen.set(r._id, r);
  }
  return { rows: [...seen.values()], pages, effectivePageSize, notes, perStatus, statuses: [...statuses] };
}

// ─── Reporting ───────────────────────────────────────────────────────────────

export function buildReport(rows, meta) {
  const verdicts = rows.map(classifyRow);
  const byCategory = {};
  for (const v of Object.values(CATEGORY)) byCategory[v] = [];
  for (const v of verdicts) byCategory[v.category].push(v.id);
  for (const k of Object.keys(byCategory)) byCategory[k].sort();

  // THE WORDING CENSUS behind criterion 4. The AUTHORING nag is anchored to a
  // LEADING marker; this counts what it sees against what a human would call a
  // gate, over the rows this sweep actually enumerated — so the widen-or-rule-out
  // decision is made against a live number, not a remembered one.
  // Split every wording bucket by FLAG STATE. A bare "48 in the family" is a
  // true number with a false story: most of those criteria already carry
  // merge_gate:true and are not residue at all. The *_unflagged arms are the
  // residue; the bare arms are the corpus.
  const census = {
    criteria_total: 0, flagged: 0,
    leading_marker: 0, leading_marker_unflagged: 0,
    family_lead_closes: 0, family_lead_closes_unflagged: 0,
    mentions_merge: 0,
  };
  for (const r of rows) {
    for (const c of (Array.isArray(r.acceptance_criteria) ? r.acceptance_criteria : [])) {
      if (!c || typeof c !== "object") continue;
      const t = typeof c.criterion === "string" ? c.criterion : "";
      census.criteria_total += 1;
      const gated = c.merge_gate === true;
      if (gated) census.flagged += 1;
      if (MARKER_LEADING.test(t)) { census.leading_marker += 1; if (!gated) census.leading_marker_unflagged += 1; }
      if (PHRASING_FAMILY.test(t)) { census.family_lead_closes += 1; if (!gated) census.family_lead_closes_unflagged += 1; }
      if (/\bmerge[ds]?\b/i.test(t)) census.mentions_merge += 1;
    }
  }

  // THE STAMP-BLOCKED SET — criteria NOBODY can stamp. Reported as `id#index`
  // because the unit here is the CRITERION, not the row: one row can carry one
  // blocked criterion and five stampable ones, and a row-level count hides that.
  const stampBlocked = [];
  for (const v of verdicts) for (const i of v.hits.stamp_blocked) stampBlocked.push(`${v.id}#${i}`);
  stampBlocked.sort();

  const ids = rows.map((r) => r._id).sort();
  return {
    wording_census: census,
    population: {
      statuses: meta.statuses || ["open"],
      per_status: meta.perStatus || null,
      terminal_excluded: TERMINAL,
    },
    // The criteria.ex-wide, unflagged, unmet set: refused to the builder by the
    // WIDE stamp arm and not autostamped for the lead by the STRICT close arm.
    stamp_blocked: stampBlocked,
    stamp_blocked_rows: [...new Set(stampBlocked.map((x) => x.split("#")[0]))].sort(),
    generated_at: new Date().toISOString(),
    mode: meta.mode,
    enumeration: {
      key: "_createdAt",
      strategy: "keyset (>=, dedup by _id)",
      page_size: meta.pageSize,
      effective_page_size: meta.effectivePageSize,
      pages: meta.pages,
      notes: meta.notes,
    },
    total_rows: ids.length,
    id_set_sha256: createHash("sha256").update(ids.join("\n")).digest("hex"),
    counts: Object.fromEntries(Object.entries(byCategory).map(([k, v]) => [k, v.length])),
    // NEVER "applied". These rows are reported with their reason and excluded
    // from anything a later --apply pass would touch.
    unwritable: byCategory[CATEGORY.UNWRITABLE].map((id) => ({
      id, ...UNWRITABLE[id], counted_as_applied: false,
    })),
    unwritable_specimen_table: Object.entries(UNWRITABLE).map(([id, u]) => ({
      id, ...u, still_in_open_enumeration: ids.includes(id),
    })),
    newly_flaggable: byCategory[CATEGORY.FLAGGABLE],
    phrasing_family: byCategory[CATEGORY.PHRASING_FAMILY],
    ids,
  };
}

// ─── THE TWO-DIRECTIONAL PLAN (dry-run only; this module never applies it) ───
// Reconciles the live stamp-blocked set against CLASSIFICATION and emits the
// write each criterion needs. It DOES NOT WRITE, and there is no flag here that
// makes it write: applying is a serialized, post-campaign run, and main's
// 2026-09-07 ruling on bl-merge-gate-flag-backfill-two-directions defers it out
// of any campaign in which many leads close rows concurrently.
//
// A snapshot guarded by a predicate: an UNCLASSIFIED live criterion is a hard
// refusal (exit 2), never a quiet omission — the table cannot rot into silence.
export function buildPlan(report) {
  const live = report.stamp_blocked;
  const unclassified = live.filter((k) => !CLASSIFICATION[k]);
  const drained = Object.keys(CLASSIFICATION).filter((k) => !live.includes(k));
  // HOLD is CLASSIFIED but NEVER WRITTEN. It must be filtered out BEFORE the
  // map, not inside it: `merge_gate: verdict === VERDICT.GATE` would silently
  // turn a HOLD into a `merge_gate:false` write, which is the same fabrication
  // in the other direction. The PLAN selftest arm reds if a HOLD ever reaches
  // `writes`.
  const held = live
    .filter((k) => CLASSIFICATION[k] && CLASSIFICATION[k][0] === VERDICT.HOLD)
    .map((k) => ({ key: k, why: CLASSIFICATION[k][1] }));
  const writes = live
    .filter((k) => CLASSIFICATION[k] && CLASSIFICATION[k][0] !== VERDICT.HOLD)
    .map((k) => {
      const [verdict, why] = CLASSIFICATION[k];
      const [doc_id, idx] = [k.slice(0, k.lastIndexOf("#")), Number(k.slice(k.lastIndexOf("#") + 1))];
      return { key: k, doc_id, index: idx, verdict, merge_gate: verdict === VERDICT.GATE, why };
    });
  return {
    generated_at: new Date().toISOString(),
    applied: false,
    apply_deferred_by: "main, 2026-09-07 — post-campaign, single lane, serialized",
    live_stamp_blocked: live.length,
    classified: writes.length + held.length,
    planned_writes: writes.length,
    held_for_owner: held.length,
    held,
    gate_writes: writes.filter((w) => w.merge_gate === true).length,
    mention_writes: writes.filter((w) => w.merge_gate === false).length,
    unclassified,
    drained_since_classification: drained,
    writes,
  };
}

function compare(pathA, pathB) {
  const a = JSON.parse(readFileSync(pathA, "utf8"));
  const b = JSON.parse(readFileSync(pathB, "utf8"));
  const sa = new Set(a.ids), sb = new Set(b.ids);
  const onlyA = a.ids.filter((x) => !sb.has(x));
  const onlyB = b.ids.filter((x) => !sa.has(x));
  const identical = onlyA.length === 0 && onlyB.length === 0;

  console.log(`sweep A: ${a.total_rows} rows  sha=${a.id_set_sha256.slice(0, 16)}  pages=${a.enumeration.pages}`);
  console.log(`sweep B: ${b.total_rows} rows  sha=${b.id_set_sha256.slice(0, 16)}  pages=${b.enumeration.pages}`);
  console.log(`only in A: ${onlyA.length}${onlyA.length ? "  " + onlyA.join(" ") : ""}`);
  console.log(`only in B: ${onlyB.length}${onlyB.length ? "  " + onlyB.join(" ") : ""}`);
  console.log(`ID SETS ${identical ? "IDENTICAL" : "DISAGREE"}`);
  console.log(`newly flaggable: A=${a.newly_flaggable.length}  B=${b.newly_flaggable.length}`);
  console.log(`phrasing family (nag cannot see): A=${a.phrasing_family.length}  B=${b.phrasing_family.length}`);
  console.log(`unwritable (NEVER counted as applied): A=${a.unwritable.length}  B=${b.unwritable.length}`);
  for (const u of b.unwritable_specimen_table) {
    console.log(`  specimen ${u.id}: ${u.reason} — still open? ${u.still_in_open_enumeration}`);
  }
  return identical ? 0 : 1;
}

// ─── Selftest ────────────────────────────────────────────────────────────────

function selftest() {
  let fails = 0;
  const eq = (name, got, want) => {
    const ok = JSON.stringify(got) === JSON.stringify(want);
    if (!ok) { fails += 1; console.log(`FAIL ${name}\n  got  ${JSON.stringify(got)}\n  want ${JSON.stringify(want)}`); }
    else console.log(`ok   ${name}`);
  };

  const row = (id, ts, crits) => ({ _id: id, _createdAt: ts, acceptance_criteria: crits });
  const mk = (n, base = "2026-01-01T00:00:00.") =>
    Array.from({ length: n }, (_, i) => row(`r${String(i).padStart(4, "0")}`, base + String(i).padStart(6, "0") + "Z", []));

  // A server that pages honestly by keyset.
  const honest = (all, cap = Infinity) => ({ since, limit }) =>
    all.filter((r) => r._createdAt >= since).slice(0, Math.min(limit, cap));

  // CONTROL — the defect this module exists to kill. An offset pager over a
  // collection that mutates mid-sweep loses rows. Proven, so a future reader
  // cannot dismiss the keyset rewrite as taste.
  {
    const all = mk(10);
    let call = 0;
    const offsetPage = ({ offset, limit }) => {
      // Between page 1 and page 2 a concurrent write moves r7 — a row page 2
      // had not reached yet — to the front. It now sits on page 1's range,
      // which was already read, and page 2 steps straight over it.
      const view = call++ === 0 ? all : [all[7], ...all.filter((r) => r !== all[7])];
      return view.slice(offset, offset + limit);
    };
    const got = [...offsetPage({ offset: 0, limit: 5 }), ...offsetPage({ offset: 5, limit: 5 })].map((r) => r._id);
    eq("CONTROL: offset paging over a mutating view loses a row", new Set(got).size, 9);
  }

  {
    const all = mk(7);
    return enumerateKeyset(honest(all), { pageSize: 3 }).then((a) =>
      enumerateKeyset(honest(all), { pageSize: 3 }).then(async (b) => {
        eq("keyset sweep returns every row", a.rows.length, 7);
        eq("two consecutive sweeps agree", a.rows.map((r) => r._id).sort(), b.rows.map((r) => r._id).sort());

        // A silently capped --limit: asked for 10, the server always returns 3.
        const capped = await enumerateKeyset(honest(mk(7), 3), { pageSize: 10 });
        eq("a silent --limit cap does not truncate the sweep", capped.rows.length, 7);
        eq("the cap is NAMED, not swallowed", capped.effectivePageSize, 3);
        eq("the cap note is emitted", capped.notes.length > 0, true);

        // Ties on the stable key are survived, never skipped.
        const tied = [row("t1", "2026-02-02T00:00:00Z", []), row("t2", "2026-02-02T00:00:00Z", []), row("t3", "2026-02-02T00:00:01Z", [])];
        const t = await enumerateKeyset(honest(tied), { pageSize: 2 });
        eq("rows sharing one timestamp are not skipped", t.rows.map((r) => r._id).sort(), ["t1", "t2", "t3"]);

        // Classification.
        const C = (t2) => classifyRow(row("x", "2026-01-01T00:00:00Z", [{ criterion: t2 }])).category;
        eq("leading marker is FLAGGABLE", C("MERGE-GATED (the LEAD closes this): ship it"), CATEGORY.FLAGGABLE);
        eq("bracketed leading marker is FLAGGABLE", C("[MERGE GATED] lead closes"), CATEGORY.FLAGGABLE);
        eq("the 73% family is its OWN category, not FLAGGABLE", C("PR merged (lead closes on merge)"), CATEGORY.PHRASING_FAMILY);
        eq("outcome-shaped gate is the family", C("PR merged to main with all four required contexts green. LEAD closes."), CATEGORY.PHRASING_FAMILY);
        eq("an unrelated criterion is CLEAN", C("the test suite passes"), CATEGORY.CLEAN);
        eq("an explicit flag is FLAGGED",
           classifyRow(row("x", "t", [{ criterion: "whatever", merge_gate: true }])).category, CATEGORY.FLAGGED);
        eq("merge_gate:false is a VETO, not a candidate",
           classifyRow(row("x", "t", [{ criterion: "MERGE-GATED: x", merge_gate: false }])).category, CATEGORY.VETOED);

        // UNWRITABLE outranks FLAGGABLE — the whole point of the category.
        const uid = "gr-backlog-d24-statusmeta-sweep";
        const u = classifyRow(row(uid, "t", [{ criterion: "MERGE-GATED (the LEAD closes this): x" }]));
        eq("a known-unwritable row is UNWRITABLE, not FLAGGABLE", u.category, CATEGORY.UNWRITABLE);
        eq("and it carries its reason", typeof u.unwritable.reason, "string");
        const rep = buildReport([row(uid, "t", [{ criterion: "MERGE-GATED: x" }])], { mode: "selftest", pageSize: 3, effectivePageSize: 3, pages: 1, notes: [] });
        eq("unwritable is never counted as applied", rep.unwritable[0].counted_as_applied, false);
        eq("unwritable is excluded from newly_flaggable", rep.newly_flaggable, []);
        eq("all four specimens are listed", rep.unwritable_specimen_table.length, 4);

        // ── POPULATION ARM ───────────────────────────────────────────────
        // REDS IF THE SWEEP NARROWS BACK TO `open`. A fake server holding one
        // flaggable row per lifecycle status; the union must carry every
        // NON-TERMINAL one. Before 2026-09-16 the live sweep filtered
        // `lifecycle_status=open` and this arm would return 1 of 5.
        const gated = [{ criterion: "MERGE-GATED (the LEAD closes this): the PR is merged" }];
        const byStatus = {
          considering: [row("c1", "2026-03-01T00:00:00Z", gated)],
          researching: [row("rs1", "2026-03-02T00:00:00Z", gated)],
          open:        [row("o1", "2026-03-03T00:00:00Z", gated)],
          in_progress: [row("p1", "2026-03-04T00:00:00Z", gated)],
          blocked:     [row("b1", "2026-03-05T00:00:00Z", gated)],
          done:        [row("d1", "2026-03-06T00:00:00Z", gated)],
          cancelled:   [row("x1", "2026-03-07T00:00:00Z", gated)],
        };
        const pageFor = (st) => honest(byStatus[st] || []);
        const pop = await sweepNonTerminal(pageFor, { pageSize: 3 });
        eq("POPULATION: every non-terminal status is swept, not just `open`",
           pop.rows.map((r) => r._id).sort(), ["b1", "c1", "o1", "p1", "rs1"]);
        eq("POPULATION: the per-status breakdown is reported, not just a total",
           pop.perStatus, { considering: 1, researching: 1, open: 1, in_progress: 1, blocked: 1 });

        // ── QUIET ARM ────────────────────────────────────────────────────
        // The fix must not become "sweep everything". A terminal row cannot be
        // stamp-blocked in any way that matters — nobody is going to stamp it —
        // and counting it would inflate the residue the flag backfill acts on.
        // This arm STAYS QUIET while the population is exactly the five.
        eq("QUIET: terminal rows are NOT enumerated",
           pop.rows.filter((r) => r._id === "d1" || r._id === "x1").length, 0);
        eq("QUIET: the union dedups a row that appears under two statuses",
           (await sweepNonTerminal((st) => honest(st === "open" || st === "blocked" ? [row("dup", "2026-04-01T00:00:00Z", [])] : []),
              { pageSize: 3 })).rows.length, 1);

        // ── STAMP-BLOCKED ARM ────────────────────────────────────────────
        // The nag's LEADING regex is not the regex that refuses a stamp. These
        // three are invisible to MARKER_LEADING and visible to criteria.ex.
        const sb = (crits) => classifyRow(row("s", "t", crits)).hits.stamp_blocked;
        eq("STAMP-BLOCKED: a buried marker blocks a stamp though the nag is blind to it",
           sb([{ criterion: "the close path refuses a MERGE-GATED criterion" }]), [0]);
        eq("STAMP-BLOCKED: the `MERGE GATE` spelling counts (criteria.ex union arm)",
           sb([{ criterion: "BOTH merge_gate SHAPES: the MERGE GATE flag and the wording" }]), [0]);
        eq("STAMP-BLOCKED: a met criterion is NOT blocked from being stamped",
           sb([{ criterion: "MERGE-GATED (the LEAD closes this): merged", met: true }]), []);
        eq("STAMP-BLOCKED: an explicit flag — either value — is never blocked",
           sb([{ criterion: "MERGE-GATED: x", merge_gate: true }, { criterion: "MERGE-GATED: y", merge_gate: false }]), []);
        eq("STAMP-BLOCKED: the phrasing family does NOT match criteria.ex, so it is not blocked",
           sb([{ criterion: "PR merged (lead closes on merge)" }]), []);
        const sbrep = buildReport([row("s1", "t", [{ criterion: "MERGE-GATED: a" }, { criterion: "ok" }, { criterion: "a MERGE GATE is buried here" }])],
                                  { mode: "selftest", pageSize: 3, effectivePageSize: 3, pages: 1, notes: [], statuses: ["open"], perStatus: { open: 1 } });
        eq("STAMP-BLOCKED: reported per CRITERION (id#index), not per row", sbrep.stamp_blocked, ["s1#0", "s1#2"]);
        eq("STAMP-BLOCKED: the row roll-up is deduped", sbrep.stamp_blocked_rows, ["s1"]);

        // ── THE RE-ARM PREDICATE (c4) ─────────────────────────────────────
        const RETIRED = 'CORRECTED 2026-08-20 by the board-reconciliation audit. ORIGINAL WORDING, verbatim: "PR merged into jarl-website main (merge-gated; the lead closes this criterion).". THE CORRECT REQUIREMENT: verifiably present on main, NOT by a merge notification.';
        eq("RE-ARM: the retired quote still trips the stamp guard (this IS the defect)", STAMP_GUARD.test(RETIRED), true);
        eq("RE-ARM: the marker is borrowed from the quotation only", quotesRetiredGateOnly(RETIRED), true);
        eq("RE-ARM: a real declaration is NOT a quote-only match", quotesRetiredGateOnly("MERGE-GATED (the LEAD closes this): PR merged to main"), false);
        eq("RE-ARM: a declaration that also quotes something is NOT quote-only",
           quotesRetiredGateOnly('MERGE-GATED (lead closes): PR merged, per "the usual rules"'), false);
        eq("RE-ARM: text with no marker at all is not a quote-only match", quotesRetiredGateOnly('he said "hello"'), false);
        eq("RE-ARM: non-string is refused, not thrown on", quotesRetiredGateOnly(null), false);
        eq("RE-ARM: the live specimen is classified MENTION, and the predicate agrees",
           [CLASSIFICATION["jf-w1-revendor-honest-media#4"][0], quotesRetiredGateOnly(RETIRED)], [VERDICT.MENTION, true]);

        // ── THE CLASSIFICATION TABLE ──────────────────────────────────────
        eq("CLASSIFY: every entry carries a verdict and a reason",
           Object.values(CLASSIFICATION).every((v) => Object.values(VERDICT).includes(v[0]) && typeof v[1] === "string" && v[1].length > 0), true);
        eq("CLASSIFY: the split is 17 GATE / 6 MENTION / 2 HOLD after the 2026-09-18 second read",
           [Object.values(CLASSIFICATION).filter((v) => v[0] === VERDICT.GATE).length,
            Object.values(CLASSIFICATION).filter((v) => v[0] === VERDICT.MENTION).length], [17, 6]);
        eq("CLASSIFY: the second reader's HOLD bucket exists and is non-empty",
           Object.values(CLASSIFICATION).filter((v) => v[0] === VERDICT.HOLD).length, 2);
        eq("CLASSIFY: every key is <doc_id>#<index>",
           Object.keys(CLASSIFICATION).every((k) => /^[^#]+#\d+$/.test(k)), true);

        // ── THE PLAN, AND ITS STALENESS GUARD ─────────────────────────────
        const planRep = (blocked) => ({ stamp_blocked: blocked });
        const allKeys = Object.keys(CLASSIFICATION);
        const pFull = buildPlan(planRep(allKeys));
        eq("PLAN: writes both directions, never one", [pFull.gate_writes, pFull.mention_writes], [17, 6]);
        eq("PLAN: it is a plan — nothing is applied", pFull.applied, false);
        eq("PLAN: a GATE entry plans merge_gate:true", pFull.writes.find((w) => w.key === "task-c7e10834d493da6f#2").merge_gate, true);
        eq("PLAN: a MENTION entry plans merge_gate:false — the one-field veto, not a reword",
           pFull.writes.find((w) => w.key === "jf-w1-revendor-honest-media#4").merge_gate, false);
        eq("PLAN: the key splits on the LAST # so a doc_id may contain one",
           buildPlan(planRep([])).writes.length === 0 &&
           pFull.writes.every((w) => `${w.doc_id}#${w.index}` === w.key), true);
        const pNew = buildPlan(planRep([...allKeys, "brand-new-row#0"]));
        eq("PLAN: an UNCLASSIFIED live criterion is named, never silently dropped", pNew.unclassified, ["brand-new-row#0"]);
        const pDrain = buildPlan(planRep(allKeys.slice(1)));
        eq("PLAN: a criterion that drained since classification is named too", pDrain.drained_since_classification, [allKeys[0]]);
        eq("PLAN: a drained entry is NOT planned as a write", pDrain.writes.some((w) => w.key === allKeys[0]), false);

        // ── HOLD: CLASSIFIED, NEVER WRITTEN ───────────────────────────────
        // The failure this guards is not an omission but a SILENT DOWNGRADE:
        // `merge_gate: verdict === VERDICT.GATE` maps HOLD to `false`, so a HOLD
        // that reaches `writes` is planned as a veto nobody decided on.
        const holdKeys = Object.keys(CLASSIFICATION).filter((k) => CLASSIFICATION[k][0] === VERDICT.HOLD);
        eq("HOLD: a held criterion is NEVER planned as a write, in either direction",
           pFull.writes.some((w) => holdKeys.includes(w.key)), false);
        eq("HOLD: every held criterion is surfaced by name for the owner",
           pFull.held.map((h) => h.key).sort(), holdKeys.slice().sort());
        eq("HOLD: a held criterion is CLASSIFIED, so the staleness guard stays quiet",
           pFull.unclassified.length, 0);
        eq("HOLD: classified counts writes AND holds; planned_writes counts only writes",
           [pFull.classified, pFull.planned_writes, pFull.held_for_owner],
           [Object.keys(CLASSIFICATION).length, Object.keys(CLASSIFICATION).length - holdKeys.length, holdKeys.length]);

        console.log(fails === 0 ? "\nSELFTEST PASS" : `\nSELFTEST FAIL (${fails})`);
        process.exit(fails === 0 ? 0 : 1);
      }));
  }
}

// ─── main ────────────────────────────────────────────────────────────────────

/**
 * TWO CONSECUTIVE SWEEPS, one command, quotable output.
 *
 * Sweep 1 and sweep 2 must return the IDENTICAL id set — that is the property
 * offset paging did not have (26 rows of disagreement between two sweeps taken
 * minutes apart, 2026-08-23). The residue count must also be IDENTICAL, which
 * is the DRY-RUN form of idempotence: a second pass discovers nothing the first
 * did not. The SIMULATED-APPLY arm then shows what a real apply leaves behind —
 * it is labelled SIMULATED because this module deliberately does not write.
 */
async function runTwice(argv) {
  const psi = argv.indexOf("--page-size");
  const pageSize = psi === -1 ? PAGE_SIZE : Number(argv[psi + 1]);
  const sweep = async (n) => {
    const res = await sweepNonTerminal(livePageFor, { pageSize });
    const rep = buildReport(res.rows, { mode: "DRY-RUN", pageSize, effectivePageSize: res.effectivePageSize, pages: res.pages, notes: res.notes, statuses: res.statuses, perStatus: res.perStatus });
    console.log(`SWEEP ${n}: rows=${rep.total_rows} pages=${rep.enumeration.pages} sha256=${rep.id_set_sha256}`);
    console.log(`SWEEP ${n}: per_status=${JSON.stringify(rep.population.per_status)}`);
    console.log(`SWEEP ${n}: stamp_blocked=${rep.stamp_blocked.length} newly_flaggable=${rep.newly_flaggable.length} phrasing_family=${rep.phrasing_family.length} unwritable=${rep.unwritable.length}`);
    return { rep, rows: res.rows };
  };
  const a = await sweep(1);
  const b = await sweep(2);
  const sa = new Set(a.rep.ids), sb = new Set(b.rep.ids);
  const onlyA = a.rep.ids.filter((x) => !sb.has(x));
  const onlyB = b.rep.ids.filter((x) => !sa.has(x));
  console.log(`DELTA: only-in-1=${onlyA.length} only-in-2=${onlyB.length}  ID SETS ${onlyA.length + onlyB.length === 0 ? "IDENTICAL" : "DISAGREE"}`);
  console.log(`DELTA: newly_flaggable 1->2 = ${a.rep.newly_flaggable.length} -> ${b.rep.newly_flaggable.length}`);
  console.log(`DELTA: stamp_blocked 1->2 = ${a.rep.stamp_blocked.length} -> ${b.rep.stamp_blocked.length}`);
  for (const x of b.rep.stamp_blocked) console.log(`  STAMP-BLOCKED ${x}`);

  // SIMULATED APPLY. Flip merge_gate on exactly the rows sweep 1 called
  // FLAGGABLE — in memory, on the rows already read — and re-classify. A real
  // apply pass is bl-merge-gate-flag-backfill-two-directions; this arm proves
  // only that the RESIDUE PREDICATE converges, which is what a random-residue
  // enumerator could never show.
  const target = new Set(a.rep.newly_flaggable);
  const applied = b.rows.map((r) => {
    if (!target.has(r._id)) return r;
    return { ...r, acceptance_criteria: (r.acceptance_criteria || []).map((c) =>
      (c && typeof c === "object" && typeof c.criterion === "string" && MARKER_LEADING.test(c.criterion) && c.merge_gate !== false)
        ? { ...c, merge_gate: true } : c) };
  });
  const after = buildReport(applied, { mode: "SIMULATED-APPLY", pageSize, effectivePageSize: b.rep.enumeration.effective_page_size, pages: b.rep.enumeration.pages, notes: [], statuses: b.rep.population.statuses, perStatus: b.rep.population.per_status });
  console.log(`SIMULATED-APPLY: newly_flaggable after applying sweep 1's ${target.size} rows = ${after.newly_flaggable.length}`);
  console.log(`SIMULATED-APPLY: unwritable still NOT counted as applied = ${after.unwritable.length}`);
  console.log(`WORDING CENSUS (${b.rep.population.statuses.join(",")}): ${JSON.stringify(b.rep.wording_census)}`);
  process.exit(onlyA.length + onlyB.length === 0 ? 0 : 1);
}

async function main(argv) {
  if (argv.includes("--selftest")) return selftest();
  const ci = argv.indexOf("--compare");
  if (ci !== -1) process.exit(compare(argv[ci + 1], argv[ci + 2]));

  if (argv.includes("--apply") && !argv.includes("--i-am-the-flag-backfill-owner")) {
    console.error(
      "refusing --apply: writing merge_gate onto live rows is bl-merge-gate-flag-backfill-two-directions,\n" +
      "not this row. This module is the ENUMERATOR. Pass --i-am-the-flag-backfill-owner if you own that work.");
    process.exit(2);
  }

  if (argv.includes("--twice")) return runTwice(argv);

  if (argv.includes("--plan")) {
    const r = await sweepNonTerminal(livePageFor, { pageSize: PAGE_SIZE });
    const rep = buildReport(r.rows, {
      mode: "PLAN (DRY-RUN)", pageSize: PAGE_SIZE, effectivePageSize: r.effectivePageSize,
      pages: r.pages, notes: r.notes, statuses: r.statuses, perStatus: r.perStatus,
    });
    const plan = buildPlan(rep);
    console.log(`live stamp-blocked: ${plan.live_stamp_blocked}   classified: ${plan.classified}`);
    console.log(`PLAN  merge_gate:true  -> ${plan.gate_writes}`);
    console.log(`PLAN  merge_gate:false -> ${plan.mention_writes}`);
    console.log(`HOLD  no write either way -> ${plan.held_for_owner}`);
    for (const w of plan.writes) console.log(`  ${w.merge_gate ? "TRUE " : "FALSE"}  ${w.key}  ${w.why}`);
    for (const h of plan.held) console.log(`  HOLD   ${h.key}  ${h.why}`);
    if (plan.drained_since_classification.length) {
      console.log(`DRAINED since classification (${plan.drained_since_classification.length}): ${plan.drained_since_classification.join(" ")}`);
    }
    const pi = argv.indexOf("--out");
    if (pi !== -1) { writeFileSync(argv[pi + 1], JSON.stringify(plan, null, 2)); console.log(`wrote ${argv[pi + 1]}`); }
    if (plan.unclassified.length) {
      console.error(`REFUSING: ${plan.unclassified.length} live stamp-blocked criteria are UNCLASSIFIED — classify them BY HAND before any apply:`);
      for (const k of plan.unclassified) console.error(`  ${k}`);
      process.exit(2);
    }
    console.log("NOT APPLIED — " + plan.apply_deferred_by);
    return;
  }

  const oi = argv.indexOf("--out");
  const psi = argv.indexOf("--page-size");
  const pageSize = psi === -1 ? PAGE_SIZE : Number(argv[psi + 1]);

  const res = await sweepNonTerminal(livePageFor, { pageSize });
  const report = buildReport(res.rows, {
    mode: argv.includes("--apply") ? "APPLY" : "DRY-RUN",
    pageSize, effectivePageSize: res.effectivePageSize, pages: res.pages, notes: res.notes,
    statuses: res.statuses, perStatus: res.perStatus,
  });

  console.log(`population=${report.population.statuses.join(",")}  per_status=${JSON.stringify(report.population.per_status)}`);
  console.log(`mode=${report.mode}  key=_createdAt  pages=${report.enumeration.pages}  page_size=${pageSize}` +
              (report.enumeration.effective_page_size !== pageSize ? ` (server cap ${report.enumeration.effective_page_size})` : ""));
  for (const n of report.enumeration.notes) console.log(`NOTE: ${n}`);
  console.log(`open rows enumerated: ${report.total_rows}   id-set sha256: ${report.id_set_sha256}`);
  for (const [k, v] of Object.entries(report.counts)) console.log(`  ${k.padEnd(16)} ${v}`);
  console.log(`STAMP-BLOCKED (criteria.ex wide predicate, no flag, unmet): ${report.stamp_blocked.length} criteria across ${report.stamp_blocked_rows.length} rows`);
  for (const x of report.stamp_blocked) console.log(`    ${x}`);
  console.log(`newly flaggable this run: ${report.newly_flaggable.length}`);
  console.log(`phrasing family the AUTHORING nag cannot see: ${report.phrasing_family.length}`);
  for (const u of report.unwritable_specimen_table) {
    console.log(`  UNWRITABLE specimen ${u.id}\n    reason: ${u.reason}\n    still in open enumeration: ${u.still_in_open_enumeration}   counted as applied: false`);
  }
  if (oi !== -1) { writeFileSync(argv[oi + 1], JSON.stringify(report, null, 2)); console.log(`wrote ${argv[oi + 1]}`); }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main(process.argv.slice(2)).catch((e) => { console.error(String(e && e.message || e)); process.exit(1); });
}
