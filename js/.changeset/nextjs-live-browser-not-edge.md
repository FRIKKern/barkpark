---
'@barkpark/nextjs': patch
'@barkpark/core': patch
---

`<BarkparkLive />` no longer misidentifies a plain browser as an edge runtime.

`@barkpark/nextjs/client` carried its own copy of `detectEdgeRuntime()` whose third layer inferred "edge" from the **absence** of `process`:

```ts
if (typeof ReadableStream !== 'undefined' && typeof process === 'undefined') { … }
```

Every modern browser satisfies both halves. Any consumer whose bundler injects no `process` shim — Vite, Rollup, esbuild, or the published ESM loaded directly — got `BarkparkEdgeRuntimeError: … requires the Node.js runtime` thrown **synchronously during render**, crashing the React tree instead of subscribing. It stayed invisible under Next only because Next's client chunks inject `next/dist/compiled/process` module-scoped into any module that names `process`, which made the branch dead code there and a false positive everywhere else.

The fork is deleted. `@barkpark/nextjs/client` now re-exports `@barkpark/core`'s `detectEdgeRuntime`, which detects edge runtimes by **positive** signal (`globalThis.EdgeRuntime`, `process.env.NEXT_RUNTIME === 'edge'`, a `Cloudflare-Workers` user agent, `globalThis.WebSocketPair`) — none of which a browser has. Absence of `process` was never a sound workerd proxy anyway: under `nodejs_compat`, workerd has `process`.

`@barkpark/core` additively exports `detectEdgeRuntime` and its `EdgeSignal` type (already in the bundle via `listen()`; no size change) so downstream packages reuse one detector instead of maintaining two.

**Behaviour change for direct callers of the exported `detectEdgeRuntime()`:** on detection it now returns core's `EdgeSignal` values — `'vercel-edge-runtime'`, `'next-runtime-edge'`, `'cloudflare-workers'`, `'workerd'` — instead of the old descriptive strings (`'globalThis.EdgeRuntime'`, `'process.env.NEXT_RUNTIME==="edge"'`, `'globalThis.ReadableStream && !process'`). The null/non-null contract, and the `BarkparkEdgeRuntimeError` thrown by `<BarkparkLive />` / `startLiveSubscription()`, are unchanged.

`@barkpark/nextjs` gains a third vitest project, `browser` — a real headless Playwright chromium, wired into the default `test` script — because the `client` project is jsdom-under-node where `process` always exists, so the browser branch had never executed in a test.
