// Pure, framework-free: computes the server token `lib/barkpark.ts` hands to
// `createBarkparkServer`. The 'barkpark-dev-token' fallback below is for
// local development only — the README calls it out as forbidden in
// production. Silently applying it in production used to defer a missing
// BARKPARK_SERVER_TOKEN to a runtime 401 on every server-side fetch; this
// throws immediately instead, at module load (no network call — the check
// is a synchronous env read), so a misconfigured prod deploy fails loud at
// startup rather than shipping broken.
//
// Kept dependency-free (no 'server-only', no @barkpark/* imports) so it's
// unit-testable directly — see create-barkpark-app's
// tests/server-token-prod-guard.test.ts.
export function resolveServerToken(env: {
  BARKPARK_SERVER_TOKEN?: string
  NODE_ENV?: string
}): string {
  const token = env.BARKPARK_SERVER_TOKEN
  if (token) return token
  if (env.NODE_ENV === 'production') {
    throw new Error(
      'BARKPARK_SERVER_TOKEN is not set. The "barkpark-dev-token" default is ' +
        'for local development only and must not be used in production — set ' +
        'BARKPARK_SERVER_TOKEN in your deploy environment (see README.md).',
    )
  }
  return 'barkpark-dev-token'
}
