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
 * the browser would silently fall back to the defaults above and join
 * `search:default:default:docs` — a topic that JOINS GREEN and then returns
 * count=0 forever, which reads as "live search is broken" with no error anywhere.
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
