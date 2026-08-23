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
