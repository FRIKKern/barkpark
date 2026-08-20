/**
 * Content-Security-Policy for the web/ demo — the CONSUMER-side backstop for
 * the XSS campaign.
 *
 * ## Why this exists (named failure mode)
 *
 * The React SDK block emitters are proven XSS-clean (react-xss-sweep, guard
 * #12289) and the API sanitizes legacy `body_html` at store time
 * (`api/lib/barkpark/portable_doc/html_sanitizer.ex`). This CSP is the
 * defense-in-depth LAYER for the consumer app: the several
 * `dangerouslySetInnerHTML` sinks in web/ (document-detail, paper-editor-doc)
 * inject escaped emitter/body_html output — but if ANY upstream layer ever
 * regresses, an enforcing `script-src` WITHOUT `'unsafe-inline'` stops an
 * injected inline `<script>` / `on*=` handler from executing in the browser.
 * Neither layer is trusted alone.
 *
 * ## Posture (mirrors api/lib/barkpark_web/plugs/paper_reader_csp.ex intent)
 *
 * A per-request NONCE lets exactly the app's own inline scripts run (the
 * theme-boot `<script>` in the root layout, and Next's own `__next_f.push` RSC
 * bootstrap scripts, which Next stamps with the same nonce when it reads
 * `x-nonce` off the forwarded request headers). Any INJECTED inline script
 * cannot know the per-request nonce, so it is blocked — that is what makes the
 * policy an XSS backstop rather than decoration.
 *
 * `'strict-dynamic'` lets a nonced script load further scripts it trusts
 * (Next's chunk loader) without each needing its own nonce, and — critically —
 * makes conformant browsers IGNORE the host allow-list, so hydration is not
 * bricked by a missing CDN host entry.
 *
 * Deliberately NOT copied from the Phoenix paper reader: `'unsafe-eval'`,
 * `'wasm-unsafe-eval'`, and the `cdn.jsdelivr.net` host — those exist ONLY for
 * the reader's mermaid/wasm/asciinema engines and would needlessly widen the
 * consumer policy. `style-src 'unsafe-inline'` IS kept: Next/Tailwind emit
 * inline `style=` attributes and a `<style>` blob, and a nonce does not cover
 * those; tightening styles is out of scope for a script-XSS backstop.
 */

/**
 * Build the exact CSP header value for a given per-request nonce.
 *
 * Pure — no I/O, no globals — so the policy shape is unit-testable in isolation
 * from the edge runtime. `proxy.ts` mints the nonce and applies the result.
 */
export function buildCspPolicy(nonce: string): string {
  return [
    "default-src 'self'",
    `script-src 'self' 'nonce-${nonce}' 'strict-dynamic'`,
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data: blob:",
    "font-src 'self'",
    "connect-src 'self' ws: wss:",
    "object-src 'none'",
    "base-uri 'self'",
    "frame-ancestors 'none'",
    "form-action 'self'",
  ].join("; ");
}

/**
 * Mint a fresh, unguessable per-request nonce. `crypto.randomUUID()` is a
 * cryptographically-strong source present in the Edge/Web-Crypto runtime the
 * proxy runs under (and in Node ≥ 18), and `btoa` base64-encodes it so the
 * value is a compact CSP-token-safe string. A fresh value per request is what
 * keeps an injected script from ever guessing it.
 */
export function generateNonce(): string {
  return btoa(crypto.randomUUID());
}
