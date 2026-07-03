/**
 * Single source of truth for this demo's public origin — the base every
 * absolute-URL surface (metadataBase, sitemap, robots, RSS feed) resolves
 * against. Derived ONCE here so the env precedence never drifts between them.
 *
 * Precedence:
 *   1. NEXT_PUBLIC_SITE_URL  — explicit, wins everywhere (prod canonical).
 *   2. VERCEL_URL            — the per-deploy hostname Vercel injects (no
 *      scheme, so we prepend https://). Covers preview + prod when (1) is unset.
 *   3. http://localhost:3000 — sane local-dev fallback so `next dev` still
 *      produces resolvable OG/canonical URLs instead of `null`.
 *
 * No secret lives here (it's a public origin), and both server components and
 * route handlers import it, so this is a plain module — not `server-only`.
 */

/** Local-dev default when neither NEXT_PUBLIC_SITE_URL nor VERCEL_URL is set. */
export const DEFAULT_SITE_URL = "http://localhost:3000";

function stripTrailingSlash(u: string): string {
  return u.endsWith("/") ? u.slice(0, -1) : u;
}

/** Resolve the origin from an env bag; pure, so it's unit-testable. */
export function resolveSiteUrl(
  env: Record<string, string | undefined>,
): string {
  const explicit = env.NEXT_PUBLIC_SITE_URL;
  if (explicit && explicit.trim() !== "") {
    return stripTrailingSlash(explicit.trim());
  }

  const vercel = env.VERCEL_URL;
  if (vercel && vercel.trim() !== "") {
    return `https://${stripTrailingSlash(vercel.trim())}`;
  }

  return DEFAULT_SITE_URL;
}

/** The resolved public origin for this process, without a trailing slash. */
export const SITE_URL = resolveSiteUrl(process.env);

/** Build an absolute URL for a site-relative path (`/d/post/x` → origin + path). */
export function absoluteUrl(path: string): string {
  return `${SITE_URL}${path.startsWith("/") ? path : `/${path}`}`;
}
