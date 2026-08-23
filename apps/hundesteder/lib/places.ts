import "server-only";
import { collectAllPages } from "./paginate";
import { paperTags, type PaperTag } from "./paper-tags";

/**
 * The data layer for Hundesteder.no — every page's source of places.
 *
 * Adapted from the monorepo's `web/lib/listings.ts` seam, repointed at the
 * Barkpark prod content for the `hundesteder` workspace. Key differences:
 *
 *   - It talks to a FIXED backend (the published `place` type), not a generic
 *     env-driven type, and authenticates with a server-only bearer token that
 *     must never reach the browser (no NEXT_PUBLIC_ prefix — every call here is
 *     made from a Server Component or route handler).
 *   - The upstream envelope is `{ result: { count, documents } }` for the query
 *     and `{ result: { ...doc } }` for a single doc.
 *   - `geo.{latitude,longitude}` arrive as STRINGS — we parseFloat them.
 *
 * Like the source, this module NEVER throws: a hard upstream failure degrades
 * to an empty list so a Server Component renders a calm empty state rather than
 * crashing. The data is small and read-only, so we lean on Next's fetch cache
 * with a short revalidate window.
 */

/* ── env (server-only) ──────────────────────────────────────────────────── */

// Canonical Barkpark env names (task dwb-3), with backwards-compatible fallback
// to the pre-unification ones so an already-deployed Vercel project keeps
// working. Canonical set: templates/DEPLOYING.md.
//   BARKPARK_API_URL  ← was BARKPARK_API_BASE   (base URL; here the scoped one)
//   BARKPARK_TOKEN    ← was BARKPARK_API_TOKEN  (server-only read token)
const API_BASE =
  process.env.BARKPARK_API_URL ??
  process.env.BARKPARK_API_BASE ??
  "https://api.barkpark.cloud/w/hundesteder/p/default";
const DATASET = process.env.BARKPARK_DATASET ?? "production";
const TOKEN =
  process.env.BARKPARK_TOKEN ?? process.env.BARKPARK_API_TOKEN ?? "";

const PLACE_TYPE = "place";
const REVALIDATE_SECONDS = 300;
// Pagination bounds (task-32a7f8c07041d4d6): the query API defaults limit to
// 100 and CLAMPS it to 1000 (query_controller.ex), so an unpaginated query
// silently truncates at 100 published places. 1000/page x 20 pages = 20k
// places, far beyond any plausible corpus — the cap exists so a misbehaving
// upstream that always returns full pages cannot spin the walk forever, and
// hitting it is reported out loud, never absorbed.
const PLACES_PAGE_LIMIT = 1000;
const PLACES_MAX_PAGES = 20;

/* ── domain types ───────────────────────────────────────────────────────── */

export interface Place {
  id: string;
  slug: string;
  title: string;
  description?: string;
  category?: string;
  city?: string;
  /** Latitude, parsed from the upstream string. */
  lat: number;
  /** Longitude, parsed from the upstream string. */
  lng: number;
  address?: {
    street?: string;
    postalCode?: string;
    country?: string;
  };
  websiteUrl?: string;
  priceRange?: string;
  tags: string[];
}

/* ── upstream parsing ───────────────────────────────────────────────────── */

function str(v: unknown): string | undefined {
  return typeof v === "string" && v.length > 0 ? v : undefined;
}

/** Coerce a coordinate that arrives as a numeric string (or, defensively, a
 * number). Returns undefined when the value can't be read as a finite number. */
function coord(v: unknown): number | undefined {
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (typeof v === "string" && v.trim() !== "") {
    const n = parseFloat(v);
    if (Number.isFinite(n)) return n;
  }
  return undefined;
}

/** Normalise one raw upstream `place` document into a `Place`, or null if it
 * lacks a usable coordinate (the map can only show what it can place, and the
 * detail page centres on the pin). */
function normalizePlace(raw: unknown): Place | null {
  if (!raw || typeof raw !== "object") return null;
  const r = raw as Record<string, unknown>;

  const geo = (r.geo && typeof r.geo === "object" ? r.geo : {}) as Record<
    string,
    unknown
  >;
  const lat = coord(geo.latitude);
  const lng = coord(geo.longitude);
  if (lat === undefined || lng === undefined) return null;
  // A literal (0,0) is an unset default, not a real place — drop it.
  if (lat === 0 && lng === 0) return null;

  const id = str(r._id) ?? str(r.id) ?? str(r.slug);
  if (!id) return null;

  const slug = str(r.slug) ?? id;

  const addrRaw = (
    r.address && typeof r.address === "object" ? r.address : {}
  ) as Record<string, unknown>;
  const address = {
    street: str(addrRaw.street),
    postalCode: str(addrRaw.postal_code),
    country: str(addrRaw.country),
  };
  const hasAddress = address.street || address.postalCode || address.country;

  // Paper surfaces carry weighted tags (charter D8–D10): a flat-string-only
  // filter here silently drops any `{tag,strength,rationale}` object, so lean
  // on the shared `paperTags` normaliser instead (ported from
  // `web/lib/paper-tags.ts`, which fixed the identical bug in listings.ts).
  const tags = paperTags(r.tags as PaperTag[] | undefined);

  return {
    id,
    slug,
    title: str(r.title) ?? id,
    description: str(r.description),
    category: str(r.category),
    city: str(r.city),
    lat,
    lng,
    address: hasAddress ? address : undefined,
    websiteUrl: str(r.website_url),
    priceRange: str(r.price_range),
    tags,
  };
}

/* ── upstream fetch ─────────────────────────────────────────────────────── */

function authHeaders(): HeadersInit {
  const h: Record<string, string> = { Accept: "application/json" };
  if (TOKEN) h.Authorization = `Bearer ${TOKEN}`;
  return h;
}

async function bpFetch(path: string): Promise<unknown | null> {
  const url = `${API_BASE}${path}`;
  try {
    const res = await fetch(url, {
      headers: authHeaders(),
      next: { revalidate: REVALIDATE_SECONDS, tags: ["places"] },
    });
    if (!res.ok) return null;
    return (await res.json()) as unknown;
  } catch {
    return null;
  }
}

/** Sort: group by city (alphabetical), then by title within a city. Gives the
 * landing grid and the index a stable, scannable order. */
function sortPlaces(a: Place, b: Place): number {
  const c = (a.city ?? "").localeCompare(b.city ?? "", "nb");
  if (c !== 0) return c;
  return a.title.localeCompare(b.title, "nb");
}

/**
 * Fetch every published place. Never throws — on any upstream failure or empty
 * result it returns `[]`, so callers render an empty state rather than crash.
 */
export async function fetchPlaces(): Promise<Place[]> {
  // Paginated (task-32a7f8c07041d4d6): one unbounded query used to ride the
  // server's DEFAULT limit of 100 and silently truncate a grown corpus. The
  // walk lives in lib/paginate.ts so the real loop is under test.
  const { rows, truncated } = await collectAllPages(
    async (limit, offset) => {
      const json = await bpFetch(
        `/v1/data/query/${encodeURIComponent(
          DATASET,
        )}/${PLACE_TYPE}?filter[status]=published&limit=${limit}&offset=${offset}`,
      );
      if (json === null) return null;
      return (
        (json as { result?: { documents?: unknown[] } }).result?.documents ?? []
      );
    },
    { limit: PLACES_PAGE_LIMIT, maxPages: PLACES_MAX_PAGES },
  );
  if (truncated !== undefined) {
    // Partial truth, said out loud — the never-throw law still holds, but a
    // silently shrunken directory is exactly the defect this walk retired.
    console.warn(
      `[places] PAGINATION COULD NOT TERMINATE CLEANLY (${truncated}) — ` +
        `rendering the ${rows.length} places collected so far`,
    );
  }
  return rows
    .map(normalizePlace)
    .filter((p): p is Place => p !== null)
    .sort(sortPlaces);
}

/**
 * Fetch a single published place by slug. Resolves against the full set (the
 * dataset is tiny — 12 docs — so a list-then-find is cheaper than a per-slug
 * filtered query, and it reuses the same cache entry as the listing pages).
 * Returns null when no place matches.
 */
export async function fetchPlaceBySlug(slug: string): Promise<Place | null> {
  const all = await fetchPlaces();
  return all.find((p) => p.slug === slug) ?? null;
}
