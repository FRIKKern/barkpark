// Pure Content-Security-Policy helper for the website-starter marketing scaffold.
//
// The only HTML this app injects is the trusted SDK-emitter output of
// `renderPortableDocument` (the canonical, type-keyed PortableDoc renderer —
// escaped upstream, the same emitter that skins Phoenix's `/papers` reader),
// mounted via `PortableDocSurface`. This CSP is defense-in-depth on top of
// that: it clamps the object/base/frame/form vectors and blocks any inline
// `<script>` an attacker might inject, mirroring the Phoenix-side posture in
// api/lib/barkpark_web/csp.ex (a script-blocking policy that never allows
// 'unsafe-inline' for scripts). See the wave Paper
// api-read-path-security-sweep-consumer-csp-wave-2026-08-18.
//
// The policy is nonce-based: `script-src` allows only per-request-nonced inline
// scripts (Next's own hydration scripts pick up the nonce from the request
// header) plus 'strict-dynamic', and deliberately omits 'unsafe-inline' — an
// injected inline script cannot guess the per-request nonce, so it is blocked.
// That `!'unsafe-inline'` invariant is the load-bearing assertion the gate and
// the header-presence guard both check.

// ── RECORDED DECISION (2026-09-05, task-3fd656364be5400f): STAYS STANDALONE ──
//
// `@barkpark/nextjs/csp` (buildCspPolicy, generateNonce, createCspMiddleware,
// cspMatcher — PR #13407) exists precisely to end the five-way policy drift
// this file is one arm of, and the migration IS behaviour-preserving: for the
// SAME nonce the SDK's `buildCspPolicy` emits this file's policy string
// BYTE-FOR-BYTE (measured 2026-09-05 — blog-starter with no options at all,
// website-starter with exactly `{ additional: { 'img-src': ['https:'] } }`;
// both diffs EMPTY). It is NOT taken today, for two MEASURED reasons:
//
//  1. THE SUBPATH IS NOT PUBLISHED. The generated app pins
//     `@barkpark/nextjs: ^1.0.0-preview.2`, which resolves to the newest
//     release on npm — 1.0.0-preview.3, published 2026-04-27. The `./csp`
//     export landed in the repo on 2026-08-24 (22f299b9f) and NO release has
//     shipped since. Measured: `npm install` in a bare app resolves
//     1.0.0-preview.3, `import('@barkpark/nextjs')` succeeds, and
//     `import('@barkpark/nextjs/csp')` throws
//     `ERR_PACKAGE_PATH_NOT_EXPORTED: Package subpath './csp' is not defined
//     by "exports"`. The published tarball carries no `dist/csp.*` file at all.
//     Migrating today would ship a scaffold that cannot build.
//
//  2. THE COHORT GUARD READS THIS FILE'S SOURCE TEXT.
//     `web/__tests__/consumer-csp-parity.test.ts` extracts the literal
//     directive array out of the policy builder below (it locates it by NAME,
//     so this very comment must not spell that name in full) in all four
//     template copies, and asserts the whole ten-directive floor verbatim.
//     Composing the
//     policy from the SDK deletes that array, so the migration must also move
//     that guard onto the SDK module in the SAME change — a `web/`-fence edit.
//     That guard says so itself: it is what keeps the three forks honest
//     "until the templates can take an `@barkpark/*` dependency without losing
//     their copy-pasteable property".
//
// UNBLOCK, in order: publish a `@barkpark/nextjs` release carrying `./csp`;
// bump this app's `@barkpark/nextjs` dependency pin; then land the template
// migration together with the parity-guard move in one commit (both template
// roots at once — cloud/priv/templates is a generated mirror and either half
// alone reds the required Cloud gate).
//
// Until then: standalone by design — copy-pasteable, importing nothing from
// `@barkpark/*`, using only Web Crypto, which is available in both the Edge and
// the Node.js Next.js middleware runtimes.

/**
 * Build the strict Content-Security-Policy string for a single request.
 *
 * @param nonce - the per-request base64 nonce minted in middleware.ts.
 * @returns a `;`-joined policy string suitable for the
 *   `Content-Security-Policy` header.
 */
export function buildCspPolicy(nonce: string): string {
  const directives = [
    `default-src 'self'`,
    // Nonce-gated scripts only — NO 'unsafe-inline'. 'strict-dynamic' lets a
    // nonced script load its own dependencies without re-listing hosts.
    `script-src 'self' 'nonce-${nonce}' 'strict-dynamic'`,
    // Tailwind ships styles inline; allow 'unsafe-inline' for styles only
    // (styles cannot execute script, so this does not weaken the XSS backstop).
    `style-src 'self' 'unsafe-inline'`,
    // `blob:` added alongside the existing `data: https:` — mermaid/asciinema-player
    // (the new PortableDoc media deps) can render through blob URLs; `https:` stays
    // for the pre-existing `heroImage` field's hosted asset URLs.
    `img-src 'self' data: blob: https:`,
    `font-src 'self'`,
    // Marketing pages fetch CMS content server-side, so the browser makes no
    // cross-origin WS/SSE/fetch — 'self' is sufficient.
    `connect-src 'self'`,
    `object-src 'none'`,
    `base-uri 'self'`,
    `frame-ancestors 'none'`,
    `form-action 'self'`,
  ]
  return directives.join('; ')
}

/**
 * Mint a fresh base64 nonce using the Web Crypto API (available in the Next.js
 * middleware/Edge runtime and in modern Node). 16 random bytes → ~22 base64
 * chars, well above the 128-bit unguessability floor a CSP nonce needs.
 */
export function generateNonce(): string {
  const bytes = new Uint8Array(16)
  crypto.getRandomValues(bytes)
  let binary = ''
  for (const b of bytes) binary += String.fromCharCode(b)
  return btoa(binary)
}
