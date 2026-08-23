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
 *
 * ## connect-src and the direct live-search WebSocket
 *
 * `connect-src` is `'self'` plus, ONLY when `NEXT_PUBLIC_BARKPARK_WS_URL` is
 * configured, that exact origin (scheme+host[:port], e.g.
 * `wss://api.barkpark.cloud`) — never a bare `ws: wss:` wildcard. The direct
 * WebSocket (`lib/use-live-search.ts`) ships dark by default (needs BOTH
 * `NEXT_PUBLIC_BARKPARK_WS_URL` and `_WS_TOKEN`); with it unset the finder
 * never opens a socket, so `connect-src` has nothing to allow beyond
 * same-origin. Every other browser read in web/ is same-origin, so a bare
 * `ws:`/`wss:` wildcard would let an XSS payload phone home to ANY WebSocket
 * host — the exact origin keeps the backstop tight even when live search is
 * on.
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
    `connect-src 'self'${wsConnectSrcSuffix()}`,
    "object-src 'none'",
    "base-uri 'self'",
    "frame-ancestors 'none'",
    "form-action 'self'",
  ].join("; ");
}

/**
 * The `connect-src` addition for the direct live-search WebSocket, or `""`
 * when `NEXT_PUBLIC_BARKPARK_WS_URL` is unset/unparseable — in which case
 * `connect-src` stays bare `'self'`. Deliberately scoped to the URL's
 * `origin` (never the full URL, which would leak the socket path into the
 * header for no CSP benefit — `connect-src` matches by origin, not path).
 */
function wsConnectSrcSuffix(): string {
  const wsUrl = process.env.NEXT_PUBLIC_BARKPARK_WS_URL;
  if (!wsUrl) return "";
  try {
    return ` ${new URL(wsUrl).origin}`;
  } catch {
    return "";
  }
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
