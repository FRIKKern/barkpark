import { NextResponse, type NextRequest } from "next/server";
import { buildCspPolicy, generateNonce } from "@/lib/csp";

/**
 * Per-request nonce CSP proxy (Next 16 rename of `middleware.ts` — the
 * middleware file convention is deprecated in 16.x; `proxy.ts` keeps the build
 * warning-clean while behaving identically at the request boundary).
 *
 * ## The load-bearing two-header pattern (do NOT simplify to one)
 *
 * The nonce must be visible to TWO consumers, and they read it from different
 * places, so it is stamped in two places:
 *
 *   1. On the FORWARDED REQUEST headers (`request.headers` passed through
 *      `NextResponse.next({ request })`). Next's App-Router renderer reads
 *      `content-security-policy` off the incoming request, extracts the nonce,
 *      and stamps it onto ITS OWN inline bootstrap scripts (`__next_f.push`).
 *      Without this, those framework scripts have no nonce, the enforcing
 *      `script-src` blocks them, and hydration dies into a static shell — the
 *      #1 flip this slice guards against. `x-nonce` is ALSO forwarded so the
 *      root layout can read it via `next/headers` and nonce the theme-boot
 *      `<script>`.
 *
 *   2. On the RESPONSE headers — this is the copy the BROWSER actually
 *      enforces. It must carry the SAME nonce as (1) so the browser trusts the
 *      scripts Next nonced.
 */
export function proxy(request: NextRequest): NextResponse {
  const nonce = generateNonce();
  const policy = buildCspPolicy(nonce);

  const requestHeaders = new Headers(request.headers);
  requestHeaders.set("content-security-policy", policy);
  requestHeaders.set("x-nonce", nonce);

  const response = NextResponse.next({
    request: { headers: requestHeaders },
  });
  response.headers.set("content-security-policy", policy);

  return response;
}

export const config = {
  matcher: [
    /*
     * Run on every request path EXCEPT the ones that never render app HTML
     * (and so need no nonce): Next's static assets, the image optimizer,
     * favicon, and API routes. The trailing negative-lookahead clause skips
     * PREFETCH requests (`next-router-prefetch`) and RSC data fetches — they
     * reuse the page's already-nonced payload, and stamping a fresh (different)
     * nonce on the prefetch would mismatch the enforced document.
     */
    {
      source:
        "/((?!_next/static|_next/image|favicon.ico|api).*)",
      missing: [
        { type: "header", key: "next-router-prefetch" },
        { type: "header", key: "purpose", value: "prefetch" },
      ],
    },
  ],
};
