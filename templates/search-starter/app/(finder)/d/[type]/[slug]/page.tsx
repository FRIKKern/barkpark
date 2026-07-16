import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { getDocument } from "@/lib/get-document";
import { PUBLIC_API_URL } from "@/lib/bp-env";
import { DOC_TYPES } from "@/lib/find";
import { metadataFromPreview } from "@/lib/preview-metadata";
import { DocumentDetail } from "@/components/document-detail";

// ISR: getDocument wraps its fetch in unstable_cache (5-min revalidate, busted
// on-demand via revalidateTag("doc:<type>")), so the per-request work here is a
// warm cache read. notFound() handles unknown slugs.
export const revalidate = 300;

/** The doc types the unified `/d/[type]/[slug]` route knows how to render —
 * derived from the config-driven `DOC_TYPES` (so a single-type seed site scopes
 * to its type), PLUS the media types (graph nodes are navigable too — a media
 * node opens a MetaCard summary instead of a 404 dead-end). Anything else is a
 * real 404: both engines scope browse to the DOC_TYPES set, so an unknown type
 * can only arrive via a hand-typed URL. */
const KNOWN_TYPES = new Set<string>([
  ...DOC_TYPES.map((t) => t.type),
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
  // missing doc yields a real HTTP 404 rather than a 200 from the page throwing
  // notFound() after headers are already sent.
  if (!doc && !error) notFound();
  if (!doc) return { title: "Document unavailable · Barkpark" };

  // ONE preview manifest drives every meta tag. The v1 envelope hoists content
  // keys to the top level, so the write-time card arrives as `doc.preview`;
  // absent (legacy unstamped) → the helper degrades to title-only + the branded
  // default card. `other` carries the per-document `bp-doc-id` HEALTH marker.
  const base = metadataFromPreview({
    preview: (doc as { preview?: unknown }).preview,
    apiOrigin: PUBLIC_API_URL,
    pageUrl: `/d/${encodeURIComponent(type)}/${encodeURIComponent(slug)}`,
    fallbackTitle: doc.title ?? slug,
  });
  return {
    ...base,
    other: { ...(base.other ?? {}), "bp-doc-id": doc._id },
  };
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
