// Content-Security-Policy for the blog-starter scaffold.
//
// This is defense-in-depth. The only HTML this app injects is the trusted
// SDK-emitter output of `renderPortableDocument` (escaped upstream, covered by
// guard #12289) — but a nonce-based CSP means that even if a future emitter
// regression, or raw server `body_html`, ever reached the DOM, an injected
// `<script>` still could not execute: it lacks the per-request nonce, and
// `script-src` does not allow `'unsafe-inline'`.
//
// Standalone by design — the template is copy-pasteable, so this file imports
// nothing from `@barkpark/*`. It uses only Web Crypto, which is available in
// both the Edge and Node.js Next.js middleware runtimes.

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
