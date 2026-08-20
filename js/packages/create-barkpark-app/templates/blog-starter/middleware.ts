import { NextResponse } from 'next/server';
import type { NextRequest } from 'next/server';
import { buildCspPolicy, generateNonce } from './lib/csp';

// Per-request nonce CSP for the blog-starter scaffold.
//
// Next 15.5.x convention: this file is `middleware.ts` (NOT `proxy.ts`). Verify
// V5 source-proved 15.5.19 carries the same `getScriptNonceFromHeader` +
// `next_f` nonce chain — Next reads the CSP nonce off the *request* header we
// set here and stamps it onto its own inline hydration scripts, so pages stay
// static-eligible and the layout never has to read `headers()`.

export function middleware(request: NextRequest) {
  const nonce = generateNonce();
  const csp = buildCspPolicy(nonce);

  // Forward the nonce + policy to the render pass on the *request* headers so
  // Next tags its inline bootstrap scripts with this nonce.
  const requestHeaders = new Headers(request.headers);
  requestHeaders.set('content-security-policy', csp);
  requestHeaders.set('x-nonce', nonce);

  const response = NextResponse.next({
    request: { headers: requestHeaders },
  });

  // And enforce the same policy on the response the browser actually receives.
  response.headers.set('content-security-policy', csp);

  return response;
}

export const config = {
  matcher: [
    // Run on every path except static assets and the API — those never inject
    // HTML and don't need a script nonce.
    {
      source:
        '/((?!_next/static|_next/image|favicon.ico|api).*)',
      missing: [
        { type: 'header', key: 'next-router-prefetch' },
        { type: 'header', key: 'purpose', value: 'prefetch' },
      ],
    },
  ],
};
