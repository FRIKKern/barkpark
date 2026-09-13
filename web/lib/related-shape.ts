/**
 * Pure `related-route JSON → RelatedEntry[]` normaliser. The server-only
 * fetch/cache layer (`lib/related.ts`) feeds it, and
 * `__tests__/related.test.ts` drives it directly under `node --test`.
 *
 * Kept free of BOTH `server-only` AND `next/cache` on purpose: `next/cache`
 * is not importable by the plain-node test runner (its import throws outside
 * the Next bundler), so the pure shaper is split out of the server module
 * exactly as `lib/find-shape.ts` is split out of the server-only
 * `lib/find-search.ts`. No secrets, no I/O — just shape.
 *
 * Wire shape (mirrors `Barkpark.Content.Related` via the query controller):
 *
 *   { "result": { "related": [ {
 *       "doc_id": "some-slug",           // published slug, NEVER a uuid
 *       "type": "paper",
 *       "title": "…" | null,
 *       "score": 1.1,
 *       "sources": ["tags"] | ["references"] | ["tags","references"],
 *       "shared_tags": [ { "tag": "search", "src_strength": 75,
 *                          "cand_strength": 50 } ]
 *     } ], "count": 1 }, "syncTags": ["bp:ds:…:related:…"] }
 *
 * A zero-tag source degrades to backlink-only related entries
 * (`sources == ["references"]`, empty `shared_tags`). That is a COMMON path:
 * ~27% of the published `paper` corpus carries zero weighted tags.
 * `isBacklinkOnly` is the provenance predicate the UI badges on.
 *
 * THE FIGURE IS DERIVED, NOT QUOTED. Census: charter D77 in
 * `.claude/workflows/bp-authoring-excellence-charter.md`, recorded 2026-07-22
 * against the guerrilla `paper` corpus — 340 weighted-tagged / 127 untagged /
 * 0 flat-only, so 127 / (340 + 127) = 127/467 = 27.2%. The re-runnable SQL,
 * the scope caveat (D77 counted `paper` rows only) and the two defects this
 * replaces live in the `Barkpark.Content.Related` moduledoc under "The
 * untagged share". Both defects, named here too so this copy stands alone:
 * (a) the retired "~35%" named no census and its introducing commit
 * `ba53e7b93` (#5615) carries no figure; (b) it was ~8 points high from the
 * hour it was written — D77 landed 4.5 hours EARLIER the same day.
 *
 * THIS NUMBER IS MIRRORED IN THREE FILES and locked by
 * `api/test/barkpark/content/related_untagged_census_test.exs`: this file,
 * `lib/related.ts`, and `api/lib/barkpark/content/related.ex` must all carry
 * 27% / charter D77 / 2026-07-22 / 127/467. The lock's rule for the retired
 * figure is a PREDICATE, not a blocklist: it may appear only on a line that
 * also says "retired", so a retraction like the one above is legal and a
 * fresh assertion is not. Move all three together or the Elixir suite reds —
 * three sites DISAGREEING is what a half-finished repair looks like.
 */

/** Provenance leg an entry earned its place through. */
export type RelatedSource = "tags" | "references";

/** One shared-tag detail: the tag plus both sides' declared strengths. */
export interface SharedTag {
  tag: string;
  src_strength: number;
  cand_strength: number;
}

/** One related entry, provenance-carrying and surface-renderable. */
export interface RelatedEntry {
  /** Published slug (NEVER a uuid) — the web links by slug via `readerHref`. */
  doc_id: string;
  type: string;
  title: string | null;
  score: number;
  sources: RelatedSource[];
  shared_tags: SharedTag[];
}

function str(v: unknown): string | undefined {
  return typeof v === "string" && v.length > 0 ? v : undefined;
}

function num(v: unknown): number | undefined {
  return typeof v === "number" && Number.isFinite(v) ? v : undefined;
}

/** Keep only the two known provenance legs, de-duplicated, order-preserving. */
function normalizeSources(raw: unknown): RelatedSource[] {
  if (!Array.isArray(raw)) return [];
  const out: RelatedSource[] = [];
  for (const s of raw) {
    if (s === "tags" && !out.includes("tags")) out.push("tags");
    else if (s === "references" && !out.includes("references")) out.push("references");
  }
  return out;
}

function normalizeSharedTag(raw: unknown): SharedTag | null {
  if (!raw || typeof raw !== "object") return null;
  const t = raw as Record<string, unknown>;
  const tag = str(t.tag);
  if (!tag) return null;
  return {
    tag,
    src_strength: num(t.src_strength) ?? 0,
    cand_strength: num(t.cand_strength) ?? 0,
  };
}

/** Normalise one raw upstream entry; drop anything without a usable slug. */
function normalizeEntry(raw: unknown): RelatedEntry | null {
  if (!raw || typeof raw !== "object") return null;
  const e = raw as Record<string, unknown>;
  const docId = str(e.doc_id) ?? str(e.document_id) ?? str(e._id);
  if (!docId) return null;
  const shared_tags = Array.isArray(e.shared_tags)
    ? e.shared_tags.map(normalizeSharedTag).filter((t): t is SharedTag => t !== null)
    : [];
  return {
    doc_id: docId,
    type: str(e.type) ?? str(e._type) ?? "_unknown",
    title: str(e.title) ?? null,
    score: num(e.score) ?? 0,
    sources: normalizeSources(e.sources),
    shared_tags,
  };
}

/** Dig the entry list out of the wire body, tolerating shape drift: the
 * `{ result: { related } }` envelope, a bare `{ related }`, or a raw array. */
function extractList(json: unknown): unknown[] {
  if (Array.isArray(json)) return json;
  if (!json || typeof json !== "object") return [];
  const root = json as Record<string, unknown>;
  const result = root.result;
  if (result && typeof result === "object") {
    const r = (result as Record<string, unknown>).related;
    if (Array.isArray(r)) return r;
  }
  return Array.isArray(root.related) ? root.related : [];
}

/** Upstream related-route body → the clean `RelatedEntry[]` the UI renders.
 * Never throws: malformed input yields `[]`, malformed entries are dropped. */
export function normalizeRelated(json: unknown): RelatedEntry[] {
  return extractList(json)
    .map(normalizeEntry)
    .filter((e): e is RelatedEntry => e !== null);
}

/** True when an entry earned its place ONLY through an inbound reference (no
 * shared tags) — the provenance badge the Related section shows. */
export function isBacklinkOnly(entry: RelatedEntry): boolean {
  return entry.sources.includes("references") && !entry.sources.includes("tags");
}

/** The credited shared strength for a tag — `LEAST(src, cand)`, mirroring the
 * server's per-name scoring credit — so the UI shows the strength that counted. */
export function creditedStrength(t: SharedTag): number {
  return Math.min(t.src_strength, t.cand_strength);
}
