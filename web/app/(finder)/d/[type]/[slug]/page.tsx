import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { getDocument } from "@/lib/get-document";
import { readerHref } from "@/lib/find";
import { PUBLIC_API_URL } from "@/lib/bp-env";
import { metadataFromPreview } from "@/lib/preview-metadata";
import { DocumentDetail } from "@/components/document-detail";

// ISR: getDocument wraps its fetch in unstable_cache (5-min revalidate, busted
// on-demand via revalidateTag("doc:<type>")), so the per-request work here is a
// warm cache read. notFound() handles unknown slugs.
export const revalidate = 300;

/** The doc types the unified `/d/[type]/[slug]` route knows how to render.
 * Anything else is a real 404 — both engines scope browse to this set, so an
 * unknown type can only arrive via a hand-typed URL. */
const KNOWN_TYPES = new Set([
  "post",
  "paper",
  "sheet",
  "page",
  "author",
  "category",
  "project",
  // Media types are graph nodes too — render them as MetaCards so clicking a
  // media node in the landing graph opens a summary instead of a 404 dead-end.
  "mediaAsset",
  "mediaCollection",
]);

type Params = Promise<{ type: string; slug: string }>;

export async function generateMetadata({
  params,
}: {
  params: Params;
}): Promise<Metadata> {
  const { type, slug } = await params;
  if (!KNOWN_TYPES.has(type)) notFound();

  const { doc, error } = await getDocument(type, slug);
  // 404 here — metadata resolves before the response status commits, so a
  // missing doc yields a real HTTP 404 rather than a 200 from the page
  // throwing notFound() after headers are already sent (mirrors posts/[slug]).
  if (!doc && !error) notFound();
  if (!doc) return { title: "Document unavailable · Barkpark" };

  // ONE preview manifest drives every meta tag. The v1 envelope hoists content
  // keys to the top level, so the write-time card arrives as `doc.preview`
  // ({title,type,description,url,image,extensions}) — image srcs are relative
  // and absolutized against the API origin. Absent (legacy unstamped) → the
  // helper degrades to title-only + the branded default card.
  return metadataFromPreview({
    preview: (doc as { preview?: unknown }).preview,
    apiOrigin: PUBLIC_API_URL,
    pageUrl: readerHref(type, slug),
    fallbackTitle: doc.title ?? slug,
  });
}

export default async function DetailPage({ params }: { params: Params }) {
  const { type, slug } = await params;
  if (!KNOWN_TYPES.has(type)) notFound();

  // getDocument is React-cached, so this re-fetch dedups with generateMetadata's
  // call within the same request — one upstream hit, not two.
  const { doc, error } = await getDocument(type, slug);
  if (!error && !doc) notFound();

  return <DocumentDetail type={type} slug={slug} />;
}
