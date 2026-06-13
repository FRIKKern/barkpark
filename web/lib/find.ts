/**
 * Advanced finder — shared types + pure helpers.
 *
 * No secrets, no `server-only`: imported by both the `/api/find` route handler
 * (server) and the `<Finder>` client component. All network + token work lives
 * in the route handler; this module only describes shapes and normalises a raw
 * Barkpark document into a uniform hit the UI can render regardless of `_type`.
 */

/** Search engines Barkpark exposes. Postgres = exact/operator-aware (and the
 * anonymous-safe flat route); Indx = fuzzy/typo-tolerant lexical recall, only
 * reachable on a token-scoped route. */
export type SearchEngine = "postgres" | "indx";

export const ENGINES: ReadonlyArray<{
  id: SearchEngine;
  label: string;
  tagline: string;
}> = [
  {
    id: "postgres",
    label: "Postgres",
    tagline: "Exact & operator-aware — phrases, exclusions, prefixes.",
  },
  {
    id: "indx",
    label: "Indx",
    tagline: "Fuzzy & typo-tolerant — finds it even when you misspell.",
  },
];

/** Document types the finder knows how to surface. `href` returns a reader path
 * when this app has a reader for the type, else null (the hit still shows). */
export interface DocType {
  type: string;
  label: string;
  href: ((slug: string) => string) | null;
}

export const DOC_TYPES: ReadonlyArray<DocType> = [
  { type: "post", label: "Posts", href: (s) => `/posts/${s}` },
  { type: "paper", label: "Papers", href: (s) => `/papers/${s}` },
  { type: "page", label: "Pages", href: null },
  { type: "author", label: "Authors", href: null },
  { type: "category", label: "Categories", href: null },
  { type: "project", label: "Projects", href: null },
];

const TYPE_BY_NAME = new Map(DOC_TYPES.map((t) => [t.type, t]));

export function typeLabel(type: string): string {
  return TYPE_BY_NAME.get(type)?.label ?? type;
}

export function readerHref(type: string, slug: string): string | null {
  const fn = TYPE_BY_NAME.get(type)?.href;
  return fn ? fn(slug) : null;
}

/** A parsed Barkpark query — how the engine understood the raw string. */
export interface ParsedQuery {
  terms: string[];
  phrases: string[];
  excludes: string[];
  prefixes: string[];
}

/** One uniform result row. */
export interface FindHit {
  id: string;
  type: string;
  title: string;
  excerpt: string | null;
  /** ISO date (publishedAt → _updatedAt → _createdAt), or null. */
  date: string | null;
  slug: string;
  /** Reader path when available, else null. */
  href: string | null;
}

export interface FindResponse {
  mode: "search" | "browse";
  hits: FindHit[];
  /** Engine total match count (may exceed `hits.length` when capped). */
  total: number;
  /** Engine the caller asked for. */
  engine: SearchEngine;
  /** Engine actually used (falls back to postgres when Indx is unavailable). */
  engineUsed: SearchEngine;
  /** True when Indx was requested but no token was configured to reach it. */
  indxUnavailable: boolean;
  parsedQuery: ParsedQuery | null;
  /** "drop_tokens" | "typo_widen" when a fallback widened the search, else null. */
  recovery: string | null;
  ms: number | null;
  error: string | null;
}

export interface PopularQuery {
  query: string;
  count: number;
  resultCount?: number;
}

/* ── normalisation ─────────────────────────────────────────────────────── */

type RawDoc = Record<string, unknown>;

function str(v: unknown): string | undefined {
  return typeof v === "string" && v.length > 0 ? v : undefined;
}

/** First heading/paragraph text out of a PortableDoc block array (papers). */
function blockText(blocks: unknown, kind: "heading" | "paragraph"): string | undefined {
  if (!Array.isArray(blocks)) return undefined;
  for (const b of blocks) {
    if (!b || typeof b !== "object") continue;
    const block = b as RawDoc;
    if (block.type !== kind) continue;
    if (kind === "heading") {
      const t = str(block.text);
      if (t) return t;
    } else {
      const content = block.content;
      if (Array.isArray(content)) {
        const text = content
          .map((n) =>
            typeof n === "string"
              ? n
              : n && typeof n === "object" && "value" in n
                ? String((n as { value?: unknown }).value ?? "")
                : "",
          )
          .join("")
          .trim();
        if (text) return text;
      }
    }
  }
  return undefined;
}

function deriveTitle(doc: RawDoc): string {
  return (
    str(doc.title) ??
    str(doc.name) ??
    blockText(doc.blocks, "heading") ??
    blockText((doc.body as RawDoc | undefined)?.blocks, "heading") ??
    str(doc._id) ??
    "(untitled)"
  );
}

function deriveExcerpt(doc: RawDoc): string | null {
  const candidate =
    str(doc.excerpt) ??
    blockText(doc.blocks, "paragraph") ??
    str(doc.description) ??
    str(doc.bio) ??
    (typeof doc.body === "string" ? (doc.body as string) : undefined);
  if (!candidate) return null;
  const trimmed = candidate.trim();
  return trimmed.length > 180 ? `${trimmed.slice(0, 177)}…` : trimmed;
}

function deriveSlug(doc: RawDoc): string {
  const content = doc.content as RawDoc | undefined;
  return (
    str(doc.slug) ??
    str(content?.slug) ??
    str(doc._publishedId) ??
    str(doc._id) ??
    ""
  );
}

function deriveDate(doc: RawDoc): string | null {
  return str(doc.publishedAt) ?? str(doc._updatedAt) ?? str(doc._createdAt) ?? null;
}

/** Map a raw Barkpark document map to a uniform {@link FindHit}. */
export function normalizeHit(raw: unknown): FindHit | null {
  if (!raw || typeof raw !== "object") return null;
  const doc = raw as RawDoc;
  const id = str(doc._id);
  const type = str(doc._type);
  if (!id || !type) return null;
  const slug = deriveSlug(doc);
  return {
    id,
    type,
    title: deriveTitle(doc),
    excerpt: deriveExcerpt(doc),
    date: deriveDate(doc),
    slug,
    href: readerHref(type, slug),
  };
}
