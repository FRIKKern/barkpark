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
export const DATASET = process.env.BARKPARK_DATASET || "docs";

/** Workspace slug — the tenancy the token-scoped search route resolves under. */
export const WORKSPACE = process.env.BARKPARK_WORKSPACE || "default";

/** Project slug — the tenancy the token-scoped search route resolves under. */
export const PROJECT = process.env.BARKPARK_PROJECT || "default";

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
