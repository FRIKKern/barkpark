import { getDocument, type GenericDoc } from "@/lib/get-document";
// The CANONICAL PortableDocument renderer — Barkpark's own type-keyed block
// grammar, emitting the exact `bp-*` classes Phoenix's Walk emits at
// `style=:article`, so this template's reader is pixel-identical to the Phoenix
// `/papers` reader and the Go TUI (charter D4). We consume it from the PUBLISHED
// `@barkpark/react` package and NEVER vendor `web/components/portable-doc.tsx`
// (the fork the render-path epic is deleting). This is a Server Component, so
// Next resolves the package's `react-server` export condition → the RSC-safe,
// context-free server build (no `createContext`) automatically.
import { PortableDoc } from "@barkpark/react";
// The one stylesheet that skins PortableDoc output identically across Next,
// Astro, and Phoenix. Shipped as an asset by `@barkpark/react`.
import "@barkpark/react/paper-surface.css";
import { MetaCard } from "@/components/meta-card";
import { DetailChrome } from "@/components/detail-chrome";

/** Pull the type-keyed PortableDocument block array off a document, wherever it
 * lives. Papers/rich types carry it at `blocks`; some shapes nest it under
 * `body.blocks`. Returns an empty array for a document with no prose body — the
 * caller then falls back to the summary MetaCard so a click is never a dead end. */
function docBlocks(doc: GenericDoc): unknown[] {
  if (Array.isArray(doc.blocks)) return doc.blocks;
  const body = doc.body as { blocks?: unknown } | undefined;
  if (body && Array.isArray(body.blocks)) return body.blocks;
  return [];
}

/** The server-rendered HTML body, for the ~2.5% of corpus papers that carry
 * ONLY `body_html` (the API's own Walk render of the same PortableDocument
 * grammar) and no `blocks` array. Returns null when absent/blank — blocks
 * always win when both exist (the caller checks blocks first). */
function docBodyHtml(doc: GenericDoc): string | null {
  const html = doc.body_html;
  return typeof html === "string" && html.trim().length > 0 ? html : null;
}

/**
 * Defense-in-depth pass over the trusted corpus HTML before it reaches
 * `dangerouslySetInnerHTML`. `body_html` is produced by the API's own
 * server-side renderer (`Barkpark.PortableDoc.Render` behind its
 * `HtmlSanitizer`) from the SAME published corpus the block arrays come from,
 * so this is a belt-and-braces strip of active content — script elements,
 * inline `on*` handlers, `javascript:` URLs — not a general-purpose sanitizer
 * for untrusted input.
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

/**
 * Render the body for a resolved document. A document with a PortableDocument
 * body (the seed corpus's rich type, papers, …) renders through the canonical
 * `<PortableDoc>` in a centred reading column; a blocks-less doc that carries
 * the server-rendered `body_html` renders that HTML into the SAME
 * `.bp-paper-surface` column (paper-surface.css styles bare h1/p/li/pre/code
 * descendants, so it reads with the identical paper typography); a body-less
 * type (author, category, …) falls back to the `MetaCard` summary so every
 * graph/finder click lands on real content, never a dead end.
 */
function renderBody(doc: GenericDoc, type: string) {
  const blocks = docBlocks(doc);
  if (blocks.length > 0) {
    return (
      <article className="mx-auto flex w-full max-w-2xl flex-col gap-4 px-6 py-10">
        {/* `value` is the type-keyed Block[] grammar; the cast is the single
            narrowing boundary (the API returns it untyped off the index sig). */}
        <PortableDoc value={blocks as Parameters<typeof PortableDoc>[0]["value"]} />
      </article>
    );
  }
  const bodyHtml = docBodyHtml(doc);
  if (bodyHtml) {
    return (
      <article className="mx-auto flex w-full max-w-2xl flex-col gap-4 px-6 py-10">
        <div
          className="bp-paper-surface"
          dangerouslySetInnerHTML={{ __html: sanitizeTrustedHtml(bodyHtml) }}
        />
      </article>
    );
  }
  return <MetaCard doc={doc} type={type} />;
}

/**
 * Server component for the detail pane: fetch `(type, slug)` through the cached
 * `getDocument`, then render a scrollable container that is a full-screen
 * overlay on mobile and a normal in-place pane on desktop. The empty-state
 * default can therefore stay visible on desktop while an open doc covers the
 * viewport on mobile.
 *
 * Honest states (Kinsta/Vercel bar): an upstream error renders an inline error
 * panel; a missing doc renders a graceful "not found" panel as a guard (the
 * page-level `notFound()` is the real HTTP 404 path).
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
      <DetailChrome title={doc.title ?? slug} type={type} />
      {renderBody(doc, type)}
    </div>
  );
}
