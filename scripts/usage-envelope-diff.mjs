#!/usr/bin/env node
// usage-envelope-diff.mjs — compare TEMPORALLY ADJACENT `usage_samples` rows of
// the same barkpark and name, per meter and per key, what changed in the
// stored `envelope` jsonb between them (task-ce383752422a5715).
//
// WHY THIS EXISTS, AND WHY IT LIVES OUTSIDE cloud/
//
// A meter that stops carrying `unavailable_reason` is not a fact any single
// sample can state: `Usage.compose/1` is stateless, and a meter that nobody
// attempted to read is the deliberate `"unmetered"` value with NO
// `unavailable_reason` key at all (cloud/lib/barkpark_cloud/
// unavailable_vocabulary.ex, the `no_admin_token` / `not_live` rows). So the
// change is only visible ACROSS two ticks. The one multi-tick read a consumer
// has — GET /v1/barkparks/:id/usage/history, `UsageHistoryPoint{At, Value}` in
// internal/cloudclient — is value-only and drops the reason by construction.
// This tool reads the envelope ITSELF, row by row, so a change confined to
// `envelope->'meters'-><meter>->'unavailable_reason'` is seen even when every
// numeric `value` is byte-identical.
//
// FEEDING IT REAL ROWS (read-only; run it yourself, the tool opens no DB):
//
//   psql "$CLOUD_DATABASE_URL" -X -At -v ON_ERROR_STOP=1 \
//     -c "SET default_transaction_read_only = on" \
//     -c "SELECT json_build_object('barkpark_id', barkpark_id,
//                                  'measured_at', measured_at,
//                                  'envelope', envelope)
//           FROM usage_samples
//          WHERE barkpark_id = '<uuid>'
//          ORDER BY measured_at" \
//     > rows.jsonl
//   node scripts/usage-envelope-diff.mjs rows.jsonl          # or: … < rows.jsonl
//
// One JSON object per line: {barkpark_id, measured_at, envelope}. Rows may
// arrive in any order and for several barkparks; the tool groups by
// barkpark_id and sorts by measured_at itself, so "adjacent" is decided here,
// not by the query. `measured_at` is `timestamp without time zone`
// (:utc_datetime_usec), which json_build_object prints with NO offset; a
// timestamp without an offset is read as UTC, never as local time.
//
// WHAT A PAIR IS, AND WHAT IT IS NOT
//
//   no_predecessor  the earliest row of a barkpark in the INPUT. Not provably
//                   the first-ever sample: AgentRetentionWorker prunes rows
//                   older than 14 days, so the window's oldest row usually had
//                   a predecessor that is gone. Nothing is diffed against it.
//   adjacent        two consecutive rows whose spacing is at most 1.5 sampler
//                   intervals (`--tick-minutes`, default 15 — the crontab in
//                   cloud/config/config.exs is `7,22,37,52 * * * *`).
//   gap             two consecutive rows further apart than that: at least one
//                   tick is missing BETWEEN them. The diff is still printed,
//                   but a transition across a gap is never given the adjacent
//                   name — the missing tick(s) may have carried anything. A
//                   missing tick is task-c3f032420b41329a's axis (a hole in the
//                   series); this tool only labels it so the two never conflate.
//
// THE NAMED TRANSITIONS (per meter, over `unavailable_reason` + `value`)
//
//   silent_restore            reason-bearing -> reasonless "unmetered", across
//                             ADJACENT ticks. The meter stopped attempting a
//                             read and nothing on the wire says so: the
//                             blind-era byte shape (charter D505) restored.
//   reason_cleared_across_gap the same before/after, but across a gap.
//   reason_cleared_to_value   reason-bearing -> a measured value.
//   reason_raised             no reason -> a reason.
//   reason_changed            one reason -> a different reason.
//
// OUTPUT: one human line per finding, or `--json` for one JSON object per pair.
// Exit 0 on a completed read, 2 when the input cannot be read or parsed.

import fs from "node:fs";
import { fileURLToPath } from "node:url";

export const UNMETERED = "unmetered";
export const DEFAULT_TICK_MINUTES = 15;

const isObject = (v) => v !== null && typeof v === "object" && !Array.isArray(v);

// Deep equality over JSON values. Key ORDER is irrelevant (jsonb does not keep
// it), but 12 and 12.0 are the same JSON number and compare equal.
function sameJson(a, b) {
  if (a === b) return true;
  if (Array.isArray(a) || Array.isArray(b)) {
    if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length) return false;
    return a.every((x, i) => sameJson(x, b[i]));
  }
  if (isObject(a) && isObject(b)) {
    const ka = Object.keys(a);
    if (ka.length !== Object.keys(b).length) return false;
    return ka.every((k) => Object.hasOwn(b, k) && sameJson(a[k], b[k]));
  }
  return false;
}

// Per-key differences between two objects: added / removed / changed, each
// named. `own` distinguishes "key absent" from "key present with null".
function keyDiff(before, after) {
  const out = [];
  const keys = [...new Set([...Object.keys(before), ...Object.keys(after)])].sort();
  for (const key of keys) {
    const inB = Object.hasOwn(before, key);
    const inA = Object.hasOwn(after, key);
    if (inB && !inA) out.push({ key, change: "removed", before: before[key] });
    else if (!inB && inA) out.push({ key, change: "added", after: after[key] });
    else if (!sameJson(before[key], after[key]))
      out.push({ key, change: "changed", before: before[key], after: after[key] });
  }
  return out;
}

/**
 * Every difference between two stored envelopes, BY NAME.
 * Meter-scoped entries carry `meter`; a meter that appeared or disappeared as a
 * whole is `meter_added` / `meter_removed` (key: null). Any top-level key other
 * than `meters` is diffed too, with `meter: null`.
 */
export function diffEnvelopes(prev, cur) {
  if (!isObject(prev) || !isObject(cur)) throw new TypeError("envelope must be a JSON object");
  const changes = [];
  const { meters: pm = {}, ...prestTop } = prev;
  const { meters: cm = {}, ...crestTop } = cur;
  for (const d of keyDiff(prestTop, crestTop)) changes.push({ meter: null, ...d });
  if (!isObject(pm) || !isObject(cm)) throw new TypeError("envelope.meters must be a JSON object");
  const names = [...new Set([...Object.keys(pm), ...Object.keys(cm)])].sort();
  for (const meter of names) {
    const inP = Object.hasOwn(pm, meter);
    const inC = Object.hasOwn(cm, meter);
    if (inP && !inC) changes.push({ meter, key: null, change: "meter_removed", before: pm[meter] });
    else if (!inP && inC) changes.push({ meter, key: null, change: "meter_added", after: cm[meter] });
    else if (isObject(pm[meter]) && isObject(cm[meter]))
      for (const d of keyDiff(pm[meter], cm[meter])) changes.push({ meter, ...d });
    else if (!sameJson(pm[meter], cm[meter]))
      changes.push({ meter, key: null, change: "changed", before: pm[meter], after: cm[meter] });
  }
  return changes;
}

const reasonOf = (m) => (isObject(m) && Object.hasOwn(m, "unavailable_reason") ? m.unavailable_reason : undefined);

/**
 * The named reason transitions between two envelopes. `adjacency` is
 * "adjacent" or "gap"; only an adjacent pair can yield `silent_restore`.
 */
export function reasonTransitions(prev, cur, adjacency) {
  const pm = isObject(prev?.meters) ? prev.meters : {};
  const cm = isObject(cur?.meters) ? cur.meters : {};
  const out = [];
  for (const meter of Object.keys(cm).sort()) {
    if (!Object.hasOwn(pm, meter)) continue;
    const before = reasonOf(pm[meter]);
    const after = reasonOf(cm[meter]);
    if (before === undefined && after === undefined) continue;
    let name;
    if (before !== undefined && after === undefined) {
      if (cm[meter]?.value === UNMETERED)
        name = adjacency === "adjacent" ? "silent_restore" : "reason_cleared_across_gap";
      else name = "reason_cleared_to_value";
    } else if (before === undefined) name = "reason_raised";
    else if (before !== after) name = "reason_changed";
    else continue;
    out.push({ meter, transition: name, reason_before: before ?? null, reason_after: after ?? null, value_after: cm[meter]?.value });
  }
  return out;
}

// `timestamp without time zone` arrives with no offset; read it as UTC.
export function parseMeasuredAt(s) {
  if (typeof s !== "string") return NaN;
  const hasOffset = /(Z|[+-]\d{2}:?\d{2})$/i.test(s.trim());
  return Date.parse(hasOffset ? s : `${s}Z`);
}

/**
 * Group rows by barkpark, order by measured_at, and walk consecutive pairs.
 * Yields one record per row: `no_predecessor` for each barkpark's earliest
 * row, then a `pair` for every later one.
 */
export function walkSamples(rows, { tickMinutes = DEFAULT_TICK_MINUTES } = {}) {
  const tickMs = tickMinutes * 60_000;
  const byBarkpark = new Map();
  for (const [i, row] of rows.entries()) {
    if (!isObject(row) || typeof row.barkpark_id !== "string" || !isObject(row.envelope))
      throw new TypeError(`row ${i + 1}: need {barkpark_id, measured_at, envelope}`);
    const t = parseMeasuredAt(row.measured_at);
    if (Number.isNaN(t)) throw new TypeError(`row ${i + 1}: unparseable measured_at ${JSON.stringify(row.measured_at)}`);
    if (!byBarkpark.has(row.barkpark_id)) byBarkpark.set(row.barkpark_id, []);
    byBarkpark.get(row.barkpark_id).push({ ...row, t });
  }
  const out = [];
  for (const id of [...byBarkpark.keys()].sort()) {
    const series = byBarkpark.get(id).sort((a, b) => a.t - b.t);
    out.push({ barkpark_id: id, kind: "no_predecessor", measured_at: series[0].measured_at });
    for (let i = 1; i < series.length; i++) {
      const prev = series[i - 1];
      const cur = series[i];
      const spacing = cur.t - prev.t;
      const adjacency = spacing <= 1.5 * tickMs ? "adjacent" : "gap";
      out.push({
        barkpark_id: id,
        kind: "pair",
        adjacency,
        missed_ticks: adjacency === "gap" ? Math.max(1, Math.round(spacing / tickMs) - 1) : 0,
        prev_measured_at: prev.measured_at,
        measured_at: cur.measured_at,
        transitions: reasonTransitions(prev.envelope, cur.envelope, adjacency),
        changes: diffEnvelopes(prev.envelope, cur.envelope),
      });
    }
  }
  return out;
}

const show = (v) => (v === undefined ? "∅" : JSON.stringify(v));

export function formatRecord(r) {
  if (r.kind === "no_predecessor")
    return [`${r.barkpark_id} ${r.measured_at} no_predecessor (earliest row in the input; nothing to compare)`];
  const head = `${r.barkpark_id} ${r.prev_measured_at} -> ${r.measured_at}`;
  const lines = [];
  if (r.adjacency === "gap") lines.push(`${head} GAP ~${r.missed_ticks} missed tick(s)`);
  for (const t of r.transitions)
    lines.push(`${head} TRANSITION ${t.transition} meter=${t.meter} reason ${show(t.reason_before ?? undefined)} -> ${show(t.reason_after ?? undefined)} value_after=${show(t.value_after)}`);
  for (const c of r.changes) {
    const where = c.meter === null ? `envelope.${c.key}` : c.key === null ? `meter=${c.meter}` : `meter=${c.meter} key=${c.key}`;
    const vals = c.change === "added" || c.change === "meter_added" ? show(c.after)
      : c.change === "removed" || c.change === "meter_removed" ? show(c.before)
      : `${show(c.before)} -> ${show(c.after)}`;
    lines.push(`${head} ${c.change} ${where} ${vals}`);
  }
  if (lines.length === 0) lines.push(`${head} ${r.adjacency} no change`);
  return lines;
}

export function parseJsonl(text) {
  const rows = [];
  for (const [i, line] of text.split("\n").entries()) {
    if (line.trim() === "") continue;
    try {
      rows.push(JSON.parse(line));
    } catch (e) {
      throw new TypeError(`line ${i + 1}: not JSON (${e.message})`);
    }
  }
  return rows;
}

function main(argv) {
  let json = false;
  let tickMinutes = DEFAULT_TICK_MINUTES;
  let file = null;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--json") json = true;
    else if (a === "--tick-minutes") tickMinutes = Number(argv[++i]);
    else if (a === "-h" || a === "--help") {
      process.stdout.write("usage: usage-envelope-diff.mjs [--json] [--tick-minutes N] [rows.jsonl]\n");
      return 0;
    } else if (file === null) file = a;
    else {
      process.stderr.write(`usage-envelope-diff: unexpected argument ${a}\n`);
      return 2;
    }
  }
  if (!(tickMinutes > 0)) {
    process.stderr.write("usage-envelope-diff: --tick-minutes must be a positive number\n");
    return 2;
  }
  let records;
  try {
    const text = fs.readFileSync(file ?? 0, "utf8");
    records = walkSamples(parseJsonl(text), { tickMinutes });
  } catch (e) {
    process.stderr.write(`usage-envelope-diff: ${e.message}\n`);
    return 2;
  }
  for (const r of records) process.stdout.write(json ? `${JSON.stringify(r)}\n` : `${formatRecord(r).join("\n")}\n`);
  return 0;
}

if (process.argv[1] && fileURLToPath(import.meta.url) === fs.realpathSync(process.argv[1])) {
  process.exitCode = main(process.argv.slice(2));
}
