/**
 * Client-side prefix seed — a tiny, bundled index that resolves the first
 * 1–2 keystrokes of a finder query LOCALLY in 0ms, before any debounce kicks
 * in or the WebSocket reply arrives. The authoritative search remains the live
 * server engine (Postgres/Indx over the Phoenix Channel); the seed is purely
 * a perceptual-latency cushion that fills the screen with reasonable matches
 * while the real engine catches up.
 *
 * Shape
 * -----
 * A {@link PrefixSeed} is two flat tables:
 *
 *   - `docs[]`     — every candidate document's `{id,title,slug,type}` (the
 *                    minimum the row renderer needs; no body/excerpt — that
 *                    keeps the seed in the KB-not-MB ballpark).
 *   - `index{}`    — `prefix → docs[] indexes`, where prefix is either ONE
 *                    lowercase letter/digit (covers single-char queries) or
 *                    TWO chars (covers two-char queries). Each bucket is
 *                    capped at {@link MAX_PER_PREFIX} to keep payload bounded.
 *
 * Lookup is by exact prefix match — `query.length === 1` hits the 1-char
 * table; `query.length === 2` hits the 2-char table. Anything longer is
 * delegated to the server (the seed returns `[]`).
 *
 * Per-document indexing
 * ---------------------
 * Title + slug get split on non-alphanumeric runs. Every resulting token
 * contributes its single-char first letter AND its two-char prefix to the
 * index. So a doc titled "JavaScript Guide" with slug "javascript-guide"
 * indexes "j", "ja", "g", "gu" — and a `lookupPrefix(seed, "ja")` finds it.
 *
 * Ordering: documents are inserted in array order. Callers pass the docs in
 * relevance order (e.g. the engine's browse ranking), so the seed's first hits
 * are the most "important" — popular pages, featured posts, etc. This is the
 * whole reason a tiny ranked corpus beats an alphabetic dictionary.
 */

// Type-only import (relative, not "@/lib/find") so this module is fully
// testable under Node's --test runner — `import type` is stripped at load
// time and never hits ESM resolution. The reader-href shape is duplicated
// inline below so there is no runtime dependency on `./find` at all.
import type { FindHit } from "./find";

/** Local mirror of `readerHref` (see `lib/find.ts`) — the ONE call site that
 * cannot route through the helper, because importing `./find` at RUNTIME would
 * break this module's zero-runtime-dep contract (the `import type` above is
 * stripped at load time; a value import is not). The path and the encoding must
 * therefore stay byte-identical to `readerHref`. Keep these two in lockstep. */
function readerHrefForSeed(type: string, slug: string): string {
  return `/d/${encodeURIComponent(type)}/${encodeURIComponent(slug)}`;
}

/** One indexable document — minimum the finder row needs. */
export interface SeedDoc {
  id: string;
  title: string;
  slug: string;
  type: string;
}

/** The serializable prefix index — safe to JSON.stringify and ship inline. */
export interface PrefixSeed {
  /** Lowercase prefix (1 or 2 chars) → ordered list of doc indexes. */
  index: Record<string, number[]>;
  docs: SeedDoc[];
}

/** Per-prefix bucket cap. Keeps each entry to ~20 doc indexes; total payload
 * scales linearly with the alphabet × this cap × log(corpus). For a 100-doc
 * browse seed the JSON serializes at ~10–20 KB — bundled, not lazy-loaded. */
export const MAX_PER_PREFIX = 20;

/** Word-token boundary — alphanumerics in, everything else out. Latin-only is
 * fine for the demo corpus; the seed is a best-effort head-start, not the
 * authoritative search. */
function tokenize(text: string): string[] {
  return text
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter((t) => t.length > 0);
}

/** Push `i` into `bucket` if it isn't already there and we have room. */
function pushOnce(bucket: number[], i: number): void {
  if (bucket.length >= MAX_PER_PREFIX) return;
  if (bucket.includes(i)) return;
  bucket.push(i);
}

/**
 * Build a {@link PrefixSeed} from a ranked document list. Pass the docs in the
 * order you want them to win ties — the index records each in insertion order,
 * so earlier-indexed docs surface first in `lookupPrefix`.
 *
 * Idempotent / pure — produces a fresh object every call.
 */
export function buildPrefixSeed(documents: SeedDoc[]): PrefixSeed {
  const index: Record<string, number[]> = {};
  documents.forEach((doc, i) => {
    // Title + slug feed the index. Body/excerpt deliberately NOT — that bloats
    // the seed JSON and the WS query refines body matches as the user types.
    const tokens = new Set<string>();
    for (const t of tokenize(doc.title)) tokens.add(t);
    for (const t of tokenize(doc.slug)) tokens.add(t);
    for (const t of tokens) {
      const one = t[0];
      const two = t.length >= 2 ? t.slice(0, 2) : null;
      const oneBucket = index[one] ?? (index[one] = []);
      pushOnce(oneBucket, i);
      if (two) {
        const twoBucket = index[two] ?? (index[two] = []);
        pushOnce(twoBucket, i);
      }
    }
  });
  return { index, docs: documents };
}

/**
 * Look up candidate documents for a 1- or 2-char prefix query. Returns `[]`
 * for empty input or anything length 3+ (the engine owns those queries — the
 * seed has nothing useful to add). The result list keeps the doc-insertion
 * order, so a ranked corpus yields ranked seed results.
 */
export function lookupPrefix(
  seed: PrefixSeed | null | undefined,
  query: string,
): SeedDoc[] {
  if (!seed) return [];
  const q = query.toLowerCase().trim();
  if (q.length === 0 || q.length > 2) return [];
  const key = q.length === 2 ? q : q[0];
  const indexes = seed.index[key];
  if (!indexes || indexes.length === 0) return [];
  const out: SeedDoc[] = [];
  for (const i of indexes) {
    const d = seed.docs[i];
    if (d) out.push(d);
  }
  return out;
}

/**
 * Adapt a {@link SeedDoc} into the {@link FindHit} shape the finder row
 * renders. Most engine-only fields (body, excerpt, date, facets beyond type)
 * stay null/empty — the row degrades gracefully (no snippet, no date chip).
 * Marked synthetic so a caller can distinguish seed rows from engine rows.
 */
export function seedDocToFindHit(d: SeedDoc): FindHit {
  return {
    id: d.id,
    type: d.type,
    title: d.title,
    excerpt: null,
    body: null,
    date: null,
    slug: d.slug,
    href: readerHrefForSeed(d.type, d.slug),
    facets: { type: d.type },
  };
}
