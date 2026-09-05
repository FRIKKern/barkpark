import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { getDocument } from "@/lib/get-document";
import { readerHref } from "@/lib/find";
import { PUBLIC_API_URL } from "@/lib/bp-env";
import { DOC_TYPES } from "@/lib/find";
import { metadataFromPreview } from "@/lib/preview-metadata";
import { DocumentDetail } from "@/components/document-detail";

// ISR: getDocument wraps its fetch in unstable_cache (5-min revalidate, busted
// on-demand via revalidateTag("doc:<type>")), so the per-request work here is a
// warm cache read. notFound() handles unknown slugs.
export const revalidate = 300;

/** The doc types the unified `/d/[type]/[slug]` route knows how to render —
 * exactly the config-driven `DOC_TYPES` (so a single-type seed site scopes to
 * its type). Media types are deliberately NOT here: `mediaAsset` /
 * `mediaCollection` are not queryable document types upstream
 * (`/v1/data/query/<ds>/mediaAsset` is a 404, and the list-op throws on it),
 * so admitting them turned every media graph-node click into a guaranteed red
 * failure panel. They 404 honestly instead. Anything else is a real 404 too:
 * both engines scope browse to the DOC_TYPES set, so an unknown type can only
 * arrive via a hand-typed URL. */
const KNOWN_TYPES = new Set<string>(DOC_TYPES.map((t) => t.type));

type Params = Promise<{ type: string; slug: string }>;

export async function generateMetadata({
  params,
}: {
  params: Params;
}): Promise<Metadata> {
  const { type, slug } = await params;
  if (!KNOWN_TYPES.has(type)) notFound();

  const { doc, error } = await getDocument(type, slug);
  // Missing doc → notFound(). This yields a REAL HTTP 404 only because the
  // detail segment deliberately ships NO loading.tsx: on Next 16.x a
  // segment-level Suspense boundary under the force-dynamic (finder) layout
  // streams the fallback shell — committing HTTP 200 — before this resolves,
  // turning every notFound() into a soft 404 (200 + embedded
  // NEXT_HTTP_ERROR_FALLBACK;404). Proven live; the old claim that metadata
  // alone beats the status commit was falsified. Do NOT re-add loading.tsx
  // here without re-proving the 404 status via next build + start + curl.
  if (!doc && !error) notFound();
  if (!doc) return { title: "Document unavailable · Barkpark" };

  // ONE preview manifest drives every meta tag. The v1 envelope hoists content
  // keys to the top level, so the write-time card arrives as `doc.preview`;
  // absent (legacy unstamped) → the helper degrades to title-only + the branded
  // default card. `other` carries the per-document `bp-doc-id` HEALTH marker.
  const base = metadataFromPreview({
    preview: (doc as { preview?: unknown }).preview,
    apiOrigin: PUBLIC_API_URL,
    pageUrl: readerHref(type, slug),
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
