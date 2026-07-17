// Vite-alias shim for `next/link` (charter D46) — the vendored finder is copied
// VERBATIM from templates/search-starter and still imports `next/link`; on the
// STATIC Astro target there is no Next runtime, so `astro.config.mjs` aliases
// `next/link` to this file. It is a plain forward-ref `<a>` that reproduces the
// two Next behaviours the finder relies on:
//
//   1. basePath prefixing — under sub-path hosting (`/sites/<slug>/`) every
//      root-absolute href must carry the site base. Astro bakes the base into
//      `import.meta.env.BASE_URL`; we prepend it (idempotently — a href that
//      already starts with the base is left alone).
//   2. trailing slash — Astro's static output writes `/d/<type>/<slug>/index.html`,
//      so a directory URL needs the trailing slash to resolve without a redirect.
//
// Next-only props (`prefetch`, `replace`, `scroll`) are accepted and dropped so
// the vendored call sites type-check and render; everything else (onClick,
// className, aria-*, onMouseEnter…) passes straight through to the anchor.
import { forwardRef } from 'react'
import type { AnchorHTMLAttributes, ReactNode } from 'react'

/** The site base Astro baked from BARKPARK_SITE_BASE — '/' at the domain root. */
const BASE = (import.meta.env.BASE_URL || '/').replace(/\/+$/, '') // '' | '/sites/slug'

/** Prefix a root-absolute href with the site base + a trailing slash (before any
 * query/hash), idempotently. Non-absolute / hash-only hrefs pass through. */
export function withBase(href: string): string {
  if (!href || href[0] !== '/') return href
  const hashIdx = href.search(/[?#]/)
  let path = hashIdx === -1 ? href : href.slice(0, hashIdx)
  const rest = hashIdx === -1 ? '' : href.slice(hashIdx)
  if (BASE && path !== BASE && !path.startsWith(BASE + '/')) path = BASE + path
  if (!path.endsWith('/')) path += '/'
  return path + rest
}

type NextLinkProps = AnchorHTMLAttributes<HTMLAnchorElement> & {
  href: string
  children?: ReactNode
  // Next-only props — accepted, ignored on the static target.
  prefetch?: boolean
  replace?: boolean
  scroll?: boolean
}

const Link = forwardRef<HTMLAnchorElement, NextLinkProps>(function Link(
  { href, prefetch: _p, replace: _r, scroll: _s, children, ...rest },
  ref,
) {
  return (
    <a ref={ref} href={withBase(href)} {...rest}>
      {children}
    </a>
  )
})

export default Link
