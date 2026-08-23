import "server-only";
import { collectAllPages } from "./paginate";
import { normalizePlace, sortPlaces, type Place } from "./normalize";

// The `Place` shape is re-exported so every consumer keeps importing it from
// `@/lib/places` — the data layer stays the one public door, and `normalize.ts`
// is an implementation detail that exists so the pure half is TESTABLE.
export type { Place } from "./normalize";

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
