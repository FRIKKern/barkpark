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

/** Document types the finder knows how to surface. Every type now has a reader
 * via the unified `/d/[type]/[slug]` detail route — there are no dead-end types
 * anymore (view-only types render a MetaCard). `href` builds that path. */
export interface DocType {
  type: string;
  label: string;
  href: (slug: string) => string;
}

export const DOC_TYPES: ReadonlyArray<DocType> = [
  { type: "post", label: "Posts", href: (s) => `/d/post/${s}` },
  { type: "paper", label: "Papers", href: (s) => `/d/paper/${s}` },
  { type: "sheet", label: "Sheets", href: (s) => `/d/sheet/${s}` },
  { type: "page", label: "Pages", href: (s) => `/d/page/${s}` },
  { type: "author", label: "Authors", href: (s) => `/d/author/${s}` },
  { type: "category", label: "Categories", href: (s) => `/d/category/${s}` },
  { type: "project", label: "Projects", href: (s) => `/d/project/${s}` },
];

const TYPE_BY_NAME = new Map(DOC_TYPES.map((t) => [t.type, t]));

export function typeLabel(type: string): string {
  return TYPE_BY_NAME.get(type)?.label ?? type;
}

/** Reader path for any document. The unified detail route serves EVERY type, so
 * this never returns null — unknown types still get a `/d/<type>/<slug>` path
 * (the detail page resolves what to render, falling back to a MetaCard). */
export function readerHref(type: string, slug: string): string {
  return `/d/${type}/${slug}`;
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
  /** Flattened plain-text body (capped) — used to build a CONTEXTUAL match
   * snippet in the results (the text that triggered the hit), not just the
   * title. Null when the doc has no prose body. */
  body: string | null;
  /** ISO date (publishedAt → _updatedAt → _createdAt), or null. */
  date: string | null;
  slug: string;
  /** Reader path — always set now (every type has a `/d/[type]/[slug]` page). */
  href: string;
  /** Facet-dimension values for client-side facet filtering (type/status/…). */
  facets: Record<string, string>;
}

/** One facet bucket: a value and how many docs carry it (counted by Indx). */
export interface FacetBucket {
  label: string;
  count: number;
}

/** Facet dimension → buckets, as computed by Indx across the result set. */
export type FacetMap = Record<string, FacetBucket[]>;

/** Facet dimensions surfaced in the rail, in display order. */
export const FACET_DIMENSIONS: ReadonlyArray<{ key: string; label: string }> = [
  { key: "type", label: "Type" },
  { key: "status", label: "Status" },
  { key: "author", label: "Author" },
  { key: "category", label: "Category" },
];

export const SORTS = [
  { id: "relevance", label: "Relevance" },
  { id: "newest", label: "Newest" },
  { id: "title", label: "Title" },
] as const;

export type SortId = (typeof SORTS)[number]["id"];

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
  /** Indx-computed facet buckets (dataset-wide for browse, match-set for a
   * query). Null for the Postgres engine — the gateway doesn't expose them. */
  facets: FacetMap | null;
  /** Indx coverage boundary: hits before `index` are coverage-confirmed
   * matches, after are softer pattern hits. Null for Postgres / no query. */
  truncation: { index: number } | null;
  /** Engine-reported compute time (ms). */
  ms: number | null;
  /** Whether the route handler served this through the Next Data Cache. */
  cache: boolean;
  /** Wall-clock the route handler spent on the upstream fetch (ms). A warm
   * Data-Cache hit is ~0–2ms; a cold miss pays the Barkpark round-trip. The
   * benchmark signal. */
  upstreamMs: number | null;
  /** Opaque id of the query event the API logged for this search — threaded
   * back as `queryEventId` on a result-click interaction. Null when the search
   * wasn't recorded (browse, no session, or a cached/empty response). */
  searchEventId: string | null;
  /** Canonical corrected term when a LEARNED/synonym correction fired server-
   * side (the synonym's `to_query`). Drives "Showing results for …". Null when
   * no correction applied. */
  correctedTo: string | null;
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

// Structure/ref leaf keys to skip when flattening a block tree to prose — so
// the body text isn't polluted with mark names, ids, urls, types (mirrors the
// server indexer's @body_skip_keys).
const BODY_SKIP_KEYS = new Set([
  "marks", "href", "src", "url", "id", "_id", "_type", "_rev", "type",
  "rev", "kind", "lang", "slug", "style",
]);

/** Recursively collect all human text out of a PortableDoc block tree (every
 * `value`/string leaf), skipping structural keys. Bounded by the caller's cap. */
function collectText(node: unknown, out: string[]): void {
  if (typeof node === "string") {
    out.push(node);
  } else if (Array.isArray(node)) {
    for (const n of node) collectText(n, out);
  } else if (node && typeof node === "object") {
    for (const [k, v] of Object.entries(node as RawDoc)) {
      if (!BODY_SKIP_KEYS.has(k)) collectText(v, out);
    }
  }
}

/** A flattened, capped plain-text body for contextual match snippets. Walks the
 * paper block tree (or a string body / description), collapses whitespace, and
 * caps the length so the client can window a snippet around a match without
 * bloating the payload. */
function deriveBody(doc: RawDoc): string | null {
  const out: string[] = [];
  collectText(doc.blocks, out);
  if (out.length === 0) collectText((doc.body as RawDoc | undefined)?.blocks, out);
  if (out.length === 0 && typeof doc.body === "string") out.push(doc.body);
  if (out.length === 0) {
    const d = str(doc.description) ?? str(doc.bio);
    if (d) out.push(d);
  }
  const text = out.join(" ").replace(/\s+/g, " ").trim();
  if (!text) return null;
  // Cap to keep the seed/landing payload bounded — covers near-top matches; a
  // deep match falls back to the static excerpt.
  return text.length > 1000 ? text.slice(0, 1000) : text;
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
  // `Envelope.render` spreads `content` to the top level (no nested `content`
  // key); `status` is a column it doesn't render, so derive it from `_draft`.
  const content = (doc.content as RawDoc | undefined) ?? {};
  const facets: Record<string, string> = { type };
  const status =
    str(doc.status) ??
    str(content.status) ??
    (typeof doc._draft === "boolean"
      ? doc._draft
        ? "draft"
        : "published"
      : undefined);
  const author = str(doc.author) ?? str(content.author);
  const category = str(doc.category) ?? str(content.category);
  if (status) facets.status = status;
  if (author) facets.author = author;
  if (category) facets.category = category;
  return {
    id,
    type,
    title: deriveTitle(doc),
    excerpt: deriveExcerpt(doc),
    body: deriveBody(doc),
    date: deriveDate(doc),
    slug,
    href: readerHref(type, slug),
    facets,
  };
}
