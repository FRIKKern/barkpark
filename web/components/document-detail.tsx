import { getDocument } from "@/lib/get-document";
import { client } from "@/lib/barkpark-client";
import {
  paperBlocks,
  resolveValuerefsInBlocks,
  type PaperDocument,
} from "@/lib/papers";
import type { PostDocument } from "@/lib/posts";
import { PostArticle } from "@/components/post-article";
import { PortableDoc } from "@barkpark/react";
import { PaperEditorDoc } from "@/components/paper-editor-doc";
import { SheetGrid, type SheetTab } from "@/components/sheet-grid";
import { MetaCard } from "@/components/meta-card";
import { DetailChrome } from "@/components/detail-chrome";
import { RelatedPapers } from "@/components/related-papers";

/** The server-rendered HTML body, for the ~2.5% of corpus papers that carry
 * ONLY `body_html` (the API's own Walk render of the same PortableDocument
 * grammar) and no `blocks` array. Returns null when absent/blank — blocks
 * always win when both exist (the caller checks blocks first). */
function docBodyHtml(doc: import("@/lib/get-document").GenericDoc): string | null {
  const html = doc.body_html;
  return typeof html === "string" && html.trim().length > 0 ? html : null;
}

/**
 * A COSMETIC pass over the corpus HTML before it reaches
 * `dangerouslySetInnerHTML`. It is NOT a sanitizer and NOT the security
 * boundary on this surface, despite what this comment used to say.
 *
 * `body_html` is produced by the API's own server-side renderer
 * (`Barkpark.PortableDoc.Render` behind its `HtmlSanitizer`) from the SAME
 * published corpus the block arrays come from, so the input arrives already
 * server-sanitized. What is left here is a regex pass, and a regex cannot
 * parse HTML. It removes well-formed script elements and the common
 * whitespace-separated handler attribute, and it is stepped around by an
 * attribute separated with `/` (`<img/onerror=alert(1) src=x>`,
 * `<svg/onload=alert(1)>`), by an entity-encoded scheme
 * (`<a href="jav&#x61;script:…">`), and by `<iframe srcdoc="…">`. Those
 * bypasses are measured, and pinned as behaviour, in
 * `__tests__/sanitize-trusted-html.test.ts`.
 *
 * So: the CSP in `lib/csp.ts` is the control. An enforcing `script-src` with
 * no `'unsafe-inline'` and no `'unsafe-eval'`, `object-src 'none'`, and a
 * per-request 128-bit nonce is what actually stops an injected inline handler
 * or a script-scheme URL from executing in the browser. Keep this filter for
 * the belt-and-braces value it genuinely has; do NOT restore a claim here that
 * the runtime does not deliver. The previous wording promised handler and URL
 * stripping this function never performed — and a comment claiming a defence
 * that is not there is precisely why nobody adds the real one.
 */
function sanitizeTrustedHtml(html: string): string {
  return html
    .replace(/<script\b[^>]*>[\s\S]*?<\/script\s*>/gi, "")
    .replace(/<script\b[^>]*\/?>/gi, "")
    .replace(/\son[a-z]+\s*=\s*"[^"]*"/gi, "")
    .replace(/\son[a-z]+\s*=\s*'[^']*'/gi, "")
    .replace(/\son[a-z]+\s*=\s*[^\s>]+/gi, "")
    .replace(/(href|src)\s*=\s*(["']?)\s*javascript:[^"'\s>]*\2/gi, '$1="#"');
}

/** `body_html` rendered into the SAME `.bp-paper-surface` column PortableDoc
 * uses — paper-surface.css styles bare h1/p/li/pre/code descendants, so the
 * HTML twin reads with the identical paper typography. */
function HtmlSurface({ html }: { html: string }) {
  return (
    <article className="mx-auto flex w-full max-w-2xl flex-col gap-4 px-6 py-10">
      <div
        className="bp-paper-surface"
        dangerouslySetInnerHTML={{ __html: sanitizeTrustedHtml(html) }}
      />
    </article>
  );
}

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
    case "paper": {
      // Flag-gated read-mode editor embed. OFF (default) keeps the server
      // PortableDoc — zero client-editor bundle cost, no SSR/demo regression.
      // ON swaps in PaperEditorDoc, which mounts one read-only <bp-paper-editor>
      // per top-level prose block and server-renders the rest.
      const paperReadMode = process.env.NEXT_PUBLIC_PAPER_EDITOR === "read";
      const blocks = paperBlocks(doc as PaperDocument);
      // Related-papers read: link by the source's own slug (its `doc_id`),
      // falling back to the uuid only if a slug is somehow absent. Rendered
      // below the article as an async Server Component; empty related shows
      // nothing (RelatedPapers returns null).
      const relatedId =
        typeof doc.slug === "string" && doc.slug ? doc.slug : doc._id;
      // ~2.5% of corpus papers carry ONLY body_html (no blocks) — render the
      // server-rendered HTML twin into the same paper surface instead of an
      // empty article (or, worse, MetaCard escaping it as a 12KB dump).
      const bodyHtml = blocks.length === 0 ? docBodyHtml(doc) : null;
      return (
        <>
          {bodyHtml ? (
            <HtmlSurface html={bodyHtml} />
          ) : (
            <article className="mx-auto flex w-full max-w-2xl flex-col gap-4 px-6 py-10">
              {paperReadMode ? (
                <PaperEditorDoc blocks={blocks} />
              ) : (
                <PortableDoc value={blocks} />
              )}
            </article>
          )}
          <RelatedPapers docId={relatedId} />
        </>
      );
    }
    case "sheet":
      return (
        <div className="w-full px-4 py-6">
          <SheetGrid tabs={(doc.tabs as SheetTab[]) ?? []} />
        </div>
      );
    default: {
      // page / author / category / project / anything unknown. A blocks-less
      // doc carrying body_html still renders as real prose, never a MetaCard
      // fallback that would drop (or worse, escape) its body.
      const bodyHtml = docBodyHtml(doc);
      if (bodyHtml) return <HtmlSurface html={bodyHtml} />;
      return <MetaCard doc={doc} type={type} />;
    }
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
  const { doc: fetched, error } = await getDocument(type, slug);

  // Inline live values (lvw-t1): pre-resolve every valueref SERVER-side and
  // stamp `resolved` onto the nodes before render, so the reader component
  // stays dumb (wire §5's recommended default). Published perspective only
  // (the public client); best-effort — any failure leaves the blocks
  // untouched and each valueref shows its pinned fallback. Freshness rides
  // the pane's existing ISR + webhook tag-bust cadence.
  let doc = fetched;
  if (doc && type === "paper") {
    const blocks = await resolveValuerefsInBlocks(
      client,
      paperBlocks(doc as PaperDocument),
    );
    doc = { ...doc, blocks };
  }

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
