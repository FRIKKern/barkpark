/**
 * Named GROQ-like query strings used by pages.
 *
 * Barkpark's query API currently exposes per-type endpoints — these strings are
 * ready for the codegen + typed-query migration (ADR-003, Phase 8). Today they
 * are informational; pages call the typed helpers in `lib/barkpark.ts`.
 */

export const allPosts = `*[_type == "post" && defined(publishedAt)] | order(publishedAt desc)`
export const postBySlug = `*[_type == "post" && slug.current == $slug][0]`
export const postsByAuthor = `*[_type == "post" && author._ref == $authorId] | order(publishedAt desc)`
export const postsByTag = `*[_type == "post" && $tagId in tags[]._ref] | order(publishedAt desc)`
export const allAuthors = `*[_type == "author"] | order(name asc)`
export const allTags = `*[_type == "tag"] | order(name asc)`

export const POSTS_PER_PAGE = 5
