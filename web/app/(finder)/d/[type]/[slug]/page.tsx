import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { getDocument } from "@/lib/get-document";
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

  return {
    title: `${doc.title ?? slug} · Barkpark`,
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
