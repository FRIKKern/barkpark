---
'@barkpark/nextjs': patch
---

Document that `createPreloader` must be instantiated per request. Its dedup Map
lives for the instance's lifetime, so a module-scoped `const loader =
createPreloader(server)` (as the old example showed) persists across requests on
a long-lived server — replaying one request's document to the next (stale
content / a cross-request data bleed) and growing unbounded, with no way for
`revalidateTag` to clear it. The example now binds the preloader to the request
with React's `cache()` (`export const getLoader = cache(() => createPreloader(server))`),
and the JSDoc warns against the module-scoped footgun. No runtime behavior change.
