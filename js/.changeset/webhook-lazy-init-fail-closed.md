---
"create-barkpark-app": patch
---

Scaffolded webhook routes no longer break `next build` when `BARKPARK_WEBHOOK_SECRET` is unset. `createWebhookHandler` validates its config synchronously and throws on a missing secret, and Next imports every route module during build ("Collecting page data") even with `dynamic = 'force-dynamic'` — so the old module-scope call aborted the production build of a freshly scaffolded app. The handler is now built lazily on first request; an unset secret serves a fail-closed `503 webhook_not_configured` instead, and construction is memoized once the secret exists.
