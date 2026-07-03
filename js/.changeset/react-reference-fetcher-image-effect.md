---
'@barkpark/react': patch
---

Two render-stability fixes:

- `BarkparkReference`: memoize the derived fetcher on `[fetcher, client]` identity. When used as `<BarkparkReference client={...}>` with no explicit `fetcher`, the internal `resolveFetcher` built a fresh async closure on every render — so any unrelated parent re-render (e.g. `BarkparkLive`'s `router.refresh()`) invalidated the inner `useMemo([id, fetcher])`, firing a redundant refetch and a Suspense-fallback flash. The memo is hoisted above the early returns to keep hook order stable.

- `BarkparkImage`: move the missing-baseUrl side effects (the `onMissingBaseUrl(asset)` callback and the dev `console.warn`) out of the render body and into a `useEffect`. `src` resolution is now a pure helper, so it's safe on concurrent/aborted renders; the callback fires once per committed render instead of once per render (or twice under StrictMode/concurrent) — a caller wiring analytics into `onMissingBaseUrl` no longer gets duplicate events. Rendered output is unchanged (a missing asset still renders nothing). SSR (`renderToString`) intentionally skips these dev/analytics affordances since effects don't run on the server.
