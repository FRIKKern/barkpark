# Site Reanimation — barkpark.cloud (2026-04-19)

**Task:** #26 (Phase 8 Remediation C)
**Defects closed:** #11 (Vercel env var missing), #12 (/docs CTA broken)
**Worker:** b-t4-w1
**Branch:** `ops/site-reanimation-task26`

## Summary

Production marketing/demo site at `https://barkpark.cloud` was returning HTTP 200 shell but every data-driven page failed with **502 — "Upstream error. Confirm BARKPARK_API_URL and BARKPARK_PUBLIC_READ_TOKEN are set."** The `/docs` CTA was redirecting to a non-existent subdomain (`docs.barkpark.cloud`, no DNS).

Both defects fixed via Vercel env addition + a single source edit to the `/docs` redirect target. Phase 7 docs subdomain remains the long-term plan.

## Before-state

```text
$ curl -sI https://barkpark.cloud
HTTP/2 200
server: Vercel
x-matched-path: /
age: 11955     # cached shell, no live data fetch in this header probe
etag: "87f7dd20ba55c34d935e76ac03f5046a"

$ curl -s https://barkpark.cloud/post | grep -oE "Upstream error \([0-9]+\)"
Upstream error (502)
# user-visible: "Upstream error (502). Confirm BARKPARK_API_URL and BARKPARK_PUBLIC_READ_TOKEN are set."

$ curl -sI https://barkpark.cloud/docs
HTTP/2 308
location: https://docs.barkpark.cloud/

$ curl -sI https://docs.barkpark.cloud
* Could not resolve host: docs.barkpark.cloud   # NXDOMAIN
```

## Root cause — defect #11

`apps/demo/lib/barkpark.ts:35` reads `process.env.BARKPARK_API_URL` (server-side, no `NEXT_PUBLIC_` prefix needed). A prior remediation attempt (4h before this fix) added **`NEXT_PUBLIC_API_URL`** to all three Vercel envs — the wrong variable name. Code never read it; fetches threw "BARKPARK_API_URL is not set"; the route handler converted that to a 502.

## Vercel env changes

Added `BARKPARK_API_URL=http://89.167.28.206:4000` to **production**, **preview**, and **development**. Per task #4 Caddy TLS work, the API still runs on the bare IP/port; once `https://api.barkpark.cloud` is live, this value should be flipped (one follow-up var update, no code change).

Pre-existing (incorrect) `NEXT_PUBLIC_API_URL` left in place per dispatch hard stop ("DO NOT remove or rotate any other env vars"). Recommend cleanup in a follow-up ops task — the var is unused and confusing.

```text
$ vercel env ls
 name                       value               environments        created
 BARKPARK_API_URL           Encrypted           Preview             6s ago
 BARKPARK_API_URL           Encrypted           Development         31s ago
 BARKPARK_API_URL           Encrypted           Production          43s ago
 NEXT_PUBLIC_API_URL        Encrypted           Development         4h ago    # unused, leftover
 NEXT_PUBLIC_API_URL        Encrypted           Preview             4h ago    # unused, leftover
 NEXT_PUBLIC_API_URL        Encrypted           Production          4h ago    # unused, leftover
```

## /docs CTA decision — defect #12

**Chosen: Option (c) — interim GitHub README link.**

Rationale:
- Option (a) "redeploy auto-fixes" was infeasible: the route handler at `apps/demo/app/docs/route.ts` hardcoded a 308 redirect to `https://docs.barkpark.cloud/`, a subdomain with **no DNS A record**. Re-deploying would not change the target.
- Option (b) "stand up the docs subdomain" is Phase 7 work (Fumadocs app) — out of scope for this remediation.
- Option (c) is the smallest, reversible edit: change the redirect target to the canonical README until Phase 7 lands. Status code dropped from 308 (permanent) to **307 (temporary)** so search engines / clients don't cache the interim URL.

Single-file diff (within the dispatch's "1 edit max" budget):

```diff
-  return NextResponse.redirect("https://docs.barkpark.cloud/", 308);
+  return NextResponse.redirect("https://github.com/FRIKKern/barkpark#readme", 307);
```

When Phase 7 ships docs.barkpark.cloud, revert this file (one-line restore) and the CTA points to the new subdomain again.

## Deploy

```text
$ vercel deploy --prod
Production: https://demo-60mx1cbdu-guerrilla.vercel.app
Deployment ID: dpl_3jsz2JDptB96e843K2HD1C4ncxew
Inspector: https://vercel.com/guerrilla/demo/3jsz2JDptB96e843K2HD1C4ncxew
readyState: READY
```

## After-state verification

```text
$ curl -sI https://barkpark.cloud
HTTP/2 200
server: Vercel
age: 0           # fresh deploy, not cached
etag: "e1a591f962a8c1529f4240e187cf8712"

$ curl -s https://barkpark.cloud/post | grep -oE "[0-9]+ published document"
19 published document
# user-visible: "19 published document(s)" with full <ul> of titles —
# Phoenix API at http://89.167.28.206:4000 is being read live, no 502.

$ curl -sI https://barkpark.cloud/docs
HTTP/2 307
location: https://github.com/FRIKKern/barkpark#readme
```

All three checks green. Defects #11 and #12 ready for closure.

## Follow-ups (not in this task)

1. Remove the leftover `NEXT_PUBLIC_API_URL` env vars on Vercel — unused, misleading.
2. After task #4 Caddy TLS lands, flip `BARKPARK_API_URL` to `https://api.barkpark.cloud` (env update only, no code).
3. After Phase 7 Fumadocs ships, restore the `/docs` redirect target to `https://docs.barkpark.cloud/` and bump status back to 308.
