/**
 * Canonical Barkpark env-var names for this demo — single source of truth, with
 * backwards-compatible fallback to the pre-unification names (task dwb-3).
 *
 * The whole repo now points Next.js apps at Barkpark with ONE set of names
 * (documented in `templates/DEPLOYING.md`). `web/` used its own older names; we
 * read the canonical name FIRST and fall back to the old one so an already-
 * deployed Vercel project (whose env still carries the old names) keeps working.
 *
 *   NEXT_PUBLIC_BARKPARK_API_URL  browser-exposed base URL   ← was NEXT_PUBLIC_API_URL
 *   BARKPARK_TOKEN                server-only read token      ← was BARKPARK_READ_TOKEN
 *   BARKPARK_DATASET              dataset name (unchanged — see lib/config.ts)
 *
 * Public / server split is preserved EXACTLY: only the URL carries a
 * `NEXT_PUBLIC_` prefix (safe to inline into client JS); the token has none, so
 * Next never bundles it into the browser. Consumers of `READ_TOKEN` remain
 * `import "server-only"`.
 */

type Env = Record<string, string | undefined>;

/** Local-dev default when no API URL is configured. */
export const DEFAULT_API_URL = "http://localhost:4000";

/**
 * Browser-exposed Barkpark API base URL. Canonical name wins; the old name is
 * the fallback. Both are `NEXT_PUBLIC_` so Next inlines whichever is set.
 */
export function resolveApiUrl(env: Env): string {
  return (
    env.NEXT_PUBLIC_BARKPARK_API_URL ??
    env.NEXT_PUBLIC_API_URL ??
    DEFAULT_API_URL
  );
}

/**
 * Server-only read token. Canonical name wins; the old name is the fallback.
 * Neither is `NEXT_PUBLIC_`, so this value never reaches the browser.
 */
export function resolveReadToken(env: Env): string | undefined {
  return env.BARKPARK_TOKEN ?? env.BARKPARK_READ_TOKEN;
}

/** Resolved API base URL for this process. */
export const PUBLIC_API_URL = resolveApiUrl(process.env);

/** Resolved server-only read token for this process (undefined → anonymous). */
export const READ_TOKEN = resolveReadToken(process.env);
