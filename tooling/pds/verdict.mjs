// verdict.mjs — THE LINE THE BOARD READS.
//
// THE ONE RULE THIS FILE EXISTS TO HOLD: **NO SENTENCE HERE MAY MEAN "THESE
// REASONS ARE TRUE."** The strongest thing the instrument can say about a row
// is that one bound sub-claim of its reason re-derived at HEAD just now. The
// remainder — every reason with no rerun attached — is printed BY NAME and BY
// COUNT at L6, asserted by nobody, because a remainder that is only summarised
// is a remainder nobody can audit.
//
// This is strictly more honest than today's green, which asserts that 213
// reasons are byte-DISTINCT and stops there: distinctness is satisfied equally
// well by a re-derived reason, a stale one, and an invented one.
//
// A banned-wording guard runs in the test suite over this file's output, so the
// rule is enforced rather than merely intended.

import { PDS_VERDICT } from "./adjudicate.mjs";
import { varianceSet } from "./variance.mjs";
import { blindSpotNote } from "./blind-spot.mjs";

const ORDER = [
  PDS_VERDICT.RE_DERIVED,
  PDS_VERDICT.REFUTED,
  PDS_VERDICT.REFUSED,
  PDS_VERDICT.INCONCLUSIVE,
  PDS_VERDICT.DEMOTED_UNKNOWN,
  PDS_VERDICT.MALFORMED,
  PDS_VERDICT.PROSE_ONLY,
];

export function renderVerdict(report, { source = "(unnamed)", listProseOnly = true } = {}) {
  const out = [];
  const rows = report.rows;
  const by = (v) => rows.filter((r) => r.verdict === v);

  out.push("PDS RERUN ADJUDICATOR");
  out.push(`  source        ${source}`);
  out.push(`  status        ${report.status}`);
  out.push(`  budget        estimate ${report.estimateMs}ms / budget ${report.budgetMs}ms / elapsed ${report.elapsedMs}ms`);
  // THE SENTENCE, BESIDE THE FIGURE (PDS-D633), and BEFORE the REFUSED-TO-START
  // early return below — a refusal still prints elapsed 0ms, and a millisecond
  // figure with no meter named beside it is the defect, whatever its value.
  for (const line of blindSpotNote()) out.push(line);

  if (report.status === "REFUSED-TO-START") {
    out.push("");
    out.push(report.message);
    return out.join("\n");
  }

  const withRerun = rows.filter((r) => r.command !== "");
  const levels = {};
  for (const r of withRerun) levels[r.level ?? "L6"] = (levels[r.level ?? "L6"] ?? 0) + 1;
  const levelLine = Object.entries(levels).sort().map(([l, n]) => `${n} at ${l}`).join(", ") || "none";

  out.push("");
  out.push(`  ${rows.length} live adjudicated row(s).`);
  out.push(`  ${withRerun.length} carry a rerun command (${levelLine}); ${rows.length - withRerun.length} carry none.`);

  // THE VARIANCE CENSUS of the authored reruns. PIPE-MASKED-RC and
  // UNCOMPARED-COUNT are the two shapes that look like a check and assert
  // nothing, so their counts belong beside the verdict, not in a footnote.
  const masked = withRerun.filter((r) => varianceSet(r.command).masked);
  const tally = {};
  for (const r of masked) {
    const m = varianceSet(r.command).masked;
    tally[m] = (tally[m] ?? 0) + 1;
  }
  out.push(
    `  variance census of those ${withRerun.length}: ${masked.length} in a MASKED class` +
    (masked.length ? ` (${Object.entries(tally).map(([k, n]) => `${n} ${k}`).join(", ")})` : " (0 PIPE-MASKED-RC, 0 UNCOMPARED-COUNT)") +
    " — a masked rerun prints an answer and asserts nothing."
  );
  out.push("");
  for (const v of ORDER) {
    const n = by(v).length;
    if (n > 0) out.push(`  ${String(n).padStart(5)}  ${v}`);
  }

  const rederived = by(PDS_VERDICT.RE_DERIVED);
  const refuted = by(PDS_VERDICT.REFUTED);
  const refused = by(PDS_VERDICT.REFUSED);
  const inconclusive = by(PDS_VERDICT.INCONCLUSIVE);
  const demoted = by(PDS_VERDICT.DEMOTED_UNKNOWN);
  const malformed = by(PDS_VERDICT.MALFORMED);
  const proseOnly = by(PDS_VERDICT.PROSE_ONLY);

  out.push("");
  out.push("VERDICT");
  out.push(
    `  ${rederived.length} of ${rows.length} reason(s) had ONE BOUND SUB-CLAIM re-derived at HEAD just now. ` +
    "That certifies re-derivability of that sub-claim and nothing else — not the rest of the reason, " +
    "and not that anyone ever ran the command."
  );
  out.push(`  ${refuted.length} REFUTED — the command ran and contradicted the claim it is bound to.`);
  out.push(`  ${refused.length} REFUSED before execution (forbidden spelling, unbound claim, over-claim, or grip's safety screen).`);
  out.push(`  ${inconclusive.length} INCONCLUSIVE — ran, said nothing usable either way. Never counted as a pass.`);
  out.push(`  ${demoted.length} DEMOTED-UNKNOWN — the command did not classify onto a named axis, so it is L6, not refused.`);
  out.push(`  ${malformed.length} MALFORMED on admission through grip's admitFact.`);
  out.push(
    `  ${proseOnly.length} PROSE-ONLY at L6 — no rerun command exists for these, so NOTHING about them is checked here. ` +
    "They are named below rather than summarised: an unfalsifiable remainder that is only counted is still unauditable."
  );

  for (const [label, set] of [["RE-DERIVED", rederived], ["REFUTED", refuted], ["REFUSED", refused], ["INCONCLUSIVE", inconclusive], ["DEMOTED-UNKNOWN", demoted], ["MALFORMED", malformed]]) {
    if (set.length === 0) continue;
    out.push("");
    out.push(`${label} (${set.length})`);
    for (const r of set) {
      out.push(`  ${r.doc_id}  [${r.claim_class ?? "-"} ${r.level ?? "-"}] ${r.reason}`);
      out.push(`      ${r.note}`);
      if (r.command) out.push(`      $ ${r.command}`);
    }
  }

  if (report.conflicts.length > 0) {
    out.push("");
    out.push(`CONFLICT (${report.conflicts.length}) — two facts on one (subject, quantity) with rival claims; both kept.`);
    for (const s of report.conflicts) out.push(`  ${s}`);
  }
  if (report.duplicates.length > 0) {
    out.push("");
    out.push(`DUPLICATE RECIPES (${report.duplicates.length}) — one recipe per row; these were refused, not merged.`);
    for (const s of report.duplicates) out.push(`  ${s}`);
  }
  if (report.orphanRecipes.length > 0) {
    out.push("");
    out.push(`ORPHAN RECIPES (${report.orphanRecipes.length}) — a recipe naming a row that is not in the live adjudicated corpus.`);
    for (const s of report.orphanRecipes) out.push(`  ${s}`);
  }

  if (listProseOnly && proseOnly.length > 0) {
    out.push("");
    out.push(`PROSE-ONLY, L6, ASSERTED BY NOBODY (${proseOnly.length})`);
    for (const r of proseOnly) out.push(`  ${r.doc_id}${r.reason === "NO-REASON" ? "   (and no reason at all)" : ""}`);
  }

  if (report.status === "INCOMPLETE") {
    out.push("");
    out.push(report.message);
  }
  return out.join("\n");
}

// WORDINGS THAT WOULD MAKE THIS OUTPUT A LIE. Pinned by the test suite against
// the rendered text, so the rule cannot decay into a comment.
export const BANNED_WORDINGS = Object.freeze([
  "these reasons are true",
  "the reasons are true",
  "all reasons verified",
  "reasons verified",
  "the board is honest",
  "every reason checks out",
  "reasons are correct",
]);

export function bannedWordingIn(text) {
  const hay = String(text).toLowerCase();
  return BANNED_WORDINGS.filter((w) => hay.includes(w));
}
