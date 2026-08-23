import { NextResponse, type NextRequest } from 'next/server'
import { buildCspPolicy, generateNonce } from './lib/csp'

// Per-request-nonce Content-Security-Policy for the website-starter scaffold.
//
// Next 15.5.x convention: a top-level `middleware.ts` exporting `middleware` +
// `config`. We mint a fresh nonce per request and:
//   1. set the CSP + `x-nonce` on the FORWARDED request headers, so Next reads
//      the nonce off the incoming request and stamps its own inline hydration
//      scripts with `nonce="…"` — this is why the strict `script-src` (no
//      'unsafe-inline') does not break the app's own scripts;
//   2. set the CSP on the RESPONSE headers, so the browser enforces it.
//
// Because the nonce is delivered on the request header (not read via
// `headers()` in the layout), Next keeps the template routes static-eligible —
// the middleware flips ZERO routes static→dynamic (wave verify V2). This is
// defense-in-depth on top of the one trusted `dangerouslySetInnerHTML` sink
// (`PortableDocSurface`, fed only by `renderPortableDocument`'s escaped
// output — see lib/csp.ts): a nonce-gated `script-src` means an injected
// `<script>` still cannot execute even if that emitter ever regressed.

export function middleware(request: NextRequest): NextResponse {
  const nonce = generateNonce()
  const csp = buildCspPolicy(nonce)

  const requestHeaders = new Headers(request.headers)
  requestHeaders.set('x-nonce', nonce)
  requestHeaders.set('content-security-policy', csp)

  const response = NextResponse.next({
    request: { headers: requestHeaders },
  })
  response.headers.set('content-security-policy', csp)

  return response
}

export const config = {
  // Run on every route EXCEPT static assets and the API — those neither render
  // HTML that could host an injected inline script nor need the nonce plumbing.
  matcher: [
    {
      source:
        '/((?!_next/static|_next/image|favicon.ico|api).*)',
      missing: [
        { type: 'header', key: 'next-router-prefetch' },
        { type: 'header', key: 'purpose', value: 'prefetch' },
      ],
    },
  ],
}
