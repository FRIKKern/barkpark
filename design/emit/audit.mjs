// design/emit/audit.mjs — the audit verb table.
// Part of design/emit.mjs, the W1.2 emitter, moved here with no change in behaviour.
// design/emit.mjs imports this module and re-exports its public names.

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { repoRoot } from "./source.mjs";

// ── the audit verb table (charter cch-w65; moved into the image cch-w69-s1) ──
// cloud/priv/audit-actions.json is the SOLE authority for the audit register's
// verb vocabulary. It lives under cloud/priv — NOT design/ — because its Elixir
// consumer compile-time-reads it inside the control-plane image build, and that
// image is built from cloud/ alone (D841/D842: the design/ home broke every cp
// deploy). Two artifacts read it and NEITHER reads the other:
//
//   • cloud/lib/barkpark_cloud/accounts/audit_event.ex derives @actions from
//     `actions[].verb` at COMPILE time (@external_resource + Jason.decode!), so
//     validate_inclusion(:action, @actions) still enforces the identical closed set.
//   • cloud/priv/static/app.js's ACTION_LABELS is the generated region below,
//     built from `actions[].label`.
//
// A row IS the declaration and its label rides ON that row, so there is no place
// to write a label for a verb the vocabulary does not declare — the shape makes
// that state unrepresentable rather than merely checked. `label: null` is the
// honest case charter D582 blessed (humanAction falls back to the raw dotted
// slug), but a null must CARRY its rationale: `reason_code` from the closed set
// the manifest itself declares, plus a `reason` that names the open row owning
// the copy (or, for a producerless verb, the census allowlist excusing it). That
// turns "unlabelled on purpose" from a discipline into a gate.
export const AUDIT_ACTIONS_PATH = "cloud/priv/audit-actions.json";
const VERB_RE = /^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$/;
const REASON_MIN = 60;
// Per-code predicates the `reason` prose must satisfy. A minimum length alone
// buys mush; each code has to point at something that can rot loudly — the same
// property the Elixir census's @producerless anchor/blocker pair carries.
const REASON_MUST_CITE = {
  "d582-copy-not-written": {
    re: /cch-w\d+-[a-z0-9-]+/,
    what: "the `cch-w…` slug of the open row that owns the copy",
  },
  "no-producer": {
    re: /@producerless/,
    what: "`@producerless` — the census allowlist that already excuses the verb by name",
  },
};

let auditActionsCache = null;
export function auditActions() {
  if (auditActionsCache) return auditActionsCache;
  const abs = join(repoRoot, AUDIT_ACTIONS_PATH);
  let table;
  try { table = JSON.parse(readFileSync(abs, "utf8")); }
  catch (e) { throw new Error(`${AUDIT_ACTIONS_PATH} is unreadable or not valid JSON: ${e.message}`); }
  const codes = table.reason_codes;
  if (!codes || typeof codes !== "object")
    throw new Error(`${AUDIT_ACTIONS_PATH} declares no \`reason_codes\` object — the closed set every null label must name.`);
  for (const code of Object.keys(codes)) {
    if (!REASON_MUST_CITE[code])
      throw new Error(`${AUDIT_ACTIONS_PATH} declares reason_code ${JSON.stringify(code)} with no predicate in emit.mjs' REASON_MUST_CITE — a code nothing checks is a sentence with no exit code.`);
  }
  const rows = table.actions;
  if (!Array.isArray(rows) || rows.length === 0)
    throw new Error(`${AUDIT_ACTIONS_PATH} has no \`actions\` array — the whole vocabulary would read as empty and every downstream gate would go vacuous.`);

  const seen = new Set();
  for (const row of rows) {
    const at = `${AUDIT_ACTIONS_PATH} row ${JSON.stringify(row?.verb ?? row)}`;
    if (!row || typeof row !== "object" || Array.isArray(row))
      throw new Error(`${AUDIT_ACTIONS_PATH}: every entry of \`actions\` must be an object; found ${JSON.stringify(row)}.`);
    if (typeof row.verb !== "string" || !VERB_RE.test(row.verb))
      throw new Error(`${at}: \`verb\` must be a dotted <noun>.<verb> slug matching ${VERB_RE}.`);
    if (seen.has(row.verb))
      throw new Error(`${at}: declared twice. The vocabulary is a set; a duplicate row means one of the two labels is dead.`);
    seen.add(row.verb);
    if (!("label" in row))
      throw new Error(`${at}: no \`label\` key at all. Every declared verb states its console label EXPLICITLY — a string, or null WITH \`reason_code\` + \`reason\`. An absent key is the silent third state this table exists to remove.`);
    if (row.label !== null && (typeof row.label !== "string" || row.label.trim() === ""))
      throw new Error(`${at}: \`label\` must be a non-empty string or null; found ${JSON.stringify(row.label)}.`);
    if (row.label === null) {
      const code = row.reason_code;
      if (!code || !Object.prototype.hasOwnProperty.call(codes, code))
        throw new Error(`${at}: \`label\` is null, so it needs a \`reason_code\` from the declared set [${Object.keys(codes).join(", ")}]; found ${JSON.stringify(code)}.`);
      if (typeof row.reason !== "string" || row.reason.trim().length < REASON_MIN)
        throw new Error(`${at}: \`label\` is null, so it needs a \`reason\` of at least ${REASON_MIN} characters saying why. Found ${JSON.stringify(row.reason)}.`);
      const { re, what } = REASON_MUST_CITE[code];
      if (!re.test(row.reason))
        throw new Error(`${at}: reason_code ${JSON.stringify(code)} requires the \`reason\` to cite ${what} (${re}). It does not, so the excuse points at nothing and cannot rot loudly.`);
    } else if ("reason_code" in row || "reason" in row) {
      throw new Error(`${at}: carries a label AND a reason_code/reason. A labelled verb needs no excuse — drop them, or the next reader cannot tell which state is live.`);
    }
    if ("note" in row && !(Array.isArray(row.note) && row.note.every((l) => typeof l === "string")))
      throw new Error(`${at}: \`note\` must be an array of single-line strings (each is emitted as one \`//\` comment above the entry).`);
  }
  auditActionsCache = rows;
  return rows;
}

// The cloud SPA's ACTION_LABELS body (app.js). Only LABELLED verbs get an entry —
// humanAction(a) returns ACTION_LABELS[a] || a, so a null row is served by that
// documented fallback and needs no key (D582). The unlabelled count is emitted as
// ONE derived comment line rather than a hand-typed figure, so the number in the
// shipped artifact cannot drift from the table the way 55-vs-56 did. Indented 4
// spaces to sit inside the object literal in the IIFE; no trailing comma and no
// trailing newline (the marker's END line carries it).
export function auditActionLabels(rows = auditActions()) {
  const labelled = rows.filter((r) => r.label !== null);
  const lines = [
    `    // ${rows.length - labelled.length} of the ${rows.length} declared verbs have no entry here: they render`,
    `    // as their raw dotted slug through humanAction's fallback below, each one`,
    // This line is part of the generated region shipped in app.js; it is now
    // repointed to cloud/priv/audit-actions.json (the table moved there in
    // #11781) by cch-w53 in the same commit that hand-edits the marker line.
    `    // declared unlabelled ON PURPOSE with a reason in ${AUDIT_ACTIONS_PATH}`,
    `    // (charter D582 — ugly, not false).`,
  ];
  labelled.forEach((r, i) => {
    for (const l of r.note ?? []) lines.push(`    // ${l}`);
    lines.push(`    ${JSON.stringify(r.verb)}: ${JSON.stringify(r.label)}${i === labelled.length - 1 ? "" : ","}`);
  });
  return lines.join("\n");
}
