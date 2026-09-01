<!-- doc-tier: human | canonical-for: react-package | budget: 320tok -->
# @barkpark/react

Framework-free renderers for Barkpark content. **Zero `next/*` imports** — use from any React 19 host.

```bash
npm install @barkpark/react
```

## Published preview advisory

**Every version of this package that exists on npm resolves a failed reference
fetch as "this document does not exist."** The repair is on `main` (#9601) and
is not in any release yet. Measured from the artifact itself —
`npm pack @barkpark/react@1.0.0-preview.1`, then `package/dist/index.mjs`
(unminified, lines 25–29):

```js
      try {
        return await fetchRaw(`/v1/data/doc/production/${id}`);
      } catch {
        return null;
      }
```

Eleven lines later the same shipped file renders that `null` as the miss:
`if (doc == null) return createElement(Fragment, null, notFound)`. So a 401, a
429 and a 500 are all indistinguishable from a genuine 404. `dist/index.cjs`
carries the same code, and `1.0.0-preview.0` ships a byte-identical
`src/Reference.tsx` (6094 B, sha1 `b7ba6f1d…`) — **no published version is free
of it**, and `1.0.0-preview.2` is where the fix lands.

Until then, pass your own `fetcher` prop and decide there what a non-404 failure
should render; the fetcher derived from `client={bp}` cannot tell you. Disposition
and remediation mechanism: `docs/ops/npm-rollback-playbook.md` § Mechanism A.

## PortableText

Renders block content to React elements, with per-type component overrides. Newlines in a span become `<br/>` (configurable via `components.hardBreak`, or `false` to disable). Unknown styles/marks/types fall back to sensible HTML or your `unknown*` components.

```tsx
import { PortableText } from '@barkpark/react'

<PortableText
  value={post.body}
  components={{
    mark: { link: ({ value, children }) => <a href={value.href}>{children}</a> },
    types: { image: ({ value }) => <img src={value.url} alt="" /> },
  }}
/>
```

> **Security:** a mark's URL (`value.href`) is untrusted CMS content. Sanitize it before putting it in an `href` — reject `javascript:`/`data:`/`vbscript:` schemes — or an editor can inject a script URL. The renderer forwards mark values verbatim; scheme filtering is the consumer's responsibility (as in the reference ecosystem).

## toPlainText

Flatten Portable Text to a plain string — for excerpts, search indexing, and meta descriptions. Server-safe (no React).

```tsx
import { toPlainText } from '@barkpark/react'

export function generateMetadata({ post }) {
  return { description: toPlainText(post.body).slice(0, 160) }
}
```

## BarkparkImage

Renders an image asset as an `<img>`, or any component via `as` (e.g. `next/image`). Pulls `width`/`height` from asset metadata and forwards `lqip` as `blurDataURL` to custom components. The `preset` prop requests a server rendition (`thumb`/`preview`/`hero`/`og`); with `baseUrl` it builds an absolute URL, without one a relative `/media/renditions/<id>/<preset>` path (valid same-origin). Omit it for the original.

```tsx
import { BarkparkImage, imageUrl } from '@barkpark/react' // imageUrl re-exported from core
import NextImage from 'next/image'

<BarkparkImage asset={post.cover} alt={post.title} preset="hero" baseUrl="https://cdn.example.com" as={NextImage} placeholder="blur" />
```

## BarkparkReference

Resolves a reference and hands the document to a render prop, under `<Suspense>`, with cycle detection and a `maxDepth` cap (default 5).

```tsx
import { BarkparkReference } from '@barkpark/react'

<BarkparkReference ref={post.author} client={bp} fallback={<Spinner />} notFound={<span>—</span>}>
  {(author) => <a href={`/authors/${author._id}`}>{author.name}</a>}
</BarkparkReference>
```

PortableText and BarkparkImage are server-component friendly (exported under the `react-server` condition). BarkparkReference uses client-only React APIs (`createContext`, `useContext`) and must be imported from a `'use client'` component — pair with `@barkpark/nextjs` for App Router integration.

## Hydrating media & tabs (`@barkpark/react/client`)

`PortableDoc`/`renderPortableDocument` (see below) emit two block families as **inert, server-rendered mount points** — a Mermaid `<pre>` with the raw diagram source, an asciicast `<div>` with a poster-frame attribute, and tab strips with every panel visible — so the page is complete and readable with zero client JS. `hydratePortableDoc(root)` from `@barkpark/react/client` is the one framework-free, lazy, idempotent hook that turns those into live diagrams/players/tab strips. It has no React dependency — call it from a Next `useEffect`, an Astro `<script>`, or anywhere else the mount points are live.

**Server/client boundary:** `renderPortableDocument`/`<PortableDoc>` are pure string/RSC-safe — no ref, no client API, safe in a Server Component. Hydration needs a DOM `ref` (or `document.getElementById`), which is client-only, so it is the *only* piece that needs a client boundary. Keep that boundary as small as the two recipes below — everything else (data fetching, layout) stays server work.

**Next.js** (mirrors the shipped `create-barkpark-app` blog-starter's `app/posts/[slug]/portable-doc-surface.tsx`, type-checked against these exact exports in [`tests/docs-examples/nextjs-hydration-recipe.tsx`](tests/docs-examples/nextjs-hydration-recipe.tsx)):

```tsx
'use client'
import { useEffect, useRef } from 'react'
import { renderPortableDocument, type Block } from '@barkpark/react'
import { hydratePortableDoc } from '@barkpark/react/client'

export function PortableDocSurface({ blocks, className }: { blocks: Block[]; className?: string }) {
  const ref = useRef<HTMLDivElement>(null)
  useEffect(() => {
    if (ref.current) void hydratePortableDoc(ref.current).catch(() => {})
  }, [blocks]) // re-hydrate only when the content itself changes
  const cls = className ? `bp-paper-surface ${className}` : 'bp-paper-surface'
  return <div ref={ref} className={cls} dangerouslySetInnerHTML={{ __html: renderPortableDocument(blocks) }} />
}
// app/posts/[slug]/page.tsx (a Server Component): const blocks = await fetchBlocks()
// return <PortableDocSurface blocks={blocks} />
```

**Astro** (a plain `<script>` island — no framework, no hydration directive; type-checked in [`tests/docs-examples/astro-hydration-recipe.ts`](tests/docs-examples/astro-hydration-recipe.ts)):

```astro
---
import { renderPortableDocument } from '@barkpark/react/portable-doc'
const surfaceHtml = renderPortableDocument(post.content)
---
<div id="post-surface" class="bp-paper-surface" set:html={surfaceHtml} />
<script>
  import { hydratePortableDoc } from '@barkpark/react/client'
  const root = document.getElementById('post-surface')
  if (root) void hydratePortableDoc(root).catch(() => {})
</script>
```

**Avoiding double hydration:** `hydratePortableDoc` stamps every mount point it touches (`data-processed`/`data-asciicast-done`/`data-hydrated`), so a repeat call — React Strict Mode's dev double-invoke, an Astro View Transitions re-run, a parent re-render — is a no-op on already-hydrated nodes.

**Error behavior:** `.catch(() => {})` is deliberate, not an oversight — the pre-hydration server markup is already valid, readable content, so a failed dynamic `import('mermaid')`/`import('asciinema-player')` (offline, CDN hiccup, ad-blocker) must degrade to that markup, never to a broken page.

**Cleanup:** none needed. Hydration only mutates the DOM subtree it scans; it registers no listener, timer, or subscription outside it, so there is nothing to unregister on unmount — removing the node removes everything hydration attached.

**CSP:** `mermaid` needs `'unsafe-eval'` in `script-src` (its layout engine evaluates generated code; this is documented by Mermaid itself, not specific to this integration) — there is no CSP-compatible mode that avoids it today. Both `mermaid` and `asciinema-player` here are loaded via `import()` — bundled by your app's own bundler (self-hosted, same-origin), the same posture as the rest of your first-party JS — so no extra `script-src` **host** allowlisting is needed. That only changes if you swap either library for a `<script src="https://cdn.jsdelivr.net/...">` tag instead of the npm package: then `script-src` also needs that CDN host.

## Subpath exports (tree-shaking) & compatibility policy

The two rendering surfaces ship as dedicated subpaths so an app that uses one
never pays for the other:

```ts
import { PortableText } from '@barkpark/react/portable-text' // legacy Sanity-shaped shim (~1.3 KB gz)
import { PortableDoc, renderPortableDocument } from '@barkpark/react/portable-doc' // canonical renderer, shim-free
```

**Compatibility policy:** the root barrel (`@barkpark/react`) keeps exporting
BOTH surfaces, unchanged, indefinitely — existing imports never break and never
need migrating. The subpaths are additive opt-in. (Since the entry split, even
the root-barrel `import { PortableText }` tree-shakes free of the renderer
chunk in bundlers that honor ESM tree-shaking; the subpaths make the boundary
explicit and are the guaranteed form.) `@barkpark/react/portable-doc` is
hook-free and safe in React Server Components; `@barkpark/react/portable-text`
is a client component. Guarded by `tests/portable-subpath-split.test.ts` and
the `.size-limit.json` budgets.
