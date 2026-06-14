import { getDocument } from "@/lib/get-document";
import { paperBlocks, type PaperDocument } from "@/lib/papers";
import type { PostDocument } from "@/lib/posts";
import { PostArticle } from "@/components/post-article";
import { PortableDoc } from "@/components/portable-doc";
import { SheetGrid, type SheetTab } from "@/components/sheet-grid";
import { MetaCard } from "@/components/meta-card";
import { DetailChrome } from "@/components/detail-chrome";

/**
 * Render the body for a resolved document, dispatched on `_type`. Text types
 * (post / paper) sit in a centred, narrow column; the sheet gets the full pane
 * width; everything else falls back to the `MetaCard` summary so a click is
 * never a dead end. The `GenericDoc` is cast to the concrete shape at each
 * dispatch boundary — the only place a narrowing cast is warranted.
 */
function renderBody(
  doc: import("@/lib/get-document").GenericDoc,
  type: string,
) {
  switch (type) {
    case "post":
      return (
        <div className="mx-auto w-full max-w-2xl px-6 py-10">
          <PostArticle post={doc as PostDocument} error={null} embedded />
        </div>
      );
    case "paper":
      return (
        <article className="mx-auto flex w-full max-w-2xl flex-col gap-4 px-6 py-10">
          <PortableDoc blocks={paperBlocks(doc as PaperDocument)} />
        </article>
      );
    case "sheet":
      return (
        <div className="w-full px-4 py-6">
          <SheetGrid tabs={(doc.tabs as SheetTab[]) ?? []} />
        </div>
      );
    default:
      // page / author / category / project / anything unknown.
      return <MetaCard doc={doc} type={type} />;
  }
}

/**
 * Server component for the detail pane: fetch `(type, slug)` through the cached
 * `getDocument`, then render a scrollable container that is a full-screen
 * overlay on mobile and a normal in-place pane on desktop. The empty-state
 * default can therefore stay visible on desktop while an open doc covers the
 * viewport on mobile.
 *
 * Errors render an inline panel; a missing doc renders a graceful "not found"
 * panel here as a guard, but the page-level `notFound()` is the real 404 path.
 */
export async function DocumentDetail({
  type,
  slug,
}: {
  type: string;
  slug: string;
}) {
  const { doc, error } = await getDocument(type, slug);

  // Scroll container: fixed full-screen overlay on mobile, static pane on md+.
  const shell =
    "fixed inset-0 z-20 overflow-y-auto bg-white md:static md:z-auto dark:bg-zinc-950";

  if (error) {
    return (
      <div className={shell}>
        <DetailChrome title="Failed to load" type={type} />
        <div className="mx-auto w-full max-w-2xl px-6 py-10">
          <section className="rounded-lg border border-red-200 bg-red-50 p-4 text-sm text-red-900 dark:border-red-900/60 dark:bg-red-950/40 dark:text-red-200">
            <strong className="font-medium">Failed to load document.</strong>
            <pre className="mt-2 whitespace-pre-wrap text-xs">{error}</pre>
          </section>
        </div>
      </div>
    );
  }

  if (!doc) {
    // The page-level notFound() handles the real 404; this is a safety net so
    // the pane never renders blank if a caller skips that guard.
    return (
      <div className={shell}>
        <DetailChrome title="Not found" type={type} />
        <div className="mx-auto w-full max-w-2xl px-6 py-10">
          <section className="rounded-lg border border-zinc-200 bg-zinc-50 p-4 text-sm text-zinc-600 dark:border-zinc-800 dark:bg-zinc-900 dark:text-zinc-300">
            No <span className="font-medium">{type}</span> document matches{" "}
            <code className="rounded bg-zinc-200 px-1.5 py-0.5 font-mono text-[0.85em] dark:bg-zinc-800">
              {slug}
            </code>
            .
          </section>
        </div>
      </div>
    );
  }

  return (
    <div className={shell}>
      {/* No `standaloneHref`: /d/[type]/[slug] IS the canonical reader now —
          the old flat /posts/:slug & /papers/:slug only 308-redirect back here,
          so offering an "open standalone" link would just loop. */}
      <DetailChrome title={doc.title ?? slug} type={type} />
      {renderBody(doc, type)}
    </div>
  );
}
