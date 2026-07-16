/**
 * Canonical Barkpark env-var names for the search-starter template — single
 * source of truth for the API base URL + read token.
 *
 * These follow the SAME cross-adapter contract the deploy engine injects at slot
 * boot (`deploy/lib/site-deploy-common.sh` RUNTIME_ALLOW: BARKPARK_API_URL,
 * BARKPARK_TOKEN, …) and that `templates/next-starter`, `templates/astro-starter`
 * and `templates/DEPLOYING.md` all use — the NAMES are identical across every
 * adapter so one .env works everywhere:
 *
 *   BARKPARK_API_URL   the API base — a bare origin (e.g.
 *                      https://guerrilla.barkpark.cloud). Consumed SERVER-SIDE
 *                      only (the finder's HTTP search proxy, graph, reader), so
 *                      it is NOT `NEXT_PUBLIC_`-prefixed and never reaches the
 *                      browser. The keystroke live-search path is a SEPARATE,
 *                      browser-visible WebSocket (NEXT_PUBLIC_BARKPARK_WS_URL, in
 *                      use-live-search) — it ships dark unless explicitly set.
 *   BARKPARK_TOKEN     server-only read token (undefined → anonymous public
 *                      reads). NEVER `NEXT_PUBLIC_` — Next would inline it into
 *                      the client bundle.
 *
 * Dev fallbacks: the older `NEXT_PUBLIC_BARKPARK_API_URL` / `NEXT_PUBLIC_API_URL`
 * names (web/ demo) and `BARKPARK_READ_TOKEN` are honored so an existing local
 * .env keeps working, but the DEPLOY path sets the canonical names above.
 *
 * Every consumer of `PUBLIC_API_URL` / `READ_TOKEN` is `import "server-only"`
 * (bp-fetch, barkpark-client, find-search, graph) or a Node route handler.
 */

type Env = Record<string, string | undefined>;

/** Local-dev default when no API URL is configured. */
export const DEFAULT_API_URL = "http://localhost:4000";

/**
 * Resolved Barkpark API base URL. Canonical `BARKPARK_API_URL` wins; the legacy
 * `NEXT_PUBLIC_*` names are dev fallbacks. Server-consumed only.
 */
export function resolveApiUrl(env: Env): string {
  return (
    env.BARKPARK_API_URL ??
    env.NEXT_PUBLIC_BARKPARK_API_URL ??
    env.NEXT_PUBLIC_API_URL ??
    DEFAULT_API_URL
  );
}

/**
 * Server-only read token. Canonical `BARKPARK_TOKEN` wins; the legacy
 * `BARKPARK_READ_TOKEN` is the fallback. Never `NEXT_PUBLIC_`, so it never
 * reaches the browser.
 */
export function resolveReadToken(env: Env): string | undefined {
  return env.BARKPARK_TOKEN ?? env.BARKPARK_READ_TOKEN;
}

/** Resolved API base URL for this process. */
export const PUBLIC_API_URL = resolveApiUrl(process.env);

/** Resolved server-only read token for this process (undefined → anonymous). */
export const READ_TOKEN = resolveReadToken(process.env);
