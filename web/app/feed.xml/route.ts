import { client } from "@/lib/barkpark-client";
import { fetchPosts, postSlug, type PostDocument } from "@/lib/posts";
import {
  fetchPapers,
  paperSlug,
  paperTitle,
  paperExcerpt,
  type PaperDocument,
} from "@/lib/papers";
import { SITE_URL, absoluteUrl } from "@/lib/site-url";
import { readerHref } from "@/lib/find";

/**
 * RSS 2.0 feed for the public reader. Route Handler (not a page) so it serves
 * raw XML under `/feed.xml`. Built from the SAME bounded post + paper list
 * queries the pages use (50 each) — no bespoke fetch path. NEVER throws: on any
 * upstream failure it emits a valid, empty channel so a crawl never 500s.
 *
 * Freshness rides Next's Data Cache on the list queries; the handler itself is
 * revalidated hourly.
 */
export const revalidate = 3600;

interface FeedItem {
  title: string;
  link: string;
  description: string;
  date?: string;
}

/** Escape the five XML-significant characters for safe text/attribute nodes. */
function xmlEscape(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

/** RFC-822 date for `<pubDate>`, or undefined when the input is absent/invalid. */
function rfc822(iso?: string): string | undefined {
  if (!iso) return undefined;
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? undefined : d.toUTCString();
}

/** Sort key: newest first, by whatever timestamp the item carries. */
function ts(iso?: string): number {
  if (!iso) return 0;
  const t = new Date(iso).getTime();
  return Number.isNaN(t) ? 0 : t;
}

function renderItem(item: FeedItem): string {
  const pubDate = rfc822(item.date);
  return [
    "    <item>",
    `      <title>${xmlEscape(item.title)}</title>`,
    `      <link>${xmlEscape(item.link)}</link>`,
    `      <guid isPermaLink="true">${xmlEscape(item.link)}</guid>`,
    item.description
      ? `      <description>${xmlEscape(item.description)}</description>`
      : "",
    pubDate ? `      <pubDate>${pubDate}</pubDate>` : "",
    "    </item>",
  ]
    .filter(Boolean)
    .join("\n");
}

async function collectItems(): Promise<FeedItem[]> {
  const [posts, papers] = await Promise.all([
    fetchPosts(client),
    fetchPapers(client),
  ]);

  const postItems: FeedItem[] = posts.map((post: PostDocument) => ({
    title: post.title ?? "(untitled)",
    link: absoluteUrl(readerHref("post", postSlug(post))),
    description: post.excerpt ?? "",
    date: post._updatedAt ?? post._createdAt,
  }));

  const paperItems: FeedItem[] = papers.map((paper: PaperDocument) => ({
    title: paperTitle(paper),
    link: absoluteUrl(readerHref("paper", paperSlug(paper))),
    description: paperExcerpt(paper) ?? "",
    date: paper._updatedAt ?? paper._createdAt,
  }));

  return [...postItems, ...paperItems].sort((a, b) => ts(b.date) - ts(a.date));
}

export async function GET(): Promise<Response> {
  let items: FeedItem[] = [];
  try {
    items = await collectItems();
  } catch (err) {
    console.error("feed.xml: collectItems failed:", err);
    items = [];
  }

  const lastBuild =
    rfc822(items.find((i) => i.date)?.date) ?? new Date().toUTCString();

  const xml = [
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<rss version="2.0">',
    "  <channel>",
    "    <title>Barkpark</title>",
    `    <link>${xmlEscape(SITE_URL)}</link>`,
    "    <description>Published posts and papers from the Barkpark dataset.</description>",
    "    <language>en</language>",
    `    <lastBuildDate>${lastBuild}</lastBuildDate>`,
    `    <atom:link xmlns:atom="http://www.w3.org/2005/Atom" href="${xmlEscape(
      absoluteUrl("/feed.xml"),
    )}" rel="self" type="application/rss+xml" />`,
    ...items.map(renderItem),
    "  </channel>",
    "</rss>",
  ].join("\n");

  return new Response(xml, {
    headers: {
      "Content-Type": "application/rss+xml; charset=utf-8",
      "Cache-Control": "public, max-age=0, s-maxage=3600, stale-while-revalidate",
    },
  });
}
