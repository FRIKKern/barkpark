---
'create-barkpark-app': patch
---

Both starter templates (`blog-starter`, `website-starter`): `lib/barkpark.ts` now fails loud, at module load, when `BARKPARK_SERVER_TOKEN` is unset and `NODE_ENV==='production'` — instead of silently falling back to `'barkpark-dev-token'`, which the README already documents as forbidden in production. The fallback previously deferred the misconfig to a runtime 401 on every server-side fetch; a missing prod env var now throws immediately with an actionable message instead of shipping a broken deploy.

The check is a pure, dependency-free `resolveServerToken(env)` in a new `lib/resolve-server-token.ts`, unit-tested directly. Non-production environments are unaffected — the dev-token fallback still applies whenever `BARKPARK_SERVER_TOKEN` is unset outside production.
