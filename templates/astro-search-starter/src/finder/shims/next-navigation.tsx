// Vite-alias shim for `next/navigation` (charter D41/D42) — the vendored finder
// (copied VERBATIM from templates/search-starter) drives all of its state
// through the URL via `useRouter().replace(...)`, `usePathname()` and
// `useSearchParams()`. On the STATIC Astro target there is no Next router, so
// `astro.config.mjs` aliases `next/navigation` here to a tiny store backed by
// the real browser primitives: `window.location` + `history.pushState/
// replaceState` + the `popstate` event.
//
// The finder writes query state with `router.replace(pathname?query)` on every
// keystroke and opens a document with `router.push(href)`. `history.*State`
// does NOT emit `popstate`, so we fire a synthetic `bp:locationchange` event on
// every programmatic navigation; `usePathname`/`useSearchParams` subscribe to
// BOTH events via `useSyncExternalStore`, so the finder re-renders in lock-step
// with the URL exactly as it did under Next.
import { useCallback, useMemo, useSyncExternalStore } from 'react'
import { withBase } from './next-link'

const LOCATION_EVENT = 'bp:locationchange'

function emit(): void {
  if (typeof window !== 'undefined') window.dispatchEvent(new Event(LOCATION_EVENT))
}

function subscribe(onChange: () => void): () => void {
  if (typeof window === 'undefined') return () => {}
  window.addEventListener('popstate', onChange)
  window.addEventListener(LOCATION_EVENT, onChange)
  return () => {
    window.removeEventListener('popstate', onChange)
    window.removeEventListener(LOCATION_EVENT, onChange)
  }
}

/** The site base, same derivation as `withBase` in the next-link shim. */
const BASE = (import.meta.env.BASE_URL || '/').replace(/\/+$/, '') // '' | '/sites/slug'

/**
 * Strip the site base and any trailing slash, so this returns the path in the
 * SAME vocabulary the finder itself speaks: root-absolute, unprefixed, no
 * trailing slash — e.g. `/d/paper/my-slug`, never `/sites/x/d/paper/my-slug/`.
 *
 * This is what makes the open row highlight. finder.tsx (byte-locked to the
 * Next edition, so the fix has to live here) marks a row selected with
 * `pathname === hit.href || pathname === '/d/<type>/<slug>'`, and `hit.href` is
 * the raw unprefixed `/d/<type>/<slug>` — while a deployed static site serves
 * `/sites/<slug>/d/<type>/<name>/`, base-prefixed AND directory-slashed. Those
 * never compared equal, so on the Astro edition no result row ever showed as
 * open. Normalising here restores the symmetry the shim already keeps
 * everywhere else: the finder thinks in unprefixed app paths, and the shim adds
 * the base at each boundary (`<Link>`, `router.push`, `router.replace`).
 */
export function normalizePathname(raw: string): string {
  let path = raw || '/'
  if (BASE && (path === BASE || path.startsWith(BASE + '/'))) path = path.slice(BASE.length) || '/'
  if (path.length > 1) path = path.replace(/\/+$/, '') || '/'
  return path
}

const getPathname = (): string =>
  typeof window === 'undefined' ? '/' : normalizePathname(window.location.pathname)
const getSearch = (): string =>
  typeof window === 'undefined' ? '' : window.location.search

/** Current pathname — reactive to back/forward and programmatic navigation. */
export function usePathname(): string {
  return useSyncExternalStore(subscribe, getPathname, () => '/')
}

/** Read-only URLSearchParams over the live URL — stable identity per query
 * string so the finder's `useMemo`/effect deps only fire on a real change. */
export function useSearchParams(): URLSearchParams {
  const search = useSyncExternalStore(subscribe, getSearch, () => '')
  return useMemo(() => new URLSearchParams(search), [search])
}

export interface Router {
  push: (href: string) => void
  replace: (href: string, opts?: { scroll?: boolean }) => void
  prefetch: (href?: string) => void
  back: () => void
  forward: () => void
  refresh: () => void
}

/** Minimal App-Router surface over History. `push` opens a new URL (base-
 * prefixed like <Link>, since the finder passes root-absolute doc hrefs);
 * `replace` rewrites query on the CURRENT (already-based) path in place. */
export function useRouter(): Router {
  const push = useCallback((href: string) => {
    if (typeof window === 'undefined') return
    window.history.pushState(null, '', withBase(href))
    emit()
  }, [])
  const replace = useCallback((href: string, _opts?: { scroll?: boolean }) => {
    if (typeof window === 'undefined') return
    // MUST base-prefix exactly like `push`: the finder calls this as
    // `replace(`${pathname}?${qs}`)` with the pathname `usePathname()` handed
    // it, and that value is now the DE-BASED app path (see normalizePathname).
    // Without withBase here, the first keystroke would rewrite the URL to a
    // base-less path and every subsequent relative asset/route read would miss.
    window.history.replaceState(null, '', withBase(href))
    emit()
  }, [])
  const prefetch = useCallback(() => {}, [])
  const back = useCallback(() => {
    if (typeof window !== 'undefined') window.history.back()
  }, [])
  const forward = useCallback(() => {
    if (typeof window !== 'undefined') window.history.forward()
  }, [])
  const refresh = useCallback(() => {}, [])
  return { push, replace, prefetch, back, forward, refresh }
}
