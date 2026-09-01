#!/usr/bin/env node
//
// FALSE-OPEN SWEEP — which OPEN rows on an epic roster already carry a merge receipt?
// (search vocabulary: false open, false-open, merge receipt, still-open row, roster sweep,
//  silently empty, zero-line clean report. No @canonical marker: this capability is
//  unforked and self-naming, and the doc contract reserves markers for decoyed ones.)
//
// WHY THIS FILE EXISTS. The "standing false-open sweep" was never a program. It was
// four ledger notes describing a hand-typed pipeline, and that pipeline had the epic's
// own defect inside it (charter D391, row
// cch-w34-bl-false-open-sweep-instrument-fails-silent-empty):
//
//   `bp task get <epic> -o json` puts `children` at the TOP LEVEL. The recipe in
//   circulation did `d.get('doc', d)` first, so it selected `doc`, which has no
//   `children`. The pipeline died with KeyError — and the SHELL REDIRECT STILL CREATED
//   THE OUTPUT FILE. Zero lines. `wc -l` said 0, every `while read` loop downstream
//   iterated nothing, and the sweep reported "no false-opens" INDISTINGUISHABLY from
//   genuine absence. An instrument that cannot tell "I found nothing" from "I read
//   nothing" reports success it never observed.
//
// So the first rule of this file is: EVERY EMPTY IS A REFUSAL, NEVER A CLEAN REPORT.
// There is no code path here that prints a clean sweep over an unread population.
//
// SECOND RULE: THIS TOOL CLOSES NOTHING. It has no write path to the ledger — no
// `bp task close`, no `bp doc patch`, no HTTP method other than GET. It reports; a
// human disposes. Partially-paid rows are printed as PARTIAL precisely so that nobody
// closes them on a merge receipt alone and stamps unbuilt work as done.
//
// THE DETECTOR (two required arms, one advisory).
//
//   ARM A — the merge gate's OWN trailer. `scripts/pr-task-gate.sh:extract_task_ids`
//     defines the grammar that decides whether a PR may merge at all: a column-0,
//     case-insensitive `task:` line, optional surrounding backticks, and TWO DISTINCT
//     ids is a refusal rather than a pick-by-position. A merged PR whose trailer names
//     a still-open row is that row's own build, already on main. This arm reproduces
//     the gate's grammar exactly, including the ambiguity refusal.
//
//   ARM B — a criterion that NAMES A PR NUMBER that is merged. Arm A alone FAILS
//     GREEN on a real class. PR #9356's trailer names `gr-bl-seal-predicate-provenance-gap`
//     while the row its criterion 6 actually pays is
//     `cch-w28-s1-empty-roster-control-asserts-clause-a`. A trailer-only detector
//     under-counted the wave-34 population by a third. The two arms are not redundant:
//     the pairing is the finding.
//
//   ARM C (ADVISORY, never counted) — a merged PR body that mentions the row's slug in
//     prose. It found one more row in wave 34 AND one NEGATION ("pays nothing toward
//     Law 0's orphan count") that a naive grep scores as a hit. So this arm reads the
//     sentence around the mention and reports negated hits as NEGATED. It is printed
//     for a human to read and is EXCLUDED from every count.
//
// THE LIMIT, WHICH THE REPORT ALSO PRINTS: the merge-receipt rate is a FLOOR on the
// false-open rate, never an estimate of it. A row whose fix shipped inside a
// neighbour's PR with no slug mention and no PR number in its criteria is invisible to
// all three arms. Only source re-derivation against origin/main finds that class.
//
// FETCHING. Roster row fetches are STRICTLY SERIAL with a bounded retry. A parallel
// `xargs -P8` fetch silently wrote 15 EMPTY files during wave 34; anyone who re-ran
// without noticing undercounted the population and got a smaller, comforting answer.
// A zero-byte or unparseable row is a REFUSAL here, not a skip. The GitHub side pages
// serially too, because `gh pr list --search ... --limit 1500` is served by the SEARCH
// API, which caps at 1000 results and says nothing about it.
//
// USAGE
//   node scripts/false-open-sweep.mjs --selftest
//   env -u BARKPARK_TOKEN node scripts/false-open-sweep.mjs --epic <epic-slug> [options]
//
//   --epic <slug>         epic whose children are swept (live mode)
//   --status <s>          lifecycle_status that counts as the population (default: open)
//   --since <YYYY-MM-DD>  oldest merge date to walk on GitHub (default: 2026-07-01)
//   --repo <owner/name>   GitHub repo (default: FRIKKern/barkpark)
//   --cache-dir <dir>     write every fetched envelope here (audit trail)
//   --roster <file>       read the epic envelope from a file instead of `bp`
//   --rows-dir <dir>      read row envelopes from <dir>/<slug>.json instead of `bp`
//   --merged-prs <file>   read the merged-PR array from a file instead of `gh`
//   --offline             refuse to shell out at all (implied by --selftest)
//   --limit-rows <n>      cap the population (a bounded rehearsal; the report says so)
//   --out <file>          also write the report text here
//
// EXIT CODES
//   0  the sweep ran over a population it actually read (receipts or not)
//   1  --selftest had a failing case
//   2  usage error
//   3  REFUSAL — the sweep could not establish that it read what it claims to have read

import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const FIXTURE_ROOT = path.join(HERE, "fixtures", "false-open-sweep");

// ─────────────────────────────────────────────────────────────────────────────
// Refusals. Each one is NAMED, because "the sweep found nothing" and "the sweep
// read nothing" must never print the same way.
// ─────────────────────────────────────────────────────────────────────────────
class Refusal extends Error {
  constructor(name, detail) {
    super(detail);
    this.refusal = name;
  }
}
const refuse = (name, detail) => {
  throw new Refusal(name, detail);
};

// ─────────────────────────────────────────────────────────────────────────────
// ARM A grammar — a transliteration of scripts/pr-task-gate.sh:extract_task_ids.
//   grep -ioE '^task:[[:space:]]*`?[a-z0-9][a-z0-9._/-]*`?' | sed 's/^task:\s*//' | tr -d '`' | sort -u
// Column 0 (so a trailer quoted inside an indented fenced block does NOT match),
// case-insensitive, backticks stripped, DISTINCT ids — two of them is ambiguity.
// ─────────────────────────────────────────────────────────────────────────────
const TRAILER_RE = /^task:[ \t]*`?([a-z0-9][a-z0-9._/-]*)`?/gim;

export function extractTrailerIds(body) {
  const out = [];
  if (typeof body !== "string") return out;
  for (const m of body.matchAll(TRAILER_RE)) {
    const id = m[1].toLowerCase();
    if (!out.includes(id)) out.push(id);
  }
  return out;
}

// `drafts.` is a ledger prefix, not part of the identity a PR author types.
export const normalizeSlug = (s) =>
  String(s || "").trim().toLowerCase().replace(/^drafts\./, "");

// ─────────────────────────────────────────────────────────────────────────────
// ARM B grammar — a PR number named inside criterion or evidence text.
// 3-6 digits so that "#1" / "9/13" / "(3/5)" do not manufacture receipts.
// ─────────────────────────────────────────────────────────────────────────────
const PR_REF_RE = /(?:#|\bpull\/|\bPRs?[ \t]*#?)(\d{3,6})\b/gi;

export function extractPrRefs(text) {
  const out = [];
  if (typeof text !== "string") return out;
  for (const m of text.matchAll(PR_REF_RE)) {
    const n = Number(m[1]);
    if (!out.includes(n)) out.push(n);
  }
  return out;
}

// ARM C — negation context. A merged body may name a slug in order to DENY paying it.
const NEGATION_RE =
  /\b(?:pays?\s+nothing|nothing\s+toward|does\s+not\s+(?:pay|close|touch)|no(?:t)?\s+(?:a\s+)?(?:payment|receipt)\s+(?:for|toward)|unrelated\s+to|deliberately\s+not)\b/i;

export function advisorySentences(body, slug) {
  const hits = [];
  if (typeof body !== "string" || !slug) return hits;
  const bare = normalizeSlug(slug);
  // Sentence-ish windows so the negation is read in context, not repo-wide.
  for (const chunk of body.split(/(?<=[.!?\n])\s+/)) {
    if (chunk.toLowerCase().includes(bare)) {
      hits.push({ text: chunk.trim().replace(/\s+/g, " ").slice(0, 200), negated: NEGATION_RE.test(chunk) });
    }
  }
  return hits;
}

// ─────────────────────────────────────────────────────────────────────────────
// CAN A MERGE RECEIPT PAY THIS CRITERION?
//
// The first draft of this asked `/\bmerg/i.test(criterion)` and it was WRONG IN THE
// CLOSING DIRECTION. cch-w11-s1's criterion 12 reads "THE GATE IS MUTATION-PROVEN ABLE
// TO BOTH STOP AND NOT-STOP A MERGE" — a criterion about a gate's behaviour that merely
// says the word `merge`. A substring test called it paid, which promotes a PARTIAL row
// to FULL and puts a still-unbuilt criterion one keystroke from a close. The fixture
// case `case-partial-never-auto-closed` pins that exact string as UNPAID.
//
// So the test is three narrow, stated things, never a substring:
//   1. the ledger's own `merge_gate: true` flag — the only authoritative signal;
//   2. the criterion NAMES A PR NUMBER for which this row has a receipt in hand;
//   3. the criterion is MERGE-RECEIPT-SHAPED — it says the PR merged to main, or it is
//      labelled MERGE-GATED, or it asks for the merge SHA.
//
// Everything else stays UNPAID, which pushes its row toward PARTIAL. That is the
// deliberate direction of the error: a wrongly-PARTIAL row costs a human one reading,
// a wrongly-FULL row costs a close on work that was never built.
// ─────────────────────────────────────────────────────────────────────────────
const MERGE_SHAPED = [
  /\bmerge[- ]?gated\b/i,
  /\bmerged\b[^.]{0,40}\b(?:to\s+)?(?:main|master)\b/i,
  /\b(?:the\s+)?(?:PR|pull request)\b[^.]{0,30}\b(?:is\s+)?merged\b/i,
  /\bmerge\s+(?:SHA|commit)\b/i,
];
export function mergeReceiptCanPay(c, receiptPrNumbers) {
  if (!c) return false;
  if (c.merge_gate === true) return true;
  const text = `${c.criterion || ""}\n${c.evidence || ""}`;
  if (receiptPrNumbers && extractPrRefs(text).some((n) => receiptPrNumbers.has(n))) return true;
  return MERGE_SHAPED.some((re) => re.test(text));
}
const isMet = (c) => c && c.met === true;

// ─────────────────────────────────────────────────────────────────────────────
// Roster reading — the exact site of the silent-empty defect.
// ─────────────────────────────────────────────────────────────────────────────
export function readRoster(envelope, status) {
  if (envelope == null || typeof envelope !== "object") {
    refuse("ROSTER_UNPARSEABLE", "the epic envelope is not a JSON object");
  }
  if (!Array.isArray(envelope.children)) {
    const hint = envelope.doc || envelope.content || envelope.doc_id
      ? "\n  This envelope looks like the `doc` SUB-OBJECT, or `doc` was selected out of it." +
        "\n  `children` is a TOP-LEVEL key of `bp task get <epic> -o json`, a SIBLING of `doc`." +
        "\n  The recipe `d.get('doc', d)` selects `doc`, which has no children, dies with" +
        "\n  KeyError, and the shell redirect still leaves a ZERO-LINE file behind it."
      : "";
    refuse(
      "ROSTER_NO_CHILDREN_KEY",
      `the epic envelope has no top-level \`children\` array (saw keys: ${Object.keys(envelope).join(", ") || "none"})${hint}`
    );
  }
  const declared = typeof envelope.child_count === "number" ? envelope.child_count : null;
  if (declared !== null && declared !== envelope.children.length) {
    refuse(
      "ROSTER_INCOMPLETE",
      `the server declares child_count=${declared} but the envelope carries ${envelope.children.length} children — ` +
        "the roster was truncated in transit; a sweep over a short roster undercounts and reads as reassuring"
    );
  }
  const population = envelope.children.filter((c) => c && c.lifecycle_status === status);
  if (population.length === 0) {
    refuse(
      "EMPTY_POPULATION",
      `the roster has ${envelope.children.length} children and NONE with lifecycle_status=${JSON.stringify(status)}. ` +
        "That is either a genuinely empty population or a mis-read; this tool will not print a clean sweep over " +
        "zero rows, because those two readings are exactly what the old pipeline confused."
    );
  }
  return { population, walked: envelope.children.length, declared };
}

// ─────────────────────────────────────────────────────────────────────────────
// Row envelopes. Serial + retried on the live path; byte-empty is a REFUSAL.
// ─────────────────────────────────────────────────────────────────────────────
function parseRowEnvelope(slug, raw) {
  if (raw == null || String(raw).trim() === "") return { ok: false, why: "EMPTY (zero bytes)" };
  let j;
  try {
    j = JSON.parse(raw);
  } catch (e) {
    return { ok: false, why: `unparseable JSON (${e.message})` };
  }
  const doc = j && j.doc ? j.doc : j;
  if (!doc || typeof doc !== "object") return { ok: false, why: "no `doc` in the envelope" };
  const id = doc.doc_id || doc.id;
  if (normalizeSlug(id) !== normalizeSlug(slug)) {
    return { ok: false, why: `envelope is for ${JSON.stringify(id)}, not ${JSON.stringify(slug)}` };
  }
  // Criteria live under `content`, NOT at the top of the doc: a reader that walks the
  // top level reports a confident zero. But a row that genuinely carries NO
  // acceptance_criteria is a legitimate ledger state, not a failed fetch — the first
  // live run of this script refused the whole sweep over exactly one such row
  // (task-85c531c2adbf0dff, open, no criteria at all). Conflating "the envelope did
  // not arrive" with "this row has nothing to read" is a guard that reds on correct
  // data, and a guard that reds on correct data gets worked around. So it is counted
  // and DECLARED as arm-B-blind coverage instead, and only a missing, empty,
  // unparseable or wrong-id envelope is a refusal.
  const ac = doc.content && doc.content.acceptance_criteria;
  if (ac !== undefined && ac !== null && !Array.isArray(ac)) {
    return { ok: false, why: `doc.content.acceptance_criteria is ${typeof ac}, not an array` };
  }
  return { ok: true, doc, criteria: Array.isArray(ac) ? ac : [], noCriteria: !Array.isArray(ac) };
}

function bpTaskGet(bin, slug, attempts) {
  let last = "";
  for (let i = 1; i <= attempts; i++) {
    const r = spawnSync(bin, ["task", "get", slug, "-o", "json"], {
      encoding: "utf8",
      maxBuffer: 64 * 1024 * 1024,
    });
    const out = r.stdout || "";
    if (r.status === 0 && out.trim() !== "") return { raw: out, attempts: i };
    last = `attempt ${i}: status=${r.status} stderr=${String(r.stderr || "").trim().slice(0, 200)}`;
    // bounded, blocking backoff — deliberately serial, see the header note on xargs -P8
    const until = Date.now() + 400 * i;
    while (Date.now() < until) { /* spin */ }
  }
  return { raw: "", attempts, last };
}

export function loadRows(slugs, opts) {
  const rows = new Map();
  const failures = [];
  for (const slug of slugs) {
    let raw = "";
    let attempts = 1;
    if (opts.rowsDir) {
      const f = path.join(opts.rowsDir, `${slug}.json`);
      raw = fs.existsSync(f) ? fs.readFileSync(f, "utf8") : "";
    } else {
      if (opts.offline) refuse("OFFLINE_NO_ROWS", `--offline was given but there is no --rows-dir for ${slug}`);
      const got = bpTaskGet(opts.bpBin, slug, opts.attempts);
      raw = got.raw;
      attempts = got.attempts;
      if (opts.cacheDir && raw) fs.writeFileSync(path.join(opts.cacheDir, `${slug}.json`), raw);
    }
    const parsed = parseRowEnvelope(slug, raw);
    if (!parsed.ok) failures.push({ slug, why: parsed.why });
    else rows.set(slug, { ...parsed, attempts });
    if (opts.onRow) opts.onRow(slug, parsed.ok, attempts);
  }
  if (failures.length) {
    refuse(
      "ROW_FETCH_INCOMPLETE",
      `${failures.length} of ${slugs.length} row envelopes did not arrive intact — the sweep would undercount:\n` +
        failures.map((f) => `    ${f.slug}: ${f.why}`).join("\n") +
        "\n  (a parallel fetch silently wrote 15 EMPTY files during wave 34; empties are refused here, never skipped)"
    );
  }
  if (rows.size !== slugs.length) {
    refuse("ROW_FETCH_INCOMPLETE", `walked ${rows.size} rows of a population of ${slugs.length}`);
  }
  return rows;
}

// ─────────────────────────────────────────────────────────────────────────────
// Merged-PR window. Serial paging, because the SEARCH API caps at 1000 silently.
// ─────────────────────────────────────────────────────────────────────────────
const GH_PAGE = 1000;

function ghJson(args) {
  const r = spawnSync("gh", args, { encoding: "utf8", maxBuffer: 256 * 1024 * 1024 });
  if (r.status !== 0) return { ok: false, why: String(r.stderr || "").trim().slice(0, 300) };
  try {
    return { ok: true, data: JSON.parse(r.stdout || "null") };
  } catch (e) {
    return { ok: false, why: `gh returned unparseable JSON: ${e.message}` };
  }
}

export function fetchMergedPrs(opts) {
  const seen = new Map();
  const pages = [];
  let upper = null; // walk backwards in time
  for (let page = 1; page <= (opts.maxPages || 12); page++) {
    const q = upper
      ? `merged:${opts.since}..${upper}`
      : `merged:>=${opts.since}`;
    let got = null;
    for (let attempt = 1; attempt <= opts.attempts; attempt++) {
      got = ghJson([
        "pr", "list", "--repo", opts.repo, "--state", "merged",
        "--search", q, "--limit", String(GH_PAGE),
        "--json", "number,title,body,mergedAt,mergeCommit",
      ]);
      if (got.ok) break;
    }
    if (!got || !got.ok) {
      refuse("PR_WINDOW_UNREADABLE", `gh could not serve the merged-PR window ${q}: ${got ? got.why : "no result"}`);
    }
    const batch = Array.isArray(got.data) ? got.data : [];
    pages.push({ query: q, returned: batch.length });
    let added = 0;
    for (const p of batch) {
      if (!seen.has(p.number)) { seen.set(p.number, p); added++; }
    }
    if (batch.length < GH_PAGE) break;           // the window closed honestly
    if (added === 0) break;                       // no forward progress; stop rather than spin
    const oldest = batch.map((p) => p.mergedAt).filter(Boolean).sort()[0];
    if (!oldest) break;
    upper = oldest;
    if (page === (opts.maxPages || 12)) {
      refuse(
        "PR_WINDOW_TRUNCATED",
        `the merged-PR window hit the search API's ${GH_PAGE}-result cap on every one of ${page} pages; ` +
          "the sweep cannot prove it saw the whole window and will not report a floor computed from a partial one"
      );
    }
  }
  return { prs: [...seen.values()], pages };
}

export function readMergedPrs(arr) {
  if (!Array.isArray(arr)) refuse("PR_WINDOW_UNREADABLE", "the merged-PR source is not a JSON array");
  if (arr.length === 0) {
    refuse(
      "EMPTY_MERGED_PR_SET",
      "the merged-PR window is EMPTY. Every arm of this detector reads that window, so a sweep over it " +
        "would report `no false-opens` having examined nothing — the precise failure this instrument replaces."
    );
  }
  return arr;
}

// ─────────────────────────────────────────────────────────────────────────────
// The sweep itself.
// ─────────────────────────────────────────────────────────────────────────────
export function sweep({ roster, rows, prs, status, prLookup, prWindow }) {
  const { population, walked, declared } = readRoster(roster, status);
  const popSlugs = population.map((c) => c.doc_id);
  const bySlug = new Map(popSlugs.map((s) => [normalizeSlug(s), s]));

  const merged = readMergedPrs(prs);
  const mergedByNumber = new Map(merged.map((p) => [Number(p.number), p]));

  const criteriaLess = popSlugs.filter((slug) => rows.get(slug) && rows.get(slug).noCriteria);
  const receipts = [];       // {row, pr, arm, mergeCommit, mergedAt, criterion?}
  const ambiguous = [];      // merged PRs whose trailer the MERGE GATE ITSELF would refuse
  const advisory = [];       // arm C — printed, never counted

  // ── ARM A: the pr-task-gate trailer ────────────────────────────────────────
  for (const pr of merged) {
    const ids = extractTrailerIds(pr.body);
    if (ids.length > 1) {
      ambiguous.push({ pr: pr.number, ids });
      continue; // the gate refuses to pick by position; so does the sweep
    }
    if (ids.length !== 1) continue;
    const row = bySlug.get(normalizeSlug(ids[0]));
    if (!row) continue;
    receipts.push({
      row, arm: "A", pr: Number(pr.number),
      mergedAt: pr.mergedAt || null,
      mergeCommit: (pr.mergeCommit && pr.mergeCommit.oid) || pr.mergeCommit || null,
      why: `pr-task-gate trailer \`Task: ${ids[0]}\``,
    });
  }

  // ── ARM B: a criterion naming a PR number that is merged ───────────────────
  //
  // A CRITERION THAT NAMES A MERGED PR IS NOT AUTOMATICALLY PAID BY IT. The first
  // live run made that plain: `cch-w40-bl-billing-is-owner-is-honest-only-by-position-
  // after-10005` is 0/3 and its criteria name #10005 — as the PR whose merge CREATED
  // the defect the row is about. Crediting that as a receipt inflates the floor with
  // rows nothing has paid, and the floor is the one number this report asks anyone to
  // trust.
  //
  // So arm B splits. A merged PR named by a criterion is a RECEIPT only when the
  // criterion is itself the merge criterion (merge_gate: true, or merge-receipt-shaped
  // prose). Every other mention is a CITATION: printed under its own heading for a
  // human to read, counted in NOTHING.
  const citations = [];
  for (const slug of popSlugs) {
    const row = rows.get(slug);
    if (!row) refuse("ROW_FETCH_INCOMPLETE", `no envelope in hand for ${slug}`);
    row.criteria.forEach((c, i) => {
      const text = `${c.criterion || ""}\n${c.evidence || ""}`;
      for (const n of extractPrRefs(text)) {
        let pr = mergedByNumber.get(n);
        if (!pr && prLookup) {
          const looked = prLookup(n);
          if (looked && looked.merged) pr = looked;
        }
        if (!pr) continue;
        const entry = {
          row: slug, arm: "B", pr: n,
          mergedAt: pr.mergedAt || null,
          mergeCommit: (pr.mergeCommit && pr.mergeCommit.oid) || pr.mergeCommit || null,
          criterionIndex: i + 1,
          met: isMet(c),
          why: `criterion ${i + 1} names #${n}, which is MERGED`,
        };
        // `mergeReceiptCanPay` with NO receipt set: the question here is whether the
        // criterion is a merge criterion at all, not whether some other PR paid it.
        if (mergeReceiptCanPay(c, null)) receipts.push(entry);
        else citations.push({ ...entry, why: `criterion ${i + 1} MENTIONS #${n} (merged) but is not a merge criterion — a citation, not a receipt` });
      }
    });
  }

  // ── ARM C: prose mention, with the negation read in context. ADVISORY. ─────
  // A cheap indexOf gates the expensive sentence split: this loop is
  // |merged PRs| x |population| and the live window is thousands by hundreds.
  const bareSlugs = popSlugs.map((s) => [s, normalizeSlug(s)]);
  for (const pr of merged) {
    const body = typeof pr.body === "string" ? pr.body : "";
    if (!body) continue;
    const lower = body.toLowerCase();
    const trailerIds = extractTrailerIds(body).map(normalizeSlug);
    for (const [slug, bare] of bareSlugs) {
      if (!lower.includes(bare)) continue;
      // a trailer for this row is already arm A; do not double-report it
      if (trailerIds.includes(bare)) continue;
      for (const s of advisorySentences(body, slug)) {
        advisory.push({ row: slug, pr: Number(pr.number), negated: s.negated, text: s.text });
      }
    }
  }

  // ── Classification. FULL vs PARTIAL — and PARTIAL is NEVER closeable. ──────
  const byRow = new Map();
  for (const r of receipts) {
    if (!byRow.has(r.row)) byRow.set(r.row, []);
    byRow.get(r.row).push(r);
  }
  const findings = [];
  for (const [slug, rs] of byRow) {
    const row = rows.get(slug);
    const receiptPrNumbers = new Set(rs.map((r) => r.pr));
    const unmet = row.criteria
      .map((c, i) => ({ c, i: i + 1 }))
      .filter((x) => !isMet(x.c));
    const uncovered = unmet.filter((x) => !mergeReceiptCanPay(x.c, receiptPrNumbers));
    findings.push({
      row: slug,
      title: (row.doc && row.doc.title) || "",
      met: row.criteria.filter(isMet).length,
      total: row.criteria.length,
      arms: [...new Set(rs.map((r) => r.arm))].sort(),
      receipts: rs,
      klass: uncovered.length === 0 ? "FULL" : "PARTIAL",
      uncovered: uncovered.map((x) => ({ i: x.i, criterion: String(x.c.criterion || "").replace(/\s+/g, " ").slice(0, 180) })),
    });
  }
  findings.sort((a, b) => (a.klass === b.klass ? a.row.localeCompare(b.row) : a.klass === "FULL" ? -1 : 1));

  const armAOnly = new Set(receipts.filter((r) => r.arm === "A").map((r) => r.row));
  const armBOnly = new Set(receipts.filter((r) => r.arm === "B").map((r) => r.row));
  const onlyB = [...armBOnly].filter((r) => !armAOnly.has(r)).sort();

  return {
    status, walked, declared,
    criteriaLess,
    citations,
    population: popSlugs.length,
    mergedPrs: merged.length,
    prWindow: prWindow || null,
    findings,
    receipts,
    ambiguous,
    advisory,
    armBRescues: onlyB,
    full: findings.filter((f) => f.klass === "FULL").length,
    partial: findings.filter((f) => f.klass === "PARTIAL").length,
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// Report rendering. The FLOOR sentence is not optional and not a footnote.
// ─────────────────────────────────────────────────────────────────────────────
export function renderReport(rep, meta) {
  const L = [];
  const pct = rep.population ? ((rep.findings.length / rep.population) * 100).toFixed(1) : "0.0";
  L.push("false-open-sweep · " + (meta.mode || "live") + " · " + (meta.now || new Date().toISOString()));
  L.push("epic: " + (meta.epic || "(fixture)"));
  L.push(
    `roster: WALKED ${rep.walked}/${rep.declared === null ? rep.walked : rep.declared} children ` +
      `(server child_count ${rep.declared === null ? "not declared" : rep.declared}) — COMPLETE`
  );
  L.push(`population: ${rep.population} rows with lifecycle_status=${rep.status}` + (meta.limited ? `  [BOUNDED REHEARSAL: capped at ${meta.limited}]` : ""));
  if (rep.prWindow) {
    L.push(
      `merged-PR window: ${rep.mergedPrs} PRs over ${rep.prWindow.pages.length} SERIAL page(s)` +
        rep.prWindow.pages.map((p) => `\n    ${p.query} -> ${p.returned}`).join("")
    );
  } else {
    L.push(`merged-PR window: ${rep.mergedPrs} PRs (supplied)`);
  }
  const cl = rep.criteriaLess || [];
  L.push(
    `arm-B coverage: ${rep.population - cl.length}/${rep.population} rows carry acceptance_criteria` +
      (cl.length ? `  — ${cl.length} row(s) carry NONE, so arm B is STRUCTURALLY BLIND to them (arm A still sees them): ${cl.join(", ")}` : "")
  );
  L.push("");
  L.push(`RESULT: ${rep.findings.length} of ${rep.population} open rows carry a merge receipt  (FULL ${rep.full} · PARTIAL ${rep.partial})`);
  L.push("");

  const block = (klass, header, note) => {
    const rows = rep.findings.filter((f) => f.klass === klass);
    L.push(`── ${header} — ${rows.length} ${"─".repeat(Math.max(0, 54 - header.length))}`);
    if (note) L.push("   " + note);
    if (rows.length === 0) L.push("   (none)");
    for (const f of rows) {
      L.push(`   ${f.row}   [${f.met}/${f.total} criteria met]  arms:${f.arms.join("+")}`);
      if (f.title) L.push(`      ${String(f.title).slice(0, 110)}`);
      for (const r of f.receipts) {
        L.push(`      receipt: arm ${r.arm} · PR #${r.pr} · merged ${r.mergedAt || "?"} · ${String(r.mergeCommit || "?").slice(0, 12)}`);
        L.push(`               ${r.why}`);
      }
      for (const u of f.uncovered) {
        L.push(`      NOT PAID by any merge receipt — criterion ${u.i}: ${u.criterion}`);
      }
    }
    L.push("");
  };

  block("FULL", "FULL — every unmet criterion is one a merge receipt can pay", "still a CANDIDATE for a human to dispose; this tool closes nothing.");
  block(
    "PARTIAL",
    "PARTIAL — paid in part, NOT CLOSEABLE",
    "closing one of these on a merge receipt alone would stamp UNBUILT WORK AS DONE. Re-scope, do not close."
  );

  const cites = rep.citations || [];
  const citeRows = [...new Set(cites.map((c) => c.row))].filter((r) => !rep.findings.some((f) => f.row === r));
  L.push(`── CITATIONS, NOT RECEIPTS — ${"─".repeat(38)}`);
  L.push("   A criterion that NAMES a merged PR is not automatically PAID by it: a row can name");
  L.push("   the very PR whose merge CREATED its defect. These are counted in NOTHING.");
  L.push(`   ${cites.length} citation(s) across ${new Set(cites.map((c) => c.row)).size} row(s); ${citeRows.length} of those rows have NO receipt from any arm.`);
  for (const r of citeRows.slice(0, 25)) {
    const cs = cites.filter((c) => c.row === r);
    L.push(`      ${r}  <- ${[...new Set(cs.map((c) => "#" + c.pr))].join(", ")} (criteria ${[...new Set(cs.map((c) => c.criterionIndex))].join(",")})`);
  }
  L.push("");
  L.push(`── ARM PAIRING — ${"─".repeat(46)}`);
  L.push(`   rows found ONLY by arm B (a trailer-only detector would have MISSED these): ${rep.armBRescues.length}`);
  for (const r of rep.armBRescues) L.push(`      ${r}`);
  L.push(`   merged PRs with an AMBIGUOUS trailer (2+ distinct ids — the merge gate itself refuses these,`);
  L.push(`   so the sweep declines to pick by position rather than crediting a guess): ${rep.ambiguous.length}`);
  for (const a of rep.ambiguous.slice(0, 10)) L.push(`      #${a.pr}: ${a.ids.join(" , ")}`);
  L.push("");

  const adv = rep.advisory.filter((a) => !a.negated);
  const neg = rep.advisory.filter((a) => a.negated);
  L.push(`── ARM C (ADVISORY, EXCLUDED FROM EVERY COUNT) — ${"─".repeat(21)}`);
  L.push(`   prose mentions: ${adv.length} readable · ${neg.length} NEGATED (a naive grep scores these as hits)`);
  for (const a of adv.slice(0, 15)) L.push(`      #${a.pr} -> ${a.row}: ${a.text}`);
  for (const a of neg.slice(0, 15)) L.push(`      NEGATED  #${a.pr} -> ${a.row}: ${a.text}`);
  L.push("");

  L.push("── THE LIMIT — READ THIS BEFORE QUOTING THE NUMBER ─────────────────────");
  L.push(`   merge-receipt rate: ${rep.findings.length} of ${rep.population} = ${pct}%`);
  L.push("   THIS IS A FLOOR ON THE FALSE-OPEN RATE. IT IS NOT AN ESTIMATE OF IT.");
  L.push("   A row whose fix shipped inside a neighbour's PR — no trailer naming it, no PR");
  L.push("   number in its criteria, no slug in the body — is invisible to all three arms.");
  L.push("   The true false-open rate is >= this number and is UNBOUNDED above it. Only");
  L.push("   source re-derivation against origin/main finds that class, and that remains");
  L.push("   the expensive instrument this cheap one does not replace.");
  if (cl.length) {
    L.push(`   The floor is also short by construction: ${cl.length} row(s) carry no acceptance_criteria,`);
    L.push("   so arm B cannot read them at all. Only arm A could have found those.");
  }
  L.push("");
  L.push("   THIS TOOL CLOSES NOTHING. It has no write path to the ledger. Every row above");
  L.push("   stays open until a human disposes it, and PARTIAL rows are not disposable on a");
  L.push("   merge receipt at all.");
  return L.join("\n");
}

// ─────────────────────────────────────────────────────────────────────────────
// Selftest over committed fixtures.
// ─────────────────────────────────────────────────────────────────────────────
function runCase(dir) {
  const rd = (f) => JSON.parse(fs.readFileSync(path.join(dir, f), "utf8"));
  const expect = rd("expect.json");
  const status = expect.status || "open";
  let out = { exit: 0, refusal: null, rep: null, text: "" };
  try {
    const roster = rd("roster.json");
    const { population } = readRoster(roster, status);
    const rows = loadRows(population.map((c) => c.doc_id), {
      rowsDir: path.join(dir, "rows"), offline: true, attempts: 1,
    });
    const prs = JSON.parse(fs.readFileSync(path.join(dir, "merged-prs.json"), "utf8"));
    const rep = sweep({ roster, rows, prs, status, prLookup: null, prWindow: null });
    out.rep = rep;
    out.text = renderReport(rep, { mode: "selftest", epic: path.basename(dir), now: "FIXED" });
  } catch (e) {
    if (!(e instanceof Refusal)) throw e;
    out.exit = 3;
    out.refusal = e.refusal;
    out.text = `REFUSAL:${e.refusal}\n${e.message}`;
  }

  const checks = [];
  const chk = (name, got, want) => checks.push({ name, ok: JSON.stringify(got) === JSON.stringify(want), got, want });

  chk("exit", out.exit, expect.exit);
  if ("refusal" in expect) chk("refusal", out.refusal, expect.refusal);
  if (expect.receipts) {
    const got = (out.rep ? out.rep.findings : []).flatMap((f) =>
      f.receipts.map((r) => ({ row: f.row, arm: r.arm, pr: r.pr, class: f.klass }))
    ).sort((a, b) => (a.row + a.arm + a.pr).localeCompare(b.row + b.arm + b.pr));
    const want = [...expect.receipts].sort((a, b) => (a.row + a.arm + a.pr).localeCompare(b.row + b.arm + b.pr));
    chk("receipts", got, want);
  }
  if (expect.arm_b_rescues) chk("arm_b_rescues", out.rep ? out.rep.armBRescues : null, expect.arm_b_rescues);
  if (expect.ambiguous_prs) chk("ambiguous_prs", out.rep ? out.rep.ambiguous.map((a) => a.pr).sort() : null, [...expect.ambiguous_prs].sort());
  if (expect.advisory_negated_prs) chk("advisory_negated_prs", out.rep ? out.rep.advisory.filter((a) => a.negated).map((a) => a.pr).sort() : null, [...expect.advisory_negated_prs].sort());
  if (expect.advisory_readable_prs) chk("advisory_readable_prs", out.rep ? out.rep.advisory.filter((a) => !a.negated).map((a) => a.pr).sort() : null, [...expect.advisory_readable_prs].sort());
  for (const s of expect.must_contain || []) {
    checks.push({ name: `contains ${JSON.stringify(s.slice(0, 40))}`, ok: out.text.includes(s), got: "(text)", want: s });
  }
  for (const s of expect.must_not_contain || []) {
    checks.push({ name: `omits ${JSON.stringify(s.slice(0, 40))}`, ok: !out.text.includes(s), got: "(text)", want: `absent: ${s}` });
  }
  if (checks.length === 0) checks.push({ name: "VACUOUS CASE — expect.json asserts nothing", ok: false, got: null, want: "at least one assertion" });
  return { checks, out };
}

function selftest() {
  if (!fs.existsSync(FIXTURE_ROOT)) {
    console.error(`REFUSAL:NO_FIXTURES  ${FIXTURE_ROOT} does not exist`);
    return 1;
  }
  const dirs = fs.readdirSync(FIXTURE_ROOT)
    .filter((d) => fs.existsSync(path.join(FIXTURE_ROOT, d, "expect.json")))
    .sort();
  if (dirs.length === 0) {
    console.error(`REFUSAL:NO_FIXTURES  no case directory under ${FIXTURE_ROOT} carries an expect.json`);
    return 1;
  }
  let pass = 0, fail = 0, assertions = 0;
  for (const d of dirs) {
    const { checks } = runCase(path.join(FIXTURE_ROOT, d));
    const bad = checks.filter((c) => !c.ok);
    assertions += checks.length;
    if (bad.length === 0) {
      pass++;
      console.log(`  PASS  ${d}  (${checks.length} assertions)`);
    } else {
      fail++;
      console.log(`  FAIL  ${d}  (${bad.length} of ${checks.length} assertions failed)`);
      for (const b of bad) {
        console.log(`          ${b.name}`);
        console.log(`            want: ${JSON.stringify(b.want)}`);
        console.log(`            got : ${JSON.stringify(b.got)}`);
      }
    }
  }
  console.log("");
  console.log(`false-open-sweep --selftest: ${dirs.length} cases · ${pass} passed · ${fail} failed · ${assertions} assertions`);
  if (dirs.length < 8) {
    console.log(`  REFUSAL:SELFTEST_UNDERPOPULATED  ${dirs.length} cases is below the floor of 8 — a shrinking suite`);
    console.log("  is how a guard goes quiet without ever going red.");
    return 1;
  }
  return fail === 0 ? 0 : 1;
}

// ─────────────────────────────────────────────────────────────────────────────
// CLI
// ─────────────────────────────────────────────────────────────────────────────
function parseArgs(argv) {
  const a = { status: "open", since: "2026-07-01", repo: "FRIKKern/barkpark", attempts: 4, bpBin: "bp" };
  for (let i = 0; i < argv.length; i++) {
    const t = argv[i];
    const next = () => argv[++i];
    switch (t) {
      case "--selftest": a.selftest = true; break;
      case "--epic": a.epic = next(); break;
      case "--status": a.status = next(); break;
      case "--since": a.since = next(); break;
      case "--repo": a.repo = next(); break;
      case "--cache-dir": a.cacheDir = next(); break;
      case "--roster": a.roster = next(); break;
      case "--rows-dir": a.rowsDir = next(); break;
      case "--merged-prs": a.mergedPrs = next(); break;
      case "--offline": a.offline = true; break;
      case "--limit-rows": a.limitRows = Number(next()); break;
      case "--out": a.out = next(); break;
      case "--bp": a.bpBin = next(); break;
      case "-h": case "--help": a.help = true; break;
      default:
        console.error(`usage error: unknown argument ${JSON.stringify(t)}`);
        process.exit(2);
    }
  }
  return a;
}

function main() {
  const a = parseArgs(process.argv.slice(2));
  if (a.help) {
    console.log(fs.readFileSync(fileURLToPath(import.meta.url), "utf8").split("\n").filter((l) => l.startsWith("//")).join("\n"));
    return 0;
  }
  if (a.selftest) return selftest();
  if (!a.epic && !a.roster) {
    console.error("usage error: --epic <slug> (or --roster <file>) is required; --selftest for the fixture suite");
    return 2;
  }

  try {
    // 1. roster
    let rosterRaw;
    if (a.roster) rosterRaw = fs.readFileSync(a.roster, "utf8");
    else {
      if (a.offline) refuse("OFFLINE_NO_ROSTER", "--offline was given without --roster");
      const got = bpTaskGet(a.bpBin, a.epic, a.attempts);
      rosterRaw = got.raw;
      if (!rosterRaw.trim()) {
        refuse("ROSTER_UNPARSEABLE", `\`${a.bpBin} task get ${a.epic} -o json\` produced NOTHING after ${a.attempts} attempts (${got.last || "no detail"})`);
      }
    }
    if (a.cacheDir) { fs.mkdirSync(a.cacheDir, { recursive: true }); fs.writeFileSync(path.join(a.cacheDir, "_epic.json"), rosterRaw); }
    const roster = JSON.parse(rosterRaw);
    const { population } = readRoster(roster, a.status);

    // 2. rows — SERIAL, retried, empties refused
    let slugs = population.map((c) => c.doc_id);
    if (a.limitRows && a.limitRows < slugs.length) slugs = slugs.slice(0, a.limitRows);
    process.stderr.write(`fetching ${slugs.length} row envelopes SERIALLY (no parallel fetch — see header)\n`);
    let n = 0;
    const rows = loadRows(slugs, {
      rowsDir: a.rowsDir, offline: a.offline, attempts: a.attempts, bpBin: a.bpBin, cacheDir: a.cacheDir,
      onRow: (slug, ok, att) => {
        n++;
        if (n % 25 === 0 || !ok || att > 1) process.stderr.write(`  ${n}/${slugs.length} ${slug} ${ok ? "ok" : "FAILED"}${att > 1 ? ` (after ${att} attempts)` : ""}\n`);
      },
    });

    // 3. merged PRs
    let prs, prWindow = null;
    if (a.mergedPrs) prs = JSON.parse(fs.readFileSync(a.mergedPrs, "utf8"));
    else {
      if (a.offline) refuse("OFFLINE_NO_PRS", "--offline was given without --merged-prs");
      process.stderr.write(`fetching merged PRs since ${a.since} (serial pages; the search API caps at ${GH_PAGE})\n`);
      const got = fetchMergedPrs({ repo: a.repo, since: a.since, attempts: a.attempts });
      prs = got.prs;
      prWindow = { pages: got.pages };
      if (a.cacheDir) fs.writeFileSync(path.join(a.cacheDir, "_merged-prs.json"), JSON.stringify(prs));
    }

    // 4. arm-B lookups for PR numbers OUTSIDE the window (the cap is real: a
    //    criterion may name #8394 while the window starts at #12159)
    const lookupCache = new Map();
    const prLookup = a.offline || a.mergedPrs
      ? null
      : (num) => {
          if (lookupCache.has(num)) return lookupCache.get(num);
          const r = ghJson(["pr", "view", String(num), "--repo", a.repo, "--json", "number,state,mergedAt,mergeCommit"]);
          const v = r.ok && r.data && r.data.state === "MERGED"
            ? { merged: true, mergedAt: r.data.mergedAt, mergeCommit: r.data.mergeCommit }
            : null;
          lookupCache.set(num, v);
          return v;
        };

    const rep = sweep({ roster, rows, prs, status: a.status, prLookup, prWindow });
    // the population reported must be the population WALKED, not the roster's
    rep.population = slugs.length;
    const text = renderReport(rep, {
      mode: a.rowsDir || a.mergedPrs ? "mixed" : "live",
      epic: a.epic || a.roster,
      limited: a.limitRows && a.limitRows < population.length ? a.limitRows : null,
    });
    console.log(text);
    if (a.out) fs.writeFileSync(a.out, text + "\n");
    return 0;
  } catch (e) {
    if (e instanceof Refusal) {
      console.error("");
      console.error(`REFUSAL:${e.refusal}`);
      console.error(`  ${e.message}`);
      console.error("");
      console.error("  This is a REFUSAL, not a clean sweep. Nothing was reported because nothing was");
      console.error("  established. Fix the read and re-run; do not treat the absence of findings above");
      console.error("  as the absence of false-opens.");
      return 3;
    }
    throw e;
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  process.exit(main());
}
