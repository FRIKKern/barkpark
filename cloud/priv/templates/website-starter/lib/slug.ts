// A document's slug as it is actually stored. The Barkpark Studio writes a slug
// field as a plain string (its Generate button stores `"my-post"`); the seeds
// and Sanity-shaped content store `{ current: "my-post" }`. Reading only
// `slug.current` made every post slugged in the Studio link by id, drop out of
// the sitemap and 404 at its own slug URL — so every read goes through here.
//
// Dependency-free (no 'server-only', no @barkpark/*): safe in server and client
// components alike, and importable straight from the template source in tests.

/** A slug value in either stored shape. */
export type SlugValue = string | { current?: string | null } | null | undefined

/** The slug string, whichever shape it was stored in; `undefined` when unset. */
export function slugOf(slug: SlugValue): string | undefined {
  if (typeof slug === 'string') return slug || undefined
  if (slug && typeof slug === 'object' && typeof slug.current === 'string') {
    return slug.current || undefined
  }
  return undefined
}
