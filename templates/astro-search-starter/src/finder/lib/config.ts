/**
 * Single source of truth for the tenancy + dataset this search site reads from.
 *
 * The whole finder + reader + graph landing run against ONE workspace / project
 * / dataset. In the `web/` demo these were three hard-coded literals scattered
 * across find-search (`/w/default/p/default`), config (`docs`) and the live-
 * search topic (`default:default`); in the template they are ALL env-driven so
 * the same build deploys unchanged against any Barkpark instance.
 *
 *   BARKPARK_DATASET    — dataset name          (default "docs")
 *   BARKPARK_WORKSPACE  — workspace slug         (default "default")
 *   BARKPARK_PROJECT    — project slug           (default "default")
 *
 * BROWSER REACH (charter D52): these three constants are read by CLIENT code
 * too — `use-live-search` builds the channel topic `search:<ws>:<proj>:<dataset>`
 * from them. A bare `BARKPARK_*` name is not inlined into the client bundle, so
 * the browser would silently fall back to the defaults above and ask for
 * `search:default:default:docs` — a topic `SearchChannel.join/3` REFUSES with
 * reason "unknown_dataset" whenever that dataset is not in the resolved
 * project. The join fails, so the LIVE badge never lights and every keystroke
 * keeps riding the same-origin HTTP route: search still works, it just pays a
 * round trip it did not have to, and the refusal reason is the whole diagnosis.
 * `next.config.mjs` therefore DERIVES `NEXT_PUBLIC_BARKPARK_{DATASET,WORKSPACE,
 * PROJECT}` from the server vars (no deploy-allowlist change, charter D47), and
 * each constant below reads the browser-visible name FIRST, falling back to the
 * bare server name so server-only builds and local `.env` files keep working.
 *
 * Why plain `.ts` constants and not `server-only`: these are NAMES (no secret),
 * and a couple of importers are shared between server libs and route handlers.
 * The token + base URL still live behind `server-only` modules (bp-fetch,
 * barkpark-client) — only the scope labels are centralised here.
 *
 * NOTE for cache coherence: `lib/bp-tags.ts` derives its default revalidation
 * dataset from `DATASET`, so the webhook busts exactly the caches the
 * finder/reader/graph tagged their reads with. Keep them in lock-step by
 * importing — never by re-declaring a second literal.
 */

/** Dataset name the finder, reader, and graph landing all read from. */
export const DATASET =
  process.env.NEXT_PUBLIC_BARKPARK_DATASET || process.env.BARKPARK_DATASET || "docs";

/** Workspace slug — the tenancy the token-scoped search route resolves under. */
export const WORKSPACE =
  process.env.NEXT_PUBLIC_BARKPARK_WORKSPACE || process.env.BARKPARK_WORKSPACE || "default";

/** Project slug — the tenancy the token-scoped search route resolves under. */
export const PROJECT =
  process.env.NEXT_PUBLIC_BARKPARK_PROJECT || process.env.BARKPARK_PROJECT || "default";

/**
 * The `/w/:ws/p/:proj` path prefix for the token-scoped (Indx) search route.
 * Replaces the `web/` demo's hard-coded `/w/default/p/default`.
 */
export const SCOPE = `/w/${WORKSPACE}/p/${PROJECT}`;

/**
 * The `<ws>:<proj>` scope segment the live-search WebSocket topic encodes
 * (`search:<ws>:<proj>:<dataset>`). Mirrors {@link SCOPE} for the WS transport.
 */
export const WS_SCOPE = `${WORKSPACE}:${PROJECT}`;

/* ── site copy ─────────────────────────────────────────────────────────── */

/**
 * The frontpage hero copy — ONE voice, declared once and read by BOTH surfaces
 * that speak it: the hero in `components/finder` and the `<meta name=
 * "description">` in `app/layout`. They used to be two independently authored
 * strings and had already drifted into two different pitches shipping in the
 * same HTML ("across every document" vs "over a Barkpark dataset … deployed
 * from one template"). Declaring the tagline here is what keeps them equal.
 *
 * The `NEXT_PUBLIC_SITE_*` overrides are a SELF-HOST seam only. The managed
 * deploy path cannot carry `NEXT_PUBLIC_*` names at all — all three layers of
 * the engine allowlist are closed over `BARKPARK_*` (charter D47; the same
 * reason `next.config.mjs` DERIVES the browser vars) — so on every provisioned
 * site the fallbacks below ARE the shipped copy. Write them as finished copy,
 * never as placeholders.
 */
export const SITE_EYEBROW = process.env.NEXT_PUBLIC_SITE_EYEBROW || "Search";

/** Hero headline. See {@link SITE_TAGLINE} for the env-seam caveat. */
export const SITE_TITLE = process.env.NEXT_PUBLIC_SITE_TITLE || "Search everything.";

/** Hero sub-headline AND the document `<meta name="description">`. */
export const SITE_TAGLINE =
  process.env.NEXT_PUBLIC_SITE_TAGLINE ||
  "Instant search across every document — misspellings widened server-side by Postgres trigram — with a live graph of how it all connects.";
