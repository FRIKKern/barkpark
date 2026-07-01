<!-- doc-tier: human | canonical-for: react-package | budget: 320tok -->
# @barkpark/react

Framework-free renderers for Barkpark content. **Zero `next/*` imports** — use from any React 19 host.

```bash
npm install @barkpark/react
```

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
