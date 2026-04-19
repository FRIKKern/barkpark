# @barkpark/react

## 1.0.0-preview.1

### Minor Changes

- [`c7b9f54`](https://github.com/FRIKKern/barkpark/commit/c7b9f54047a51a134cfec1a047061fe0f9679011) Thanks [@FRIKKern](https://github.com/FRIKKern)! - BREAKING: defineLive now returns {barkparkFetch, defineLive} only; import BarkparkLive/BarkparkLiveProvider from @barkpark/nextjs/client. RSC-safe react-server export. Closes #1.

### Patch Changes

- Updated dependencies [[`47b96c8`](https://github.com/FRIKKern/barkpark/commit/47b96c8b28ab8901be5fe971ba7762dcfdffd662)]:
  - @barkpark/core@1.0.0-preview.2

## preview.1

### Patch Changes

- **Fix RSC boundary crash under Next 15 App Router.** Importing
  `@barkpark/react` from a React Server Component raised
  `TypeError: (0, react.createContext) is not a function`, because Next 15
  resolves `react` via the `react-server` export condition which does not
  expose `createContext`. `BarkparkReference` calls
  `createContext(...)` at module scope to build its cycle-detection
  context.
- **Fix pattern applied:**
  1. Every source module that calls `createContext` at module scope
     (today: `src/Reference.tsx`) carries a `"use client"` directive on
     its first line, plus `src/index.ts`, `src/Image.tsx`, and
     `src/PortableText.tsx` for defence in depth.
  2. `tsup` bundles the whole barrel into one chunk per format and the
     rollup bundler strips module-level directives, so the build pipeline
     now prepends a literal `"use client";` banner to `dist/index.cjs`
     and `dist/index.mjs` via an `onSuccess` hook in `tsup.config.ts`.
     Next's bundler reads the banner and treats the module as a Client
     Component boundary.
  3. `package.json` grows a `react-server` export condition that points
     to a new `dist/server.{mjs,cjs}` entry built from
     `src/server.ts`. The server entry re-exports only
     `PortableText` and `BarkparkImage` (pure, context-free renderers)
     plus type-only re-exports from `Reference`, so no code path from a
     Server Component can pull `createContext` into the RSC graph.
- **Verification:**
  `node --conditions=react-server -e 'require("@barkpark/react")'` no
  longer throws; the resolved module exports `PortableText` and
  `BarkparkImage` and omits `BarkparkReference`. Default (client)
  condition continues to export all three.
- Task #1 / branch `fix/rsc-createcontext-boundaries`.

## 1.0.0-preview.0

### Major Changes

- [#13](https://github.com/FRIKKern/barkpark/pull/13) [`1cc653b`](https://github.com/FRIKKern/barkpark/commit/1cc653be24c23bc5533b0b1a04da527a8518d562) Thanks [@FRIKKern](https://github.com/FRIKKern)! - Phase 8 beta: first `@preview` publish targeting 1.0.0. No breaking changes from Phase 7. Packages now enter Changesets pre-mode under the `preview` dist-tag.

### Patch Changes

- Updated dependencies [[`1cc653b`](https://github.com/FRIKKern/barkpark/commit/1cc653be24c23bc5533b0b1a04da527a8518d562)]:
  - @barkpark/core@1.0.0-preview.0
