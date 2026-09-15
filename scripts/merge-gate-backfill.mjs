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
  const hits = { flagged: [], vetoed: [], flaggable: [], phrasing: [] };

  crits.forEach((c, idx) => {
    if (!c || typeof c !== "object") return;
    const text = typeof c.criterion === "string" ? c.criterion : "";
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

function livePage({ since, limit }) {
  return bpQuery([
    "doc", "query", "task",
    "--filter", "lifecycle_status=open",
    "--filter", `_createdAt>=${since}`,
    "--order", "_createdAt:asc",
    "--limit", String(limit),
    "--fields", "acceptance_criteria,title,lifecycle_status",
    "-o", "json",
  ]);
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

  const ids = rows.map((r) => r._id).sort();
  return {
    wording_census: census,
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
    const res = await enumerateKeyset(livePage, { pageSize });
    const rep = buildReport(res.rows, { mode: "DRY-RUN", pageSize, effectivePageSize: res.effectivePageSize, pages: res.pages, notes: res.notes });
    console.log(`SWEEP ${n}: rows=${rep.total_rows} pages=${rep.enumeration.pages} sha256=${rep.id_set_sha256}`);
    console.log(`SWEEP ${n}: newly_flaggable=${rep.newly_flaggable.length} phrasing_family=${rep.phrasing_family.length} unwritable=${rep.unwritable.length}`);
    return { rep, rows: res.rows };
  };
  const a = await sweep(1);
  const b = await sweep(2);
  const sa = new Set(a.rep.ids), sb = new Set(b.rep.ids);
  const onlyA = a.rep.ids.filter((x) => !sb.has(x));
  const onlyB = b.rep.ids.filter((x) => !sa.has(x));
  console.log(`DELTA: only-in-1=${onlyA.length} only-in-2=${onlyB.length}  ID SETS ${onlyA.length + onlyB.length === 0 ? "IDENTICAL" : "DISAGREE"}`);
  console.log(`DELTA: newly_flaggable 1->2 = ${a.rep.newly_flaggable.length} -> ${b.rep.newly_flaggable.length}`);

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
  const after = buildReport(applied, { mode: "SIMULATED-APPLY", pageSize, effectivePageSize: b.rep.enumeration.effective_page_size, pages: b.rep.enumeration.pages, notes: [] });
  console.log(`SIMULATED-APPLY: newly_flaggable after applying sweep 1's ${target.size} rows = ${after.newly_flaggable.length}`);
  console.log(`SIMULATED-APPLY: unwritable still NOT counted as applied = ${after.unwritable.length}`);
  console.log(`WORDING CENSUS (open rows only): ${JSON.stringify(b.rep.wording_census)}`);
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

  const oi = argv.indexOf("--out");
  const psi = argv.indexOf("--page-size");
  const pageSize = psi === -1 ? PAGE_SIZE : Number(argv[psi + 1]);

  const res = await enumerateKeyset(livePage, { pageSize });
  const report = buildReport(res.rows, {
    mode: argv.includes("--apply") ? "APPLY" : "DRY-RUN",
    pageSize, effectivePageSize: res.effectivePageSize, pages: res.pages, notes: res.notes,
  });

  console.log(`mode=${report.mode}  key=_createdAt  pages=${report.enumeration.pages}  page_size=${pageSize}` +
              (report.enumeration.effective_page_size !== pageSize ? ` (server cap ${report.enumeration.effective_page_size})` : ""));
  for (const n of report.enumeration.notes) console.log(`NOTE: ${n}`);
  console.log(`open rows enumerated: ${report.total_rows}   id-set sha256: ${report.id_set_sha256}`);
  for (const [k, v] of Object.entries(report.counts)) console.log(`  ${k.padEnd(16)} ${v}`);
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
