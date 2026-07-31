// corpus.mjs — READ the PDS ledger's live adjudicated rows. READ-ONLY, always.
//
// Two sources, one shape:
//   loadCorpus(path)  a committed snapshot (fixtures/live-corpus-<date>.json)
//   fetchCorpus(opts) the live board, paged
//
// THE SNAPSHOT DOES NOT STORE THE REASON PROSE, ON PURPOSE. grip's record.mjs
// never parses `evidence` — it is L6 by construction — so a sha256 plus a byte
// count re-derives every clause this instrument asserts. Committing 143 KB of
// reason prose into the repo would have produced one more artifact nobody can
// re-check, which is the exact thing wave 28 exists to bound. `--fetch` gets
// the prose live for anyone who wants to read it.
//
// THE PAGED READ INHERITS THE CENSUS'S FOUR HARD-WON RULES (scripts/pds-ledger-
// census.sh clauses 1-4) rather than re-deriving them: explicit offsets, an
// assertion that the server ECHOED the limit and offset that were asked for
// (it silently caps 5000 → 1000 and says nothing), `order=_createdAt:asc`
// because the default `updated_at DESC` key MUTATES under a concurrent write
// and can skip a row with no duplicate to show for it, and serial paced
// requests because a parallel walk of this board returns short pages and
// exits 0. This module does NOT import that script — it is bash+python and
// this is ESM — and it does not modify it either (that file is another slice's).
//
// NO EXIT CODE IS EVER READ HERE, and nothing is executed: this module does
// HTTP and fs, and reports failures by returning them.

import { readFileSync } from "node:fs";

export const DEFAULT_ROOT = "task-2ac1f95237c4a8e5";
export const TERMINAL_LIFECYCLE = Object.freeze(["done", "cancelled", "canceled"]);
export const PAGE_ORDER = "_createdAt:asc";

/** A ledger row, normalised. `disposition_reason` may be absent in a snapshot. */
function normaliseRow(row) {
  const str = (k) => (typeof row[k] === "string" ? row[k].trim() : "");
  return {
    doc_id: str("doc_id") || str("_id"),
    title: str("title"),
    lifecycle_status: str("lifecycle_status"),
    disposition: str("disposition"),
    disposition_reason: str("disposition_reason"),
    disposition_reason_sha256: str("disposition_reason_sha256"),
    disposition_reason_bytes: Number.isFinite(row.disposition_reason_bytes) ? row.disposition_reason_bytes : null,
    disposition_rerun: str("disposition_rerun"),
    reopen_trigger: str("reopen_trigger"),
    parent_id: str("parent_id"),
    _createdAt: str("_createdAt") || str("inserted_at"),
  };
}

/** Does this row carry a reason at all? Prose OR its stored digest. */
export function hasReason(row) {
  return row.disposition_reason !== "" || row.disposition_reason_sha256 !== "";
}

/** Load a committed snapshot. Throws with a legible message on a bad shape. */
export function loadCorpus(path) {
  let parsed;
  try {
    parsed = JSON.parse(readFileSync(path, "utf8"));
  } catch (err) {
    throw new Error(`corpus: cannot read ${path} — ${err.message}`);
  }
  if (!Array.isArray(parsed?.rows)) {
    throw new Error(`corpus: ${path} has no \`rows\` array — refusing to report an empty board as a small one`);
  }
  return {
    source: `snapshot ${path} (read_at ${parsed.read_at ?? "unrecorded"})`,
    root: parsed.root ?? DEFAULT_ROOT,
    closure: parsed.closure ?? null,
    rows: parsed.rows.map(normaliseRow),
  };
}

/**
 * fetchCorpus({ server, token, root, pageLimit, paceMs, dataset }) → corpus
 *
 * Serial, paced, explicit offsets, echo-asserted, closure over parent_id.
 * Every failure THROWS with the reason named — a census that cannot read its
 * board must never return a smaller board.
 */
export async function fetchCorpus({
  server,
  token,
  root = DEFAULT_ROOT,
  dataset = "production",
  pageLimit = 1000,
  paceMs = 350,
  maxPages = 40,
} = {}) {
  if (!server || !token) {
    throw new Error("corpus: --fetch needs a server and a token (BARKPARK_SERVER / BARKPARK_TOKEN, or ~/.config/barkpark/config.json)");
  }
  const base = server.replace(/\/+$/, "");
  const all = new Map();
  const pageSizes = [];

  for (let page = 0; page < maxPages; page++) {
    const offset = page * pageLimit;
    const url = `${base}/v1/data/query/${dataset}/task?limit=${pageLimit}&offset=${offset}&order=${encodeURIComponent(PAGE_ORDER)}`;
    const res = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
    if (res.status !== 200) {
      throw new Error(`corpus: page ${page} answered HTTP ${res.status} — a non-200 is a transport failure, never an empty page`);
    }
    const body = await res.json();
    const result = body?.result;
    if (!result || !Array.isArray(result.documents)) {
      throw new Error(`corpus: page ${page} returned HTTP 200 with no result.documents list — the shape is asserted, "it parsed" is not a success`);
    }
    if (result.limit !== pageLimit || result.offset !== offset) {
      throw new Error(
        `corpus: page ${page} asked limit=${pageLimit} offset=${offset} and the server echoed limit=${result.limit} offset=${result.offset} — a cap that is not echoed honestly is a transport failure`
      );
    }
    pageSizes.push(result.documents.length);
    for (const doc of result.documents) {
      const id = doc.doc_id ?? doc._id;
      if (id) all.set(id, doc);
    }
    if (result.documents.length < pageLimit) break;
    if (paceMs > 0) await new Promise((r) => setTimeout(r, paceMs));
  }

  // Transitive closure over parent_id — NEVER `.children`, which is a one-level
  // read that scores ~63% of this board and greens.
  const kids = new Map();
  for (const [id, doc] of all) {
    const p = doc.parent_id;
    if (!kids.has(p)) kids.set(p, []);
    kids.get(p).push(id);
  }
  const closure = new Set();
  const stack = [...(kids.get(root) ?? [])];
  while (stack.length) {
    const n = stack.pop();
    if (closure.has(n)) continue;
    closure.add(n);
    stack.push(...(kids.get(n) ?? []));
  }

  const rows = [...closure]
    .sort()
    .map((id) => normaliseRow(all.get(id)))
    .filter((r) => !TERMINAL_LIFECYCLE.includes(r.lifecycle_status) && r.disposition !== "");

  return {
    source: `live ${base} (${pageSizes.length} page(s) of ${pageLimit}: ${pageSizes.join(", ")}; order=${PAGE_ORDER})`,
    root,
    closure: closure.size,
    rows,
  };
}

/** The live adjudicated rows: non-terminal lifecycle AND a non-empty disposition. */
export function liveAdjudicated(corpus) {
  return corpus.rows.filter(
    (r) => !TERMINAL_LIFECYCLE.includes(r.lifecycle_status) && r.disposition !== ""
  );
}
