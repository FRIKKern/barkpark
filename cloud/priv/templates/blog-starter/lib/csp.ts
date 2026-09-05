// Content-Security-Policy for the blog-starter scaffold.
//
// This is defense-in-depth. The only HTML this app injects is the trusted
// SDK-emitter output of `renderPortableDocument` (escaped upstream, covered by
// guard #12289) — but a nonce-based CSP means that even if a future emitter
// regression, or raw server `body_html`, ever reached the DOM, an injected
// `<script>` still could not execute: it lacks the per-request nonce, and
// `script-src` does not allow `'unsafe-inline'`.
//
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
 * Build the Content-Security-Policy header value for a single request.
 *
 * `'strict-dynamic'` lets Next's own nonce-tagged bootstrap script load the
 * rest of the app's scripts, so no host allowlist is needed for first-party
 * chunks. `connect-src 'self'` is deliberate: the starter reads its CMS
 * server-side (React Server Components), so nothing browser-side opens a
 * network connection — no WebSocket, no SSE, no cross-origin fetch.
 *
 * @param nonce a fresh, per-request base64 nonce from {@link generateNonce}
 */
export function buildCspPolicy(nonce: string): string {
  return [
    "default-src 'self'",
    `script-src 'self' 'nonce-${nonce}' 'strict-dynamic'`,
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data: blob:",
    "font-src 'self'",
    "connect-src 'self'",
    "object-src 'none'",
    "base-uri 'self'",
    "frame-ancestors 'none'",
    "form-action 'self'",
  ].join('; ');
}

/**
 * Mint a fresh CSP nonce. `crypto.randomUUID()` gives 122 bits of entropy;
 * base64-encoding it produces the opaque token the CSP spec expects.
 */
export function generateNonce(): string {
  return btoa(crypto.randomUUID());
}
