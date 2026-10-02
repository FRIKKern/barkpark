---
'create-barkpark-app': patch
---

A missing post, tag or author in a scaffolded starter now answers HTTP 404 instead of 200. The shared root `app/loading.tsx` was a Suspense boundary: Next streamed the 200 status and the skeleton before the `[slug]` page could call `notFound()`, so every missing route became a soft 404 that carried only a noindex meta. The root skeleton is removed. The search starter already avoids a loading boundary on its detail segment for the same reason.
