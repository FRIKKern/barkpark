import type { MetadataRoute } from "next";
import { client } from "@/lib/barkpark-client";
import { fetchPosts, postSlug } from "@/lib/posts";
import { fetchPapers, paperSlug } from "@/lib/papers";
import { paperTags } from "@/lib/paper-tags";
import { absoluteUrl } from "@/lib/site-url";
import { readerHref } from "@/lib/find";

/**
 * Dynamic sitemap for the public reader. Enumerates the canonical
 * `/d/[type]/[slug]` URLs for every published post + paper (bounded by the
 * shared list queries — 50 each), the papers listing, and one entry per
 * distinct paper tag (`/tags/<tag>`), plus the home route.
 *
 * Reuses the SAME server client + list helpers the pages use — no bespoke
 * fetch path. NEVER throws: any upstream failure degrades to the static routes
 * so a build/crawl never breaks on a flaky API.
 *
 * `lastModified` comes from each doc's `_updatedAt` when parseable.
 */
export const revalidate = 3600;

/** Parse an ISO timestamp into a Date, or undefined when absent/invalid. */
function lastModified(iso?: string): Date | undefined {
  if (!iso) return undefined;
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? undefined : d;
}

export default async function sitemap(): Promise<MetadataRoute.Sitemap> {
  const staticRoutes: MetadataRoute.Sitemap = [
    { url: absoluteUrl("/"), changeFrequency: "daily", priority: 1 },
    { url: absoluteUrl("/papers"), changeFrequency: "daily", priority: 0.8 },
  ];

  try {
    const [posts, papers] = await Promise.all([
      fetchPosts(client),
      fetchPapers(client),
    ]);

    const postEntries: MetadataRoute.Sitemap = posts.map((post) => ({
      url: absoluteUrl(readerHref("post", postSlug(post))),
      lastModified: lastModified(post._updatedAt),
      changeFrequency: "weekly",
      priority: 0.7,
    }));

    const paperEntries: MetadataRoute.Sitemap = papers.map((paper) => ({
      url: absoluteUrl(readerHref("paper", paperSlug(paper))),
      lastModified: lastModified(paper._updatedAt),
      changeFrequency: "weekly",
      priority: 0.7,
    }));

    const tags = new Set<string>();
    for (const paper of papers) for (const t of paperTags(paper.tags)) tags.add(t);
    const tagEntries: MetadataRoute.Sitemap = [...tags].map((tag) => ({
      url: absoluteUrl(`/tags/${encodeURIComponent(tag)}`),
      changeFrequency: "weekly",
      priority: 0.5,
    }));

    return [...staticRoutes, ...postEntries, ...paperEntries, ...tagEntries];
  } catch {
    // Upstream unavailable — still emit a valid sitemap of the static routes.
    return staticRoutes;
  }
}
