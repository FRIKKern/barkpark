/**
 * basePath-aware URL builder for CLIENT-side fetches.
 *
 * This site is MULTI-route and served under a sub-path (`/sites/<slug>/`), so
 * `next.config.mjs` bakes a `basePath` (charter D6). Next auto-prefixes
 * `<Link>`, `router.push`, `usePathname`, next/image and its own RSC requests —
 * but NOT hand-written `fetch("/api/…")` calls, which would escape to the domain
 * root and 404 under the sub-path. Every client fetch to a same-origin route
 * MUST go through {@link apiPath}.
 *
 * The base path is inlined at build time via `next.config.mjs`'s `env` key
 * (`NEXT_PUBLIC_BP_BASE_PATH`), so it is available in the client bundle. Empty
 * string when the site is served at the domain root (local dev) — `apiPath` is
 * then a no-op.
 */
const BASE_PATH = (process.env.NEXT_PUBLIC_BP_BASE_PATH || "").replace(/\/+$/, "");

/** Prefix a root-absolute same-origin path with the site's basePath. */
export function apiPath(path: string): string {
  return `${BASE_PATH}${path}`;
}
