/**
 * Advanced finder — shared types + pure helpers.
 *
 * No secrets, no `server-only`: imported by both the `/api/find` route handler
 * (server) and the `<Finder>` client component. All network + token work lives
 * in the route handler; this module only describes shapes and normalises a raw
 * Barkpark document into a uniform hit the UI can render regardless of `_type`.
 */

/** Search engines Barkpark exposes. Postgres = exact/operator-aware; Indx =
 * fuzzy/typo-tolerant lexical recall. Both ride the same route (scoped when a
 * token is configured, flat-anonymous otherwise). */
export type SearchEngine = "postgres" | "indx";

/**
 * The ONE default engine — consumed by the SSR seed (layout), the Finder's
 * `initialEngine` prop default, the `?engine=` URL readers (Finder + the
 * `/api/find` route), so every surface agrees on what "no engine param" means.
 * Postgres: always provisioned wherever Barkpark runs, exact + operator-aware.
 * The engine PILL is retired (Indx is unprovisionable headlessly, so the UI no
 * longer advertises it); an explicit `?engine=indx` URL still opts in, and the
 * server-reported `engineUsed` drives an honest `indxUnavailable` note when
 * the request was silently served by Postgres instead.
 */
export const DEFAULT_ENGINE: SearchEngine = "postgres";

/** Document types the finder knows how to surface. Every type now has a reader
 * via the unified `/d/[type]/[slug]` detail route — there are no dead-end types
 * anymore (view-only types render a MetaCard). `href` builds that path. */
export interface DocType {
  type: string;
  label: string;
  href: (slug: string) => string;
}

/** The content types this site's finder surfaces + facets over, config-driven.
 *
 * `NEXT_PUBLIC_BARKPARK_DOC_TYPES` is a comma-separated list, each entry either
 * a bare `type` or `type:Label` (the label auto-Title-Cases + pluralises when
 * omitted). It MUST be `NEXT_PUBLIC_` so the value is inlined into BOTH the
 * server route (find-search) and the client bundle (use-live-search) — otherwise
 * the two would compute a different `types` allowlist and drift.
 *
 * Default keeps the multi-type demo set; a single-type seed site sets e.g.
 * `NEXT_PUBLIC_BARKPARK_DOC_TYPES=guide:Guides`. On the managed-deploy path (the
 * build env is scrubbed to the BUILD_ALLOW list, which drops NEXT_PUBLIC_* but
 * keeps the singular `BARKPARK_DOC_TYPE`), the server bundle falls back to that
 * single type; the client bundle sees neither and keeps the demo default (a
 * benign superset — extra types in the WS `types` allowlist just yield no hits). */
function titleCase(type: string): string {
  const t = type.charAt(0).toUpperCase() + type.slice(1);
  return t.endsWith("s") ? t : `${t}s`;
}

function parseDocTypes(spec: string | undefined): DocType[] {
  const entries = (spec ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  if (entries.length === 0) {
    return [
      { type: "post", label: "Posts" },
      { type: "paper", label: "Papers" },
      { type: "sheet", label: "Sheets" },
      { type: "page", label: "Pages" },
      { type: "author", label: "Authors" },
      { type: "category", label: "Categories" },
      { type: "project", label: "Projects" },
    ].map((t) => ({ ...t, href: (s: string) => readerHref(t.type, s) }));
  }
  return entries.map((entry) => {
    const [type, label] = entry.split(":").map((s) => s.trim());
    return {
      type,
      label: label && label.length > 0 ? label : titleCase(type),
      href: (s: string) => readerHref(type, s),
    };
  });
}

export const DOC_TYPES: ReadonlyArray<DocType> = parseDocTypes(
  process.env.NEXT_PUBLIC_BARKPARK_DOC_TYPES ?? process.env.BARKPARK_DOC_TYPE,
);

const TYPE_BY_NAME = new Map(DOC_TYPES.map((t) => [t.type, t]));

export function typeLabel(type: string): string {
  return TYPE_BY_NAME.get(type)?.label ?? type;
}

/** Reader path for any document. The unified detail route serves EVERY type, so
 * this never returns null — unknown types still get a `/d/<type>/<slug>` path
 * (the detail page resolves what to render, falling back to a MetaCard). */
export function readerHref(type: string, slug: string): string {
  return `/d/${encodeURIComponent(type)}/${encodeURIComponent(slug)}`;
}

/** Is `pathname` the reader path for this hit? THE COMPARISON HALF of the same
 * invariant {@link readerHref} owns on the construction half.
 *
 * The browser's `usePathname()` returns the ENCODED path, so a raw-interpolated
 * expected side (a raw '/d/' + type + '/' + slug template) never matches once
 * a slug carries a space, '#', '?' or '/' — and the symptom is silent: the
 * active result row simply stops highlighting. Encoding the expected side
 * through {@link readerHref} is what makes the two sides comparable.
 *
 * `hit.href` is checked first because a normalised hit may carry a href the
 * server chose; the derived path is the fallback for hits built elsewhere. */
export function isReaderPathActive(
  pathname: string | null | undefined,
  hit: { type: string; slug: string; href?: string | null },
): boolean {
  if (!pathname) return false;
  if (hit.href && pathname === hit.href) return true;
  return pathname === readerHref(hit.type, hit.slug);
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
  /** Engine that ACTUALLY served — the server-reported `engineUsed` (the
   * query pipeline is the only place that knows; a silent zero-hit-recovery
   * substitution reports postgres here even on an indx request). */
  engineUsed: SearchEngine;
  /** True when indx was requested but the answer was served by Postgres —
   * derived from the server truth, shown as a calm inline note. */
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

/* ── popular-chip curation ─────────────────────────────────────────────── */

/** Most words a popular query may have to earn a chip. */
export const POPULAR_CHIP_MAX_WORDS = 2;
/** Longest a popular query may be (characters) to earn a chip. */
export const POPULAR_CHIP_MAX_CHARS = 24;
/** How many chips the idle status row shows at most. */
export const POPULAR_CHIP_CAP = 6;

/**
 * Curate the raw popular-query pool down to the chips worth offering.
 *
 * `/api/find?suggest` returns the query LOG verbatim, and a Barkpark instance's
 * log is mostly machine exhaust: agents probing with whole sentences ("research
 * coverage ledger"), operator syntax, one-off spelunking. A chip row is a
 * promise — "these are the searches worth trying" — so an uncurated row ships
 * that promise over telemetry and reads as noise at the ten-second bar.
 *
 * The filter keeps only human-shaped queries: at most
 * {@link POPULAR_CHIP_MAX_WORDS} words AND at most
 * {@link POPULAR_CHIP_MAX_CHARS} characters, deduped case-insensitively (the
 * log records "Deploy" and "deploy" separately), capped at
 * {@link POPULAR_CHIP_CAP}. Input rank order is preserved — the pool already
 * arrives sorted by popularity.
 *
 * DEGRADES TO NOTHING BY DESIGN: a fresh dataset has an empty log, and a
 * dev-heavy one can have a log with nothing short in it. Both yield `[]`, and
 * the caller renders no row at all rather than a row of leftovers.
 */
export function curatePopularQueries(
  pool: PopularQuery[] | null | undefined,
): PopularQuery[] {
  const seen = new Set<string>();
  const chips: PopularQuery[] = [];
  for (const entry of pool ?? []) {
    const query = typeof entry?.query === "string" ? entry.query.trim() : "";
    if (!query || query.length > POPULAR_CHIP_MAX_CHARS) continue;
    if (query.split(/\s+/).length > POPULAR_CHIP_MAX_WORDS) continue;
    const key = query.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    chips.push({ ...entry, query });
    if (chips.length >= POPULAR_CHIP_CAP) break;
  }
  return chips;
}

/* ── normalisation ─────────────────────────────────────────────────────── */

type RawDoc = Record<string, unknown>;

function str(v: unknown): string | undefined {
  return typeof v === "string" && v.length > 0 ? v : undefined;
}

/** Plain text of one inline-content array (e.g. a paragraph block's `content`).
 * PortableDoc stores marked-up runs as WRAPPER nodes (`strong`/`em`/`link`/…)
 * whose text lives in `children`, so a shallow `.value` read would drop them.
 * This descends into any `children` array, reads `value` on object leaves, and
 * accepts bare string/number leaves — the same walk {@link collectText} does,
 * confined to a single inline array. */
export function inlineText(content: unknown): string {
  const out: string[] = [];
  const walk = (n: unknown): void => {
    if (typeof n === "string") {
      out.push(n);
    } else if (typeof n === "number") {
      out.push(String(n));
    } else if (Array.isArray(n)) {
      for (const c of n) walk(c);
    } else if (n && typeof n === "object") {
      const node = n as { value?: unknown; children?: unknown };
      if (node.value !== undefined && node.value !== null) out.push(String(node.value));
      if (Array.isArray(node.children)) walk(node.children);
    }
  };
  walk(content);
  return out.join("").trim();
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
        const text = inlineText(content);
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
