// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
//
// Per-request-nonce Content-Security-Policy for a Barkpark consumer app.
//
// ## Why this lives in the SDK
//
// Wave 5 shipped this as a STANDALONE `lib/csp.ts` + `middleware.ts` pair per
// template — a copy-pasteable teaching artifact with zero cross-package
// coupling. Five copies later the policies had measurably DRIFTED:
//
//   | copy                        | img-src                   | connect-src        | nonce source          |
//   |-----------------------------|---------------------------|--------------------|-----------------------|
//   | blog-starter                | 'self' data: blob:        | 'self'             | btoa(randomUUID())    |
//   | website-starter             | 'self' data: blob: https: | 'self'             | 16B getRandomValues   |
//   | web/ (Next 16 `proxy.ts`)   | 'self' data: blob:        | 'self' + WS origin | btoa(randomUUID())    |
//
// Every divergence is a legitimate per-app need (a hosted hero image, a direct
// live-search WebSocket) riding on a hand-forked policy body. This module keeps
// ONE policy body and turns the three variance points into typed options, so a
// consumer widens `img-src` without also inheriting whatever else that fork
// happened to say.
//
// ## The security floor is not configurable
//
// `default-src`, `object-src`, `base-uri`, `frame-ancestors` and `form-action`
// are fixed — enforced at RUNTIME against `EXTENDABLE_DIRECTIVES`, since the
// `additional` TYPE never closed the door (a `Record<string, readonly
// string[]>` assembled from config is assignable to it with no error, and the
// package is consumable from plain JS besides). Naming a floor directive in
// `additional` THROWS. `script-src` accepts additions but REJECTS `'unsafe-inline'` and
// `'unsafe-eval'`: the whole point of the nonce is that an injected inline
// script cannot execute, and a policy that re-admits `'unsafe-inline'` is
// decoration. Conformant browsers also ignore `'unsafe-inline'` alongside a
// nonce — so a caller who passes it gets a policy that is *either* a silent
// no-op or a real hole depending on the browser. Throwing is the honest answer.
//
// ## Edge-safe
//
// Web Crypto + `next/server` only — no `node:` imports (see
// js/scripts/check-no-node-imports.sh, which gates this directory).

import { NextResponse, type NextRequest } from 'next/server'

/**
 * The directives a consumer may WIDEN. Everything absent from this union is
 * part of the fixed security floor and cannot be reached from options — an
 * invariant {@link EXTENDABLE_DIRECTIVES} enforces at RUNTIME, because the type
 * alone never did (see that constant's note).
 */
export type ExtendableDirective =
  | 'script-src'
  | 'style-src'
  | 'img-src'
  | 'font-src'
  | 'connect-src'
  | 'frame-src'
  | 'media-src'
  | 'worker-src'

/**
 * The runtime twin of {@link ExtendableDirective} — the allow-list
 * `buildCspPolicy` actually consults.
 *
 * The type could not carry this on its own. `additional` is typed
 * `Partial<Record<ExtendableDirective, readonly string[]>>`, and TypeScript's
 * excess-property check only fires on a fresh object literal: a variable of
 * type `Record<string, readonly string[]>` — the realistic shape when a
 * consumer assembles its policy map from config or env — is assignable with no
 * error. The package also ships CJS/ESM consumable from plain JS, where no
 * type exists at all. Before this list, `buildCspPolicy` read
 * `extra[name as ExtendableDirective]` for EVERY base directive, so
 * `object-src`, `frame-ancestors`, `base-uri`, `form-action` and `default-src`
 * — the five the module header calls fixed — were all reachable from options.
 */
const EXTENDABLE_DIRECTIVES: readonly ExtendableDirective[] = [
  'script-src',
  'style-src',
  'img-src',
  'font-src',
  'connect-src',
  'frame-src',
  'media-src',
  'worker-src',
]

function isExtendable(name: string): name is ExtendableDirective {
  return (EXTENDABLE_DIRECTIVES as readonly string[]).includes(name)
}

/** Sources that make a nonce-based `script-src` meaningless. */
const FORBIDDEN_SCRIPT_SOURCES = ["'unsafe-inline'", "'unsafe-eval'"] as const

export interface CspOptions {
  /**
   * Extra sources appended to a directive, e.g.
   * `{ 'img-src': ['https:'], 'connect-src': ['wss://api.example.com'] }`.
   *
   * Appended AFTER the built-in sources and de-duplicated, so passing a source
   * the base policy already carries is a no-op rather than a repeated token.
   */
  additional?: Partial<Record<ExtendableDirective, readonly string[]>>
  /**
   * Emit `report-uri`/`report-to` reporting endpoints. Reporting alone never
   * relaxes the policy.
   */
  reportUri?: string
}

/**
 * The base policy, before per-app additions. Nonce-gated scripts only:
 * `'strict-dynamic'` lets Next's own nonced bootstrap load the app's chunks
 * without a host allow-list, and `style-src 'unsafe-inline'` is kept because
 * Tailwind/Next emit inline `style=` attributes a nonce cannot cover (styles
 * cannot execute script, so this does not weaken the XSS backstop).
 */
function baseDirectives(nonce: string): Array<[string, string[]]> {
  return [
    ['default-src', ["'self'"]],
    ['script-src', ["'self'", `'nonce-${nonce}'`, "'strict-dynamic'"]],
    ['style-src', ["'self'", "'unsafe-inline'"]],
    ['img-src', ["'self'", 'data:', 'blob:']],
    ['font-src', ["'self'"]],
    ['connect-src', ["'self'"]],
    ['object-src', ["'none'"]],
    ['base-uri', ["'self'"]],
    ['frame-ancestors', ["'none'"]],
    ['form-action', ["'self'"]],
  ]
}

/**
 * Build the Content-Security-Policy header value for a single request.
 *
 * Pure — no I/O, no globals — so the policy shape is unit-testable in isolation
 * from the edge runtime. {@link createCspMiddleware} mints the nonce and
 * applies the result.
 *
 * @param nonce - the per-request nonce from {@link generateNonce}.
 * @throws if `additional['script-src']` contains `'unsafe-inline'` or
 *   `'unsafe-eval'` — see the module note on why this is a throw, not a warn.
 */
export function buildCspPolicy(nonce: string, options: CspOptions = {}): string {
  const extra = options.additional ?? {}

  // Enforce the allow-list BEFORE any directive is built, so a floor key can
  // never be merged. Throwing (rather than dropping) matches the module's
  // posture for `'unsafe-inline'` below: a caller who believes they widened
  // `object-src` and silently did not is worse off than one who is told.
  for (const name of Object.keys(extra)) {
    if (!isExtendable(name)) {
      // Message kept terse on purpose: `dist/csp.mjs` sits under a 1 kB
      // size-limit cap (js/CLAUDE.md "Bundle budget"), and the extendable list
      // is reused from the constant rather than re-spelled.
      throw new Error(
        `buildCspPolicy: "${name}" is in the fixed security floor. ` +
          `Extendable: ${EXTENDABLE_DIRECTIVES.join(' ')}`,
      )
    }
  }

  const scriptExtras = extra['script-src'] ?? []
  for (const src of scriptExtras) {
    if ((FORBIDDEN_SCRIPT_SOURCES as readonly string[]).includes(src.trim())) {
      throw new Error(
        `buildCspPolicy: refusing to add ${src} to script-src — it defeats the ` +
          `per-request nonce this policy exists for. Ship the inline script with ` +
          `nonce={nonce} instead, or hash it.`,
      )
    }
  }

  const directives = baseDirectives(nonce).map(([name, sources]) => {
    // `isExtendable` rather than a cast: `name` walks the FULL base list, floor
    // directives included, so a cast here reads `extra['object-src']` whenever
    // one is present. The guard above already refuses such a key — this keeps
    // the invariant readable where it matters instead of depending on a check
    // twenty lines up.
    const additions = (isExtendable(name) ? extra[name] : undefined) ?? []
    const merged = [...sources]
    for (const src of additions) {
      if (!merged.includes(src)) merged.push(src)
    }
    return `${name} ${merged.join(' ')}`
  })

  // A directive a consumer widens but the base policy never named (e.g.
  // `worker-src`) still needs to exist, or the addition silently falls through
  // to `default-src`.
  for (const [name, additions] of Object.entries(extra)) {
    if (!additions || additions.length === 0) continue
    if (directives.some((d) => d.startsWith(`${name} `))) continue
    directives.push(`${name} ${["'self'", ...additions].join(' ')}`)
  }

  if (options.reportUri) directives.push(`report-uri ${options.reportUri}`)

  return directives.join('; ')
}

/**
 * Mint a fresh, unguessable per-request nonce. 16 random bytes (128 bits) is
 * the unguessability floor the CSP spec asks for; base64 makes it a compact
 * CSP-token-safe string. Uses Web Crypto, present in both the Edge and the
 * Node.js Next.js middleware runtimes.
 */
export function generateNonce(): string {
  const bytes = new Uint8Array(16)
  crypto.getRandomValues(bytes)
  let binary = ''
  for (const b of bytes) binary += String.fromCharCode(b)
  return btoa(binary)
}

/**
 * The `config.matcher` a CSP middleware should ship with: every route EXCEPT
 * static assets, the image optimizer, the favicon and API routes — none of
 * which render app HTML that could host an injected inline script.
 *
 * The `missing` clause skips PREFETCH/RSC requests: they reuse the page's
 * already-nonced payload, and stamping a fresh (different) nonce on the
 * prefetch would mismatch the enforced document.
 */
export const cspMatcher = [
  {
    source: '/((?!_next/static|_next/image|favicon.ico|api).*)',
    missing: [
      { type: 'header', key: 'next-router-prefetch' },
      { type: 'header', key: 'purpose', value: 'prefetch' },
    ],
  },
] as const

/**
 * Build the Next middleware (Next 15 `middleware.ts`) / proxy (Next 16
 * `proxy.ts`) request handler. The two file conventions differ only in the
 * exported symbol NAME — the handler body is identical, which is why this
 * factory serves both:
 *
 * ```ts
 * // middleware.ts (Next 15)      |  // proxy.ts (Next 16)
 * import { createCspMiddleware, cspMatcher } from '@barkpark/nextjs/csp'
 * export const middleware = createCspMiddleware()   // export const proxy = …
 * export const config = { matcher: cspMatcher }
 * ```
 *
 * ## The load-bearing two-header pattern (do NOT simplify to one)
 *
 * The nonce is stamped in two places because two consumers read it from
 * different sources:
 *
 *   1. the FORWARDED REQUEST headers — Next's App-Router renderer reads
 *      `content-security-policy` off the incoming request, extracts the nonce
 *      and stamps its OWN inline bootstrap scripts (`__next_f.push`) with it.
 *      Without this the framework scripts carry no nonce, the enforcing
 *      `script-src` blocks them, and hydration dies into a static shell.
 *      `x-nonce` is forwarded too so a root layout can read it via
 *      `next/headers` and nonce its own inline `<script>`;
 *   2. the RESPONSE headers — the copy the BROWSER enforces. It must carry the
 *      SAME nonce as (1) so the browser trusts the scripts Next nonced.
 *
 * Because the nonce arrives on a request header rather than through
 * `headers()` in the layout, routes stay static-eligible: this flips ZERO
 * routes static→dynamic.
 *
 * ## Ejecting
 *
 * This factory is ~20 lines with no Barkpark-specific state. To take it over,
 * inline the body into your own `middleware.ts` and keep calling
 * {@link buildCspPolicy} — or copy that too. Nothing here is load-bearing for
 * the rest of `@barkpark/nextjs`.
 */
export function createCspMiddleware(
  options: CspOptions = {},
): (request: NextRequest) => NextResponse {
  return function cspMiddleware(request: NextRequest): NextResponse {
    const nonce = generateNonce()
    const policy = buildCspPolicy(nonce, options)

    const requestHeaders = new Headers(request.headers)
    requestHeaders.set('x-nonce', nonce)
    requestHeaders.set('content-security-policy', policy)

    const response = NextResponse.next({ request: { headers: requestHeaders } })
    response.headers.set('content-security-policy', policy)

    return response
  }
}
