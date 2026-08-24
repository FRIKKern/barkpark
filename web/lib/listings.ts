import "server-only";
import { unstable_cache } from "next/cache";
import { DATASET } from "@/lib/config";
import { bpAll } from "@/lib/bp-tags";
import { PUBLIC_API_URL } from "@/lib/bp-env";
import { bpFetchJson, BpUpstreamError, humanUpstreamMessage } from "@/lib/bp-fetch";
import {
  resolveListings,
  type Listing,
  type ResolvedListings,
} from "@/lib/listings-data";
import { paperTags, type PaperTag } from "@/lib/paper-tags";
import { collectAllPages } from "@/lib/paginate";

/**
 * The data layer for the listing-directory landing — the map's source of pins.
 *
 * It is built to be a TEMPLATE seam, not a hard dependency on any one backend:
 *
 *   - Out of the box (no env set) it returns the bundled `SAMPLE_LISTINGS`, so
 *     `pnpm dev` shows a real map immediately.
 *   - Point it at a live source by setting `LISTINGS_TYPE` (the document/content
 *     type to query) — it then fetches published rows from the API the rest of
 *     the demo already talks to and projects each row's coordinate fields into
 *     the flat `Listing` shape the map renders.
 *
 * Mirrors `lib/graph.ts`: a `server-only` module, a hand-rolled `unstable_cache`
 * (the Phoenix origin marks responses `private, max-age=0`, so per-fetch
 * revalidate is a no-op), and — crucially — it NEVER throws. A hard upstream
 * failure degrades to the sample set so the landing always has something to map
 * rather than crashing the Server Component.
 */

/** Cache tag for the listings Data Cache — `revalidateTag(LISTINGS_TAG)` busts it. */
export const LISTINGS_TAG = "listings";

const API_URL = PUBLIC_API_URL;

/** The content type to query for listings. Unset → use the bundled sample set. */
const LISTINGS_TYPE = process.env.LISTINGS_TYPE || "";

/** Cap on rows pulled from the source — a directory map wants every pin, but a
 * sane ceiling keeps one runaway dataset from blowing the payload. Used as the
 * PER-PAGE size for the offset walk below (task-269eefbe4864d8a5): this used
 * to be the only page fetched, so a corpus over `LISTINGS_LIMIT` silently lost
 * pins with no error signal — latent while `LISTINGS_TYPE` is unset, but real
 * the moment a deployment turns this source on against a corpus that size. */
const LISTINGS_LIMIT = Number(process.env.LISTINGS_LIMIT) || 500;
/** Bounds the walk so a misbehaving upstream that never serves a short page
 * can't spin it forever — mirrors PAPERS_MAX_PAGES / POSTS_MAX_PAGES
 * (lib/papers.ts, lib/posts.ts) and apps/hundesteder/lib/paginate.ts. */
const LISTINGS_MAX_PAGES = 20;

export type { Listing };

/* ── upstream parsing ───────────────────────────────────────────────────── */

function str(v: unknown): string | undefined {
  return typeof v === "string" && v.length > 0 ? v : undefined;
}

/** Coerce a coordinate that may arrive as a number or a numeric string. */
function coord(v: unknown): number | undefined {
  if (typeof v === "number" && Number.isFinite(v)) return v;
  if (typeof v === "string" && v.trim() !== "") {
    const n = Number(v);
    if (Number.isFinite(n)) return n;
  }
  return undefined;
}

/** Reach into an object by a dotted path (`"geo.latitude"`) without throwing. */
function dig(obj: Record<string, unknown>, path: string): unknown {
  let cur: unknown = obj;
  for (const key of path.split(".")) {
    if (!cur || typeof cur !== "object") return undefined;
    cur = (cur as Record<string, unknown>)[key];
  }
  return cur;
}

/** Pull a lat/lng pair out of a row, tolerant of the common nestings:
 * `geo.{latitude,longitude}` (the schema this template assumes), a flat
 * `lat`/`lng`, or a GeoJSON-ish `location.coordinates: [lng, lat]`. */
function readLatLng(row: Record<string, unknown>): { lat: number; lng: number } | null {
  const lat =
    coord(dig(row, "geo.latitude")) ??
    coord(row.lat) ??
    coord(row.latitude) ??
    coord(dig(row, "location.lat"));
  const lng =
    coord(dig(row, "geo.longitude")) ??
    coord(row.lng) ??
    coord(row.lon) ??
    coord(row.longitude) ??
    coord(dig(row, "location.lng"));
  if (lat === undefined || lng === undefined) return null;
  // A row with a coordinate at literal (0,0) is almost always an unset default,
  // not a buoy in the Gulf of Guinea — drop it rather than map an island of one.
  if (lat === 0 && lng === 0) return null;
  return { lat, lng };
}

/** Normalise one raw upstream document into a `Listing`, or null if it has no
 * usable coordinate (a directory map can only show things it can place). */
function normalizeListing(raw: unknown): Listing | null {
  if (!raw || typeof raw !== "object") return null;
  const r = raw as Record<string, unknown>;

  const content = (
    r.content && typeof r.content === "object" ? r.content : r
  ) as Record<string, unknown>;

  // Coordinates may sit at the document top level OR inside `content`, depending
  // on how the source stores custom fields — check both.
  const here = readLatLng(r) ?? readLatLng(content);
  if (!here) return null;

  const id = str(r._id) ?? str(r.id) ?? str(r.slug);
  if (!id) return null;

  // Tags may arrive flat (`["dog_friendly"]`) OR as authoring-excellence
  // weighted objects (`[{tag,strength,rationale}]`) — the same dual shape the
  // Paper surfaces carry (charter D8–D10). Lean on the shared `paperTags`
  // normalizer so weighted-tag listings are no longer silently dropped; it
  // tolerates a non-array (→ []), reads both shapes, trims + dedups first-seen.
  const tags = paperTags((content.tags ?? r.tags) as PaperTag[] | undefined);

  return {
    id,
    type: str(r._type) ?? str(r.type) ?? (LISTINGS_TYPE || "listing"),
    slug: str(r.slug) ?? str(content.slug) ?? id,
    title: str(content.title) ?? str(r.title) ?? id,
    lat: here.lat,
    lng: here.lng,
    category: str(content.category) ?? str(content.place_type),
    city: str(dig(content, "address.city")) ?? str(content.city),
    description: str(content.description),
    address: str(dig(content, "address.street")) ?? str(content.address),
    url: str(content.website_url) ?? str(content.url),
    priceRange: str(content.price_range),
    tags: tags && tags.length > 0 ? tags : undefined,
  };
}

/* ── upstream fetch ─────────────────────────────────────────────────────── */

/** Fetch one page of published listings of `LISTINGS_TYPE`. Returns null on a
 * failed fetch (the `collectAllPages` "page failed" signal) rather than
 * throwing, EXCEPT the first page — see `rawListings` for why. */
async function fetchListingsPage(
  limit: number,
  offset: number,
): Promise<unknown[]> {
  const qs = new URLSearchParams({
    "filter[status]": "published",
    limit: String(limit),
    offset: String(offset),
  });
  const url = `${API_URL}/v1/data/query/${encodeURIComponent(DATASET)}/${encodeURIComponent(
    LISTINGS_TYPE,
  )}?${qs.toString()}`;

  let json: unknown;
  try {
    json = await bpFetchJson(url);
  } catch (e) {
    if (e instanceof BpUpstreamError) {
      throw new Error(`listings ${e.status}: ${humanUpstreamMessage(e)}`);
    }
    throw e;
  }

  // Accept both the query envelope (`{ result: { documents } }`) and a bare
  // array, so the seam survives a minor API shape drift.
  return Array.isArray(json)
    ? json
    : (((json as { result?: { documents?: unknown[] } })?.result?.documents ??
        (json as { documents?: unknown[] })?.documents) ||
      []);
}

/** Raw, uncached query for published listings of `LISTINGS_TYPE`, walked page
 * by page until a short page terminates (task-269eefbe4864d8a5 — this used to
 * be a single `limit=LISTINGS_LIMIT` query that silently truncated past that
 * many rows). Caching is layered above by `cachedListings`. Only called when
 * `LISTINGS_TYPE` is set. */
async function rawListings(): Promise<Listing[]> {
  const { rows, truncated } = await collectAllPages(
    async (limit, offset) => {
      try {
        return await fetchListingsPage(limit, offset);
      } catch (err) {
        // A first-page failure keeps the PRE-EXISTING behaviour: this used to
        // be the only query issued, so its rejection propagated to
        // `fetchListings`'s try/catch (degrade to SAMPLE_LISTINGS). A later
        // page failing mid-walk is new territory the walk now recovers from.
        if (offset === 0) throw err;
        return null;
      }
    },
    { limit: LISTINGS_LIMIT, maxPages: LISTINGS_MAX_PAGES },
  );
  if (truncated !== undefined) {
    console.warn(
      `[listings] PAGINATION COULD NOT TERMINATE CLEANLY (${truncated}) — ` +
        `returning the ${rows.length} listings collected so far`,
    );
  }

  return rows
    .map(normalizeListing)
    .filter((l): l is Listing => l !== null);
}

const cachedListings = unstable_cache(rawListings, ["listings", DATASET, LISTINGS_TYPE], {
  revalidate: 300,
  tags: [LISTINGS_TAG, bpAll()],
});

/**
 * Fetch the listings for the map landing WITH their provenance. Never throws:
 * with no `LISTINGS_TYPE` configured, or on any upstream failure / empty
 * result, it falls back to the bundled sample set so the directory always
 * renders a populated map.
 *
 * The fallback used to be silent (task-78bd64a68c6de26f): a bare `catch`
 * returned the 13 bundled pins and a deployment with a BROKEN live source drew
 * exactly the same map as a working one, with no log line to tell them apart.
 * The degrade stays — a crashed Server Component is worse — but it now names
 * itself. `resolveListings` (lib/listings-data.ts) owns the four-way decision
 * and builds the operator-facing line; this function fetches and logs it.
 */
export async function fetchListingsResult(): Promise<ResolvedListings> {
  if (!LISTINGS_TYPE) return resolveListings({ configured: false });

  // Capture the failure instead of swallowing it: the CAUSE is the whole point
  // of the log line below, and a bare `catch {}` threw it away.
  let live: Listing[] | null = null;
  let error: unknown;
  try {
    live = await cachedListings();
  } catch (e) {
    error = e;
  }

  const resolved = resolveListings({
    configured: true,
    sourceName: LISTINGS_TYPE,
    live,
    error,
  });
  if (resolved.notice) console.warn(resolved.notice);
  return resolved;
}

/**
 * The rows only — the shape callers that do not care about provenance keep.
 * Behaviour is unchanged from before: never throws, always renderable.
 */
export async function fetchListings(): Promise<Listing[]> {
  return (await fetchListingsResult()).listings;
}
