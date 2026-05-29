# Phase 2 Monorepo Scaffold — Synthesized Implementation Spec

**Audience:** the 3 implementation workers (A/B/C) that will create the `js/` monorepo skeleton.
**Scope:** scaffold-only. Source files are throwing/`TODO` stubs whose ONLY job is to make `pnpm i && pnpm build && pnpm test` pass green and unblock Phase 3.
**Source ADRs synthesized:** 000, 001, 002, 003, 004, 005, 006, 007, 008, 009, 010, 011, 012 + masterplan-20260417-212541.md + VERIFICATION-REPORT.md.
**Monorepo root path (decision):** `js/` at repo root. ADR-001 line 32 leaves "co-located with the monorepo at `js/` (or repo root, finalized at scaffold)" open; the task brief and masterplan Phase 2 deliverable both use `js/`. Lock to `js/`.

---

## 1. Package layout

All six packages live at `js/packages/<name>/`. Every package is `private: false`, `license: "Apache-2.0"`, `type: "module"`, with `engines: {node: ">=20"}` and `sideEffects: false`. Stub packages (`groq`, `nextjs-query`) are versioned `0.0.0-placeholder` per critic.md L74 (referenced from ADR-001 L30, ADR-000 L39, ADR-012 L134-143). Real packages start at `0.0.0` (Changesets bumps from there).

### 1.1 `@barkpark/core`
- **Purpose:** runtime-agnostic HTTP client (`fetch`-only) for Phoenix; owns filter-builder, fluent patch, transactions, listen, error taxonomy.
- **package.json name:** `@barkpark/core`
- **Version:** `0.0.0`
- **License:** `Apache-2.0`
- **`type`:** `"module"`
- **Public exports from `src/index.ts` (stubs):**
  - `createClient(config)` — factory, returns `BarkparkClient` (stub throws "not implemented in scaffold"; real impl Phase 3).
  - `defineActions(client)` — re-exported here per ADR-008 L42 ("re-exported from `@barkpark/core` for framework-agnostic use"). Stub throws.
  - `typedClient(client)` — signature only; the real factory body is emitted by codegen (ADR-006 L35-39). Scaffold ships an identity passthrough that returns `client` unchanged.
  - **10 error classes (ADR-009 L47-60):** `BarkparkError` (base), `BarkparkAPIError`, `BarkparkAuthError`, `BarkparkNetworkError`, `BarkparkTimeoutError`, `BarkparkRateLimitError`, `BarkparkNotFoundError`, `BarkparkValidationError`, `BarkparkHmacError`, `BarkparkSchemaMismatchError`, `BarkparkEdgeRuntimeError`. (`BarkparkConflictError` is a subclass of `BarkparkAPIError`, ADR-008 L62 — also exported.)
  - **Types:** `BarkparkClient`, `BarkparkConfig`, `ListenEvent`, `RequestContext`, `ResponseContext`, `BarkparkHooks` (ADR-010 L42-50).
- **Workspace deps:** none.
- **Peer deps:** none (zero-dep runtime — ADR-002 L18, masterplan L261 "Zero RxJS").
- **`optionalDependencies`:** `undici` (latest stable; ADR-002 L22, dynamic-imported only on Node <18).
- **`devDependencies`:** `tsup`, `typescript`, `vitest`, `msw`, `@size-limit/preset-small-lib`, `size-limit`, `@vitest/browser`, `playwright` (browser-pool driver), `miniflare`, `@cloudflare/workers-types`.
- **Size budget:** `< 12 KB gz` (`.size-limit.json`, masterplan L256).

### 1.2 `@barkpark/codegen`
- **Purpose:** CLI (`barkpark`) that introspects `/v1/schemas/:dataset` and emits `barkpark.types.ts` + Zod input schemas + `typedClient` factory binding.
- **package.json name:** `@barkpark/codegen`
- **Version:** `0.0.0`
- **`type`:** `"module"`
- **`bin`:** `{ "barkpark": "./dist/cli.mjs" }` (ESM-only CLI; ADR-001's tsup is configured for both, but the bin entry points at `.mjs` so Node's shebang works without CJS shim).
- **Public exports from `src/index.ts` (stubs):**
  - `defineConfig(config)` — for `barkpark.config.ts` (mirrors `tsup`/`vite` patterns; ADR-006 L24-34 implies a config surface even if not named explicitly).
  - Type re-exports: `BarkparkCodegenConfig`, `BarkparkSchemaJson`.
- **Public CLI commands (stubs that print "not implemented; Phase 4"):** `init`, `schema extract`, `codegen [--watch] [--loose]`, `check` (masterplan Phase 4 lines 148-159).
- **Workspace deps:** `@barkpark/core` (uses `createClient` to fetch schemas in Phase 4; in scaffold, listed as `workspace:^` to wire Turborepo `^build` ordering).
- **Runtime deps:** `chokidar` (ADR-006 L34), `commander` or `cac` (CLI parser — choose `cac` for smaller bundle), `zod` (emitted into generated files but also used by codegen at run-time for validation), `prettier` (formats generated output).
- **Peer deps:** none.
- **devDeps:** standard build/test set.

### 1.3 `@barkpark/nextjs`
- **Purpose:** Next.js App Router integration. Runtime-split subpaths per ADR-001 L24, masterplan L161-171.
- **package.json name:** `@barkpark/nextjs`
- **Version:** `0.0.0`
- **`type`:** `"module"`
- **Public exports — subpath map (ADR-001 L99-114, masterplan L43):**
  - `.` (root) — `revalidateBarkpark()` helper (ADR-003 L28-30, masterplan L168), public type re-exports. NO server/client code at root.
  - `./server` — `createBarkparkServer(config)`, `defineLive({client, serverToken, browserToken?, fetchOptions?})` returning `{barkparkFetch, BarkparkLive, BarkparkLiveProvider}` (masterplan L162-163). First line of file: `import 'server-only'` (ADR-004 L30).
  - `./client` — `BarkparkLive` re-export prefixed with `'use client'` (masterplan L165). Edge-detection guard from ADR-005 L27-30.
  - `./actions` — `defineActions(client)` returning `{createDoc, patchDoc, publish, unpublish, transaction}` (ADR-008 L42-48, masterplan L175-177); `useOptimisticDocument()` (masterplan L178).
  - `./webhook` — `createWebhookHandler({secret, onMutation?, previousSecret?})` (masterplan L167).
  - `./draft-mode` — `createDraftModeRoutes({previewSecret, resolvePath})` returning `{GET, DELETE}` (masterplan L166).
- **Workspace deps:** `@barkpark/core` (`workspace:^`).
- **Peer deps:**
  - `next: ">=15.0.0 <17"` (masterplan risk L240).
  - `react: ">=19.0.0"` (uses `useOptimistic` — masterplan L178).
  - `react-dom: ">=19.0.0"`.
- **`peerDependenciesMeta`:** `react-dom` is `optional: false`; all others required.
- **devDeps:** `next@15.x`, `react@19.x`, `react-dom@19.x` for type-checking + tests.
- **Size budget:** `client` entry < 15 KB gz, `server` entry < 20 KB gz, `react` entry n/a here (masterplan L256).

### 1.4 `@barkpark/react`
- **Purpose:** framework-free renderers (PortableText, Image with `as` override, Reference with cycle detection). Zero `next/*` imports.
- **package.json name:** `@barkpark/react`
- **Version:** `0.0.0`
- **`type`:** `"module"`
- **Public exports from `src/index.ts` (stubs):**
  - `PortableText` (component)
  - `BarkparkImage` (component, accepts `as` prop — masterplan L180)
  - `BarkparkReference` (component, accepts `fetcher` or `client` prop — masterplan L181)
  - Types: `PortableTextProps`, `BarkparkImageProps`, `BarkparkReferenceProps`, `PortableTextComponents`.
- **Workspace deps:** `@barkpark/core` (`workspace:^`).
- **Peer deps:**
  - `react: ">=19.0.0"`.
  - `react-dom: ">=19.0.0"`.
- **devDeps:** standard + `react`, `react-dom`, `@vitest/browser`.
- **Size budget:** `< 8 KB gz` (masterplan L256).

### 1.5 `@barkpark/groq` (stub)
- **Purpose:** reserved npm name for 1.1 GROQ DSL (ADR-000 L22, ADR-001 L30, masterplan L46).
- **package.json name:** `@barkpark/groq`
- **Version:** `0.0.0-placeholder` (ADR-001 L30, critic.md L74).
- **`type`:** `"module"`
- **Public exports from `src/index.ts`:** module top-level **throws on import** with the message:
  ```
  @barkpark/groq is not implemented in 1.0. Deferred to 1.1 — see https://barkpark.dev/roadmap.
  ```
- **Workspace deps:** none.
- **Peer deps:** none.
- **README:** "1.1 roadmap — npm name reserved." Cross-references ADR-000 codemod gate.

### 1.6 `@barkpark/nextjs-query` (stub)
- **Purpose:** reserved npm name for 1.1 TanStack Query adapter (ADR-012 L131-168).
- **package.json name:** `@barkpark/nextjs-query`
- **Version:** `0.0.0-placeholder`
- **`type`:** `"module"`
- **Public exports from `src/index.ts`:** module top-level **throws on import** with the **exact** message from ADR-012 L140-143:
  ```
  @barkpark/nextjs-query is not implemented in 1.0. Deferred to 1.1 — see https://barkpark.dev/roadmap. For optimistic updates, use useOptimisticDocument() from @barkpark/nextjs.
  ```
- **Workspace deps:** none.
- **Peer deps:** none.

---

## 2. Build/exports contract

**Source ADR:** ADR-001 (sections "Decision" L19-32 and "Worked Example" L79-114). The brief mis-mapped this to ADR-005; ADR-005 is live transport.

### 2.1 tsup config shape (per package)

`packages/<name>/tsup.config.ts`:
```ts
import { defineConfig } from 'tsup'

export default defineConfig({
  entry: { index: 'src/index.ts' },          // see §2.2 for nextjs multi-entry
  format: ['cjs', 'esm'],
  dts: true,                                  // emits .d.ts AND .d.mts via rollup-plugin-dts
  sourcemap: true,
  clean: true,
  splitting: true,                            // ESM only
  treeshake: true,
  target: 'es2022',
  outDir: 'dist',
  external: [],                               // populated per package — see §2.3
  outExtension({ format }) {
    return { js: format === 'cjs' ? '.cjs' : '.mjs' }
  },
})
```

**Critical:** `outExtension` MUST emit `.cjs` for CJS and `.mjs` for ESM. tsup defaults to `.js` for CJS which breaks dual-publish in `"type": "module"` packages (Node parses unmarked `.js` as ESM). The `.d.mts` file is automatically emitted by tsup when `dts: true` is set in conjunction with both formats.

### 2.2 `@barkpark/nextjs` multi-entry tsup (ADR-001 L99-114)

```ts
export default defineConfig({
  entry: {
    index:        'src/index.ts',
    server:       'src/server/index.ts',
    client:       'src/client/index.ts',
    actions:      'src/actions/index.ts',
    webhook:      'src/webhook/index.ts',
    'draft-mode': 'src/draft-mode/index.ts',
  },
  format: ['cjs', 'esm'],
  dts: true,
  // … rest as §2.1
})
```
Each entry produces `dist/<name>.cjs`, `dist/<name>.mjs`, `dist/<name>.d.ts`, `dist/<name>.d.mts`.

### 2.3 `external` per package
- **core:** `['undici']` (optional dep; never bundled — ADR-001 L55, ADR-002 L70).
- **codegen:** `['chokidar', 'cac', 'zod', 'prettier']` (runtime deps).
- **nextjs:** `['react', 'react-dom', 'next', 'next/cache', 'next/headers', 'next/server', 'server-only', '@barkpark/core']`.
- **react:** `['react', 'react-dom', '@barkpark/core']`.
- **groq, nextjs-query:** `[]`.

### 2.4 `package.json` `exports` map

**Single-entry packages (core, codegen, react, groq, nextjs-query):**
```json
{
  "type": "module",
  "main": "./dist/index.cjs",
  "module": "./dist/index.mjs",
  "types": "./dist/index.d.ts",
  "exports": {
    ".": {
      "import": {
        "types": "./dist/index.d.mts",
        "default": "./dist/index.mjs"
      },
      "require": {
        "types": "./dist/index.d.ts",
        "default": "./dist/index.cjs"
      }
    },
    "./package.json": "./package.json"
  },
  "files": ["dist", "README.md", "LICENSE"],
  "sideEffects": false,
  "engines": { "node": ">=20" }
}
```

**`@barkpark/codegen`** also adds `"bin": { "barkpark": "./dist/cli.mjs" }`.

**Multi-entry `@barkpark/nextjs`:**
```json
{
  "type": "module",
  "main": "./dist/index.cjs",
  "module": "./dist/index.mjs",
  "types": "./dist/index.d.ts",
  "exports": {
    ".":            { "import": { "types": "./dist/index.d.mts",        "default": "./dist/index.mjs" },        "require": { "types": "./dist/index.d.ts",        "default": "./dist/index.cjs" } },
    "./server":     { "import": { "types": "./dist/server.d.mts",       "default": "./dist/server.mjs" },       "require": { "types": "./dist/server.d.ts",       "default": "./dist/server.cjs" } },
    "./client":     { "import": { "types": "./dist/client.d.mts",       "default": "./dist/client.mjs" },       "require": { "types": "./dist/client.d.ts",       "default": "./dist/client.cjs" } },
    "./actions":    { "import": { "types": "./dist/actions.d.mts",      "default": "./dist/actions.mjs" },      "require": { "types": "./dist/actions.d.ts",      "default": "./dist/actions.cjs" } },
    "./webhook":    { "import": { "types": "./dist/webhook.d.mts",      "default": "./dist/webhook.mjs" },      "require": { "types": "./dist/webhook.d.ts",      "default": "./dist/webhook.cjs" } },
    "./draft-mode": { "import": { "types": "./dist/draft-mode.d.mts",   "default": "./dist/draft-mode.mjs" },   "require": { "types": "./dist/draft-mode.d.ts",   "default": "./dist/draft-mode.cjs" } },
    "./package.json": "./package.json"
  }
}
```

### 2.5 File extension → package.json field map

| Field | Extension |
|---|---|
| `main` (CJS legacy resolver) | `.cjs` |
| `module` (bundlers' ESM hint) | `.mjs` |
| `types` (TS legacy resolver) | `.d.ts` |
| `exports.*.import.types` (modern ESM type resolver, Node16/Bundler moduleResolution) | `.d.mts` |
| `exports.*.import.default` | `.mjs` |
| `exports.*.require.types` | `.d.ts` |
| `exports.*.require.default` | `.cjs` |

### 2.6 `engines` and `sideEffects`
- `engines.node`: `">=20"` everywhere (masterplan L105 runtime matrix locks node 20/22 as supported tier; <18 lives only on the `undici` polyfill cliff).
- `sideEffects: false` on all six packages (enables tree-shaking; ADR-001 L25).

---

## 3. Root tooling config

All paths below are relative to `js/`.

### 3.1 `pnpm-workspace.yaml`
```yaml
packages:
  - 'packages/*'
  - 'docs'           # reserved for Phase 7 Fumadocs site; create empty placeholder dir + README only
```

### 3.2 Root `package.json` (orchestration only — no published code)
```json
{
  "name": "barkpark-js",
  "private": true,
  "version": "0.0.0",
  "license": "Apache-2.0",
  "packageManager": "pnpm@9.12.0",
  "engines": { "node": ">=20", "pnpm": ">=9" },
  "scripts": {
    "build":     "turbo run build",
    "test":      "turbo run test",
    "typecheck": "turbo run typecheck",
    "lint":      "turbo run lint",
    "size":      "turbo run size",
    "changeset": "changeset",
    "version-packages": "changeset version",
    "release":   "turbo run build && changeset publish"
  },
  "devDependencies": {
    "turbo": "^2.x",
    "typescript": "^5.6.x",
    "tsup": "^8.x",
    "vitest": "^2.x",
    "@vitest/browser": "^2.x",
    "@vitest/coverage-v8": "^2.x",
    "playwright": "^1.x",
    "msw": "^2.x",
    "miniflare": "^3.x",
    "@cloudflare/workers-types": "^4.x",
    "size-limit": "^11.x",
    "@size-limit/preset-small-lib": "^11.x",
    "@changesets/cli": "^2.x",
    "eslint": "^9.x",
    "@typescript-eslint/parser": "^8.x",
    "@typescript-eslint/eslint-plugin": "^8.x",
    "eslint-plugin-import": "^2.x",
    "prettier": "^3.x"
  }
}
```

### 3.3 `turbo.json`
```json
{
  "$schema": "https://turbo.build/schema.json",
  "ui": "stream",
  "tasks": {
    "build": {
      "dependsOn": ["^build"],
      "inputs": ["src/**", "tsup.config.ts", "package.json", "tsconfig.json"],
      "outputs": ["dist/**"]
    },
    "typecheck": {
      "dependsOn": ["^build"],
      "inputs": ["src/**", "tests/**", "tsconfig.json", "../../tsconfig.base.json"]
    },
    "test": {
      "dependsOn": ["^build"],
      "inputs": ["src/**", "tests/**", "vitest.config.ts"],
      "outputs": ["coverage/**"]
    },
    "lint": {
      "inputs": ["src/**", "tests/**", "../../eslint.config.js"]
    },
    "size": {
      "dependsOn": ["build"],
      "inputs": ["dist/**", ".size-limit.json"]
    }
  }
}
```

`dependsOn: ["^build"]` enforces topological order: `core` builds before `nextjs`/`react`/`codegen`. Required by ADR-001 L22.

### 3.4 `tsconfig.base.json`
```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "lib": ["ES2022", "DOM", "DOM.Iterable"],
    "strict": true,
    "noUncheckedIndexedAccess": true,
    "noImplicitOverride": true,
    "exactOptionalPropertyTypes": true,
    "esModuleInterop": true,
    "isolatedModules": true,
    "verbatimModuleSyntax": true,
    "skipLibCheck": true,
    "resolveJsonModule": true,
    "forceConsistentCasingInFileNames": true,
    "noEmit": true,
    "declaration": false
  },
  "exclude": ["**/dist", "**/node_modules"]
}
```
Per-package `tsconfig.json`:
```json
{
  "extends": "../../tsconfig.base.json",
  "include": ["src/**/*", "tests/**/*"],
  "compilerOptions": {
    "rootDir": "."
  }
}
```
Type emission is owned by tsup (`dts: true`) — `tsc` is `--noEmit` (ADR-001 L26).

### 3.5 `eslint.config.js` (flat config, ESLint 9)
```js
import tseslint from '@typescript-eslint/eslint-plugin'
import tsparser from '@typescript-eslint/parser'
import importPlugin from 'eslint-plugin-import'

export default [
  { ignores: ['**/dist/**', '**/node_modules/**', '**/.turbo/**', 'docs/**'] },
  {
    files: ['**/*.{ts,tsx}'],
    languageOptions: {
      parser: tsparser,
      parserOptions: { project: ['./packages/*/tsconfig.json'] },
    },
    plugins: { '@typescript-eslint': tseslint, import: importPlugin },
    rules: {
      '@typescript-eslint/no-unused-vars': ['error', { argsIgnorePattern: '^_' }],
      '@typescript-eslint/consistent-type-imports': 'error',
      '@typescript-eslint/no-floating-promises': 'error',
      'import/no-default-export': 'off',
      'no-restricted-imports': ['error', {
        // ADR-002 L27: zero `node:` imports in core / nextjs edge subpaths
        // Enforced via grep test in CI rather than ESLint to keep config simple
      }],
    },
  },
]
```
A separate **CI grep job** enforces "no `node:` imports in `packages/core/src/**` or `packages/nextjs/src/{client,server,webhook,draft-mode}/**`" per ADR-002 L27, masterplan L169.

### 3.6 `.prettierrc`
```json
{
  "semi": false,
  "singleQuote": true,
  "trailingComma": "all",
  "printWidth": 100,
  "arrowParens": "always"
}
```
(Style mirrors ADR-002 worked-example formatting.)

### 3.7 vitest config — workspace mode

`vitest.workspace.ts` (root):
```ts
import { defineWorkspace } from 'vitest/config'

export default defineWorkspace([
  // Default node project for every package
  'packages/*/vitest.config.ts',
  // Browser project for DOM-touching packages (ADR-001 L28)
  {
    extends: './packages/react/vitest.config.ts',
    test: {
      name: 'react-browser',
      browser: { enabled: true, provider: 'playwright', name: 'chromium', headless: true },
      include: ['packages/react/tests/**/*.browser.test.ts?(x)'],
    },
  },
  // Workerd project for runtime-parity tests (ADR-002 L26 + ADR-005)
  {
    extends: './packages/core/vitest.config.ts',
    test: {
      name: 'core-workerd',
      pool: '@cloudflare/vitest-pool-workers',
      poolOptions: { workers: { miniflare: { compatibilityDate: '2024-09-23' } } },
      include: ['packages/core/tests/**/*.workerd.test.ts'],
    },
  },
])
```

Per-package `vitest.config.ts`:
```ts
import { defineConfig } from 'vitest/config'
export default defineConfig({
  test: {
    environment: 'node',
    coverage: { provider: 'v8', reporter: ['text', 'lcov'], include: ['src/**'] },
    setupFiles: ['../../test-utils/vitest.setup.ts'],   // §3.8
  },
})
```

### 3.8 MSW setup — `js/test-utils/`
A repo-internal (NOT published) directory `js/test-utils/` holds shared MSW fixtures so every package's vitest setup can `import { server } from '../../test-utils/msw'` without an extra workspace package. Files:
- `test-utils/msw/handlers.ts` — default Phoenix REST handlers (one stub each for `GET /v1/data/query/:dataset/:type`, `GET /v1/data/doc/:dataset/:type/:id`, `POST /v1/data/mutate/:dataset`, `GET /v1/meta`, `GET /v1/schemas/:dataset`, `GET /v1/data/listen` SSE).
- `test-utils/msw/server.ts` — `setupServer(...handlers)`.
- `test-utils/vitest.setup.ts` — `beforeAll(server.listen)`, `afterEach(server.resetHandlers)`, `afterAll(server.close)`.

Scaffold ships handler stubs only (return canned envelopes matching P1-b). Real assertions land in Phase 3+.

### 3.9 miniflare/workerd integration
Use the `@cloudflare/vitest-pool-workers` package as the vitest pool for the dedicated `core-workerd` project (see §3.7). Files matching `*.workerd.test.ts` execute inside a workerd runtime via miniflare. Requires:
- `wrangler.toml` at `js/packages/core/` (minimal: `compatibility_date = "2024-09-23"`, no bindings).
- A single example test `tests/runtime.workerd.test.ts` that asserts `typeof globalThis.fetch === 'function'`.

### 3.10 changesets — `.changeset/config.json`
```json
{
  "$schema": "https://unpkg.com/@changesets/config@3.0.0/schema.json",
  "changelog": ["@changesets/changelog-github", { "repo": "barkpark/barkpark" }],
  "commit": false,
  "fixed": [],
  "linked": [],
  "access": "public",
  "baseBranch": "main",
  "updateInternalDependencies": "patch",
  "ignore": ["@barkpark/groq", "@barkpark/nextjs-query"],
  "snapshot": { "useCalculatedVersion": true, "prereleaseTemplate": "{tag}.{datetime}" },
  "___experimentalUnsafeOptions_WILL_CHANGE_IN_PATCH": {
    "onlyUpdatePeerDependentsWhenOutOfRange": true,
    "useCalculatedVersionForSnapshots": true
  }
}
```
- `access: "public"` — required for scoped npm publish (ADR-001 L23).
- `baseBranch: "main"` — masterplan default.
- `updateInternalDependencies: "patch"` — ADR-001 L23.
- `ignore: ["@barkpark/groq", "@barkpark/nextjs-query"]` — stub packages stay at `0.0.0-placeholder`; Changesets does not bump them (ADR-001 L30, ADR-012 L131-143).
- **`bumpVersionsWithWorkspaceProtocolOnly`** is NOT a top-level Changesets option (the brief asked about it). The closest equivalent is the experimental flag above; default behavior already preserves `workspace:^` ranges. Document the choice but do not invent a non-existent key.

A pre-release mode for `@next` channel (ADR-012 L48) is entered manually via `changeset pre enter next` from CI before publish; CI exits pre mode with `changeset pre exit` only when the release manager runs the manual `@latest` promotion workflow.

---

## 4. CI matrix

**Source ADRs:** masterplan L123-128 (canonical), ADR-001 L31 (composition), ADR-002 L26 (runtime matrix), ADR-012 L43-87 (release flow). The brief mis-mapped CI to ADR-012 only; the matrix authority is masterplan L123 + ADR-001 L31.

All workflows live at `js/.github/workflows/` (paths in workflow `paths` filters are repo-root-relative — `js/**`).

### 4.1 `js/.github/workflows/ci.yml` — main per-PR/push pipeline
```yaml
name: js-ci
on:
  push:    { branches: [main], paths: ['js/**'] }
  pull_request: { paths: ['js/**'] }

concurrency:
  group: js-ci-${{ github.ref }}
  cancel-in-progress: true

jobs:
  lint-and-typecheck:
    runs-on: ubuntu-latest
    defaults: { run: { working-directory: js } }
    steps:
      - uses: actions/checkout@v4
      - uses: pnpm/action-setup@v4
      - uses: actions/setup-node@v4
        with: { node-version: 22, cache: pnpm, cache-dependency-path: js/pnpm-lock.yaml }
      - run: pnpm install --frozen-lockfile
      - run: pnpm lint
      - run: pnpm typecheck
      - name: grep-test no node: imports on edge surfaces
        run: bash scripts/check-no-node-imports.sh

  test-node:
    needs: lint-and-typecheck
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix: { node: [20, 22] }
    defaults: { run: { working-directory: js } }
    steps:
      - uses: actions/checkout@v4
      - uses: pnpm/action-setup@v4
      - uses: actions/setup-node@v4
        with: { node-version: ${{ matrix.node }}, cache: pnpm, cache-dependency-path: js/pnpm-lock.yaml }
      - run: pnpm install --frozen-lockfile
      - run: pnpm build
      - run: pnpm test -- --project=core --project=codegen --project=nextjs --project=react

  test-bun:
    needs: lint-and-typecheck
    runs-on: ubuntu-latest
    defaults: { run: { working-directory: js } }
    steps:
      - uses: actions/checkout@v4
      - uses: oven-sh/setup-bun@v2
        with: { bun-version: latest }
      - uses: pnpm/action-setup@v4
      - run: pnpm install --frozen-lockfile
      - run: pnpm build
      - run: bun test packages/core/tests   # bun runs vitest natively on simple suites

  test-workerd:
    needs: lint-and-typecheck
    runs-on: ubuntu-latest
    defaults: { run: { working-directory: js } }
    steps:
      - uses: actions/checkout@v4
      - uses: pnpm/action-setup@v4
      - uses: actions/setup-node@v4
        with: { node-version: 22, cache: pnpm, cache-dependency-path: js/pnpm-lock.yaml }
      - run: pnpm install --frozen-lockfile
      - run: pnpm build
      - run: pnpm test -- --project=core-workerd

  test-browser:
    needs: lint-and-typecheck
    runs-on: ubuntu-latest
    defaults: { run: { working-directory: js } }
    steps:
      - uses: actions/checkout@v4
      - uses: pnpm/action-setup@v4
      - uses: actions/setup-node@v4
        with: { node-version: 22, cache: pnpm, cache-dependency-path: js/pnpm-lock.yaml }
      - run: pnpm install --frozen-lockfile
      - run: pnpm exec playwright install chromium
      - run: pnpm build
      - run: pnpm test -- --project=react-browser

  build-and-size:
    needs: [test-node, test-bun, test-workerd, test-browser]
    runs-on: ubuntu-latest
    defaults: { run: { working-directory: js } }
    steps:
      - uses: actions/checkout@v4
      - uses: pnpm/action-setup@v4
      - uses: actions/setup-node@v4
        with: { node-version: 22, cache: pnpm, cache-dependency-path: js/pnpm-lock.yaml }
      - run: pnpm install --frozen-lockfile
      - run: pnpm build
      - run: pnpm size
      # +2% regression gate (ADR-001 L29, masterplan L239) — size-limit's
      # built-in compare uses the previous build artifact; CI fails on diff > 2%.

  changeset-check:
    if: github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    defaults: { run: { working-directory: js } }
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: pnpm/action-setup@v4
      - run: pnpm install --frozen-lockfile
      - run: pnpm changeset status --since=origin/main
```

### 4.2 `js/.github/workflows/contract.yml` — Phoenix contract tests
Trigger paths per ADR-001 L31 and masterplan L124:
```yaml
name: contract
on:
  push:
    paths:
      - 'api/lib/**'
      - 'js/packages/**'
  pull_request:
    paths:
      - 'api/lib/**'
      - 'js/packages/**'
  schedule:
    - cron: '17 3 * * *'   # nightly 03:17 UTC

jobs:
  contract:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:16
        env: { POSTGRES_PASSWORD: postgres }
        ports: ['5432:5432']
        options: --health-cmd pg_isready --health-interval 5s
    steps:
      - uses: actions/checkout@v4
      - uses: erlef/setup-beam@v1
        with: { otp-version: '27.x', elixir-version: '1.17.x' }
      - name: Bring up Phoenix from docker-compose
        run: docker compose -f api/docker-compose.test.yml up -d
      - uses: pnpm/action-setup@v4
      - uses: actions/setup-node@v4
        with: { node-version: 22, cache: pnpm, cache-dependency-path: js/pnpm-lock.yaml }
      - run: cd js && pnpm install --frozen-lockfile && pnpm build
      - run: cd js && pnpm --filter @barkpark/core test:contract
        env: { BARKPARK_API_URL: http://localhost:4000 }
```

(`docker-compose.test.yml` is a Phase 3 deliverable; the workflow file ships now and will be wired to a real compose file then. Currently use a placeholder `echo "contract test placeholder — wired in Phase 3"` step.)

### 4.3 `js/.github/workflows/vercel-preview.yml` — per-PR Vercel preview
Trigger: only on PRs touching `js/packages/nextjs/**` (masterplan L123 + L227-238 narrow scope to keep cost bounded).
```yaml
name: vercel-preview
on:
  pull_request:
    paths: ['js/packages/nextjs/**']

jobs:
  preview:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Deploy preview app to Vercel
        uses: amondnet/vercel-action@v25
        with:
          vercel-token: ${{ secrets.VERCEL_TOKEN }}
          vercel-org-id: ${{ secrets.VERCEL_ORG_ID }}
          vercel-project-id: ${{ secrets.VERCEL_PROJECT_ID }}
          working-directory: js/examples/vercel-preview-harness
      - name: Smoke (one RSC page + one edge route + listen-throws)
        run: bash js/scripts/vercel-preview-smoke.sh "${{ steps.deploy.outputs.preview-url }}"
```
The `examples/vercel-preview-harness` Next.js mini-app is a Phase 3 follow-up; the workflow file ships now with a `continue-on-error: true` step and a TODO note. The three smoke assertions are scripted per masterplan L123: one RSC page, one edge route, one `client.listen()` throws-on-edge.

### 4.4 `js/.github/workflows/release.yml` — Changesets release
```yaml
name: release
on:
  push: { branches: [main] }

concurrency: { group: release, cancel-in-progress: false }

jobs:
  release:
    runs-on: ubuntu-latest
    permissions: { contents: write, pull-requests: write, id-token: write }
    defaults: { run: { working-directory: js } }
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - uses: pnpm/action-setup@v4
      - uses: actions/setup-node@v4
        with: { node-version: 22, cache: pnpm, registry-url: 'https://registry.npmjs.org' }
      - run: pnpm install --frozen-lockfile
      - run: pnpm build
      - id: changesets
        uses: changesets/action@v1
        with:
          version: pnpm version-packages
          publish: pnpm changeset publish --tag next   # @next default per ADR-012 L48
          createGithubReleases: true
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          NPM_TOKEN: ${{ secrets.NPM_TOKEN }}
```

### 4.5 `js/.github/workflows/promote-latest.yml` — manual @latest promotion
```yaml
name: promote-latest
on:
  workflow_dispatch:
    inputs:
      version:
        description: 'Exact version to promote to @latest (e.g. 1.0.0)'
        required: true
      packages:
        description: 'Space-separated package names; default = all six'
        required: false
        default: '@barkpark/core @barkpark/codegen @barkpark/nextjs @barkpark/react'
jobs:
  promote:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/setup-node@v4
        with: { node-version: 22, registry-url: 'https://registry.npmjs.org' }
      - name: Coordinated retag → latest (ADR-012 §Rollback protocol L73-78)
        run: |
          for pkg in ${{ github.event.inputs.packages }}; do
            npm dist-tag add "${pkg}@${{ github.event.inputs.version }}" latest
          done
        env: { NPM_TOKEN: ${{ secrets.NPM_TOKEN }} }
```
The same template, parameterised, doubles as `rollback-to.sh` (ADR-012 L77).

### 4.6 Caching
- **pnpm store cache**: `actions/setup-node@v4` with `cache: pnpm` and `cache-dependency-path: js/pnpm-lock.yaml`. Used in every job above.
- **Turborepo remote cache**: NOT enabled in 1.0 scaffold (ADR-001 L22 "Remote caching optional; local caching on by default"). A future opt-in via `TURBO_TOKEN` + `TURBO_TEAM` secrets.
- **Playwright browser cache**: `~/.cache/ms-playwright`, restored via the `actions/cache` pattern in the `test-browser` job (add separately if browser install becomes slow; 1.0 scaffold relies on the per-job install).

---

## 5. Root-level files

All paths below are relative to `js/` UNLESS noted as repo-root.

### 5.1 LICENSE — Apache-2.0
**Two copies required** (masterplan L37, L122 — repo currently has zero LICENSE files):
1. **Repo root** (`/LICENSE`) — covers Phoenix API + TUI + monorepo contents.
2. **Monorepo root** (`/js/LICENSE`) — covers all `js/packages/**` (each package README cross-references this file via `../../LICENSE` in published `files`).

The file body is the verbatim Apache License 2.0 text from https://www.apache.org/licenses/LICENSE-2.0.txt.

**SPDX identifier header for source files** — by convention each package's `src/index.ts` opens with:
```ts
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors
```
(Single line each — not a full header block. Apache-2.0 NOTICE file is NOT required because Barkpark distributes no third-party Apache-2.0 components in the scaffold.)

### 5.2 SECURITY.md — `js/SECURITY.md`
```markdown
# Security Policy

## Reporting a Vulnerability

Please report security issues to **security@barkpark.dev**. Do NOT open a
public GitHub issue.

We aim to acknowledge within 48 hours and ship a fix within 14 days for
critical issues. Coordinated disclosure window is 90 days from acknowledgment.

## Supported Versions

| Channel  | Supported            |
|----------|----------------------|
| @latest  | yes                  |
| @next    | yes (best effort)    |
| @preview | no (testing only)    |

See ADR-012 for the release-channel policy.

## Bug Bounty

Not currently funded. Public acknowledgment in CHANGELOG + SECURITY-HALL-OF-FAME.md.
```
(Email per masterplan L122 + ADR-001 L32.)

### 5.3 CODEOWNERS — `js/.github/CODEOWNERS`
ADRs do not name a maintainer team; use `@barkpark-maintainers` as placeholder per the task brief.
```
*                              @barkpark-maintainers
js/packages/core/**            @barkpark-maintainers
js/packages/codegen/**         @barkpark-maintainers
js/packages/nextjs/**          @barkpark-maintainers
js/packages/react/**           @barkpark-maintainers
js/packages/groq/**            @barkpark-maintainers
js/packages/nextjs-query/**    @barkpark-maintainers
js/.github/**                  @barkpark-maintainers
js/.changeset/**               @barkpark-maintainers
api/**                         @barkpark-maintainers
```

### 5.4 CONTRIBUTING.md — `js/CONTRIBUTING.md`
Sections (masterplan L122):
1. **Workflow** — fork → branch off `main` → PR. Squash-merge; commit messages follow conventional-commits.
2. **Local setup** — `cd js && pnpm install && pnpm build`.
3. **How to add a changeset** — `pnpm changeset` and follow the prompts; commit the generated `.changeset/*.md` file with the PR. CI's `changeset-check` job blocks merges that touch `packages/**` without a changeset.
4. **How to run tests** — `pnpm test` (all projects), `pnpm test --project=core` (single), `pnpm test:contract` (against ephemeral Phoenix), `pnpm test --project=core-workerd` (workerd parity), `pnpm test --project=react-browser` (DOM).
5. **Bundle budgets** — `pnpm size`. CI fails on > 2% regression (ADR-001 L29).
6. **ADRs** — link to `.doey/plans/adrs/`. Any change touching the Decision section of a locked ADR requires a follow-up amendment ADR.
7. **No `node:` imports** in `core` and `nextjs/{client,server,webhook,draft-mode}` — enforced by `scripts/check-no-node-imports.sh`.

---

## 6. File tree diagram

```
barkpark/
├── LICENSE                                    ← NEW (Apache-2.0, repo-root copy)
└── js/                                        ← NEW monorepo root
    ├── LICENSE                                ← NEW (duplicate of repo-root for npm publish)
    ├── SECURITY.md
    ├── CONTRIBUTING.md
    ├── README.md                              ← brief monorepo readme + cross-refs
    ├── package.json                           ← private root, workspace orchestration
    ├── pnpm-workspace.yaml
    ├── pnpm-lock.yaml                         ← generated by first pnpm install
    ├── turbo.json
    ├── tsconfig.base.json
    ├── eslint.config.js
    ├── .prettierrc
    ├── .gitignore                             ← node_modules, dist, .turbo, .changeset/pre.json
    ├── .npmrc                                 ← public-hoist-pattern[]= and shamefully-hoist=false
    ├── vitest.workspace.ts
    │
    ├── .changeset/
    │   ├── README.md
    │   └── config.json
    │
    ├── .github/
    │   ├── CODEOWNERS
    │   ├── pull_request_template.md
    │   └── workflows/
    │       ├── ci.yml
    │       ├── contract.yml
    │       ├── vercel-preview.yml
    │       ├── release.yml
    │       └── promote-latest.yml
    │
    ├── scripts/
    │   ├── check-no-node-imports.sh
    │   └── vercel-preview-smoke.sh            ← TODO stub for Phase 5
    │
    ├── test-utils/                            ← internal, not published
    │   ├── msw/
    │   │   ├── handlers.ts
    │   │   └── server.ts
    │   └── vitest.setup.ts
    │
    ├── docs/                                  ← Phase 7 placeholder
    │   └── README.md
    │
    └── packages/
        ├── core/
        │   ├── package.json
        │   ├── tsconfig.json
        │   ├── tsup.config.ts
        │   ├── vitest.config.ts
        │   ├── wrangler.toml                  ← workerd test pool only
        │   ├── .size-limit.json               ← {dist/index.mjs, 12 KB}
        │   ├── README.md
        │   ├── src/
        │   │   ├── index.ts                   ← stub: createClient, defineActions, typedClient, errors
        │   │   ├── errors.ts                  ← 10 error classes (ADR-009)
        │   │   ├── client.ts                  ← createClient stub
        │   │   ├── filter-builder.ts          ← stub
        │   │   ├── patch.ts                   ← stub
        │   │   ├── transaction.ts             ← stub
        │   │   ├── listen.ts                  ← stub with edge-detection guard signature
        │   │   └── types.ts                   ← BarkparkClient, RequestContext, ResponseContext, BarkparkHooks
        │   └── tests/
        │       ├── smoke.test.ts              ← imports index, asserts exports exist
        │       └── runtime.workerd.test.ts    ← asserts globalThis.fetch present in workerd
        │
        ├── codegen/
        │   ├── package.json                   ← bin: { barkpark: ./dist/cli.mjs }
        │   ├── tsconfig.json
        │   ├── tsup.config.ts                 ← entry: { index: src/index.ts, cli: src/cli.ts }
        │   ├── vitest.config.ts
        │   ├── .size-limit.json
        │   ├── README.md
        │   ├── src/
        │   │   ├── index.ts                   ← defineConfig + types
        │   │   ├── cli.ts                     ← #!/usr/bin/env node + cac router stubs
        │   │   └── types.ts
        │   └── tests/
        │       └── smoke.test.ts
        │
        ├── nextjs/
        │   ├── package.json                   ← multi-entry exports map (§2.4)
        │   ├── tsconfig.json
        │   ├── tsup.config.ts                 ← 6 entries (§2.2)
        │   ├── vitest.config.ts
        │   ├── .size-limit.json               ← server <20KB, client <15KB
        │   ├── README.md
        │   └── src/
        │       ├── index.ts                   ← revalidateBarkpark stub + type re-exports
        │       ├── server/index.ts            ← `import 'server-only'`; createBarkparkServer + defineLive stubs
        │       ├── client/index.ts            ← `'use client'`; BarkparkLive stub
        │       ├── actions/index.ts           ← defineActions, useOptimisticDocument stubs
        │       ├── webhook/index.ts           ← createWebhookHandler stub
        │       └── draft-mode/index.ts        ← createDraftModeRoutes stub
        │   └── tests/
        │       └── smoke.test.ts
        │
        ├── react/
        │   ├── package.json
        │   ├── tsconfig.json
        │   ├── tsup.config.ts
        │   ├── vitest.config.ts
        │   ├── .size-limit.json               ← <8KB
        │   ├── README.md
        │   └── src/
        │       ├── index.ts                   ← PortableText, BarkparkImage, BarkparkReference stubs
        │       ├── PortableText.tsx
        │       ├── Image.tsx
        │       └── Reference.tsx
        │   └── tests/
        │       ├── smoke.test.ts
        │       └── PortableText.browser.test.tsx
        │
        ├── groq/
        │   ├── package.json                   ← version: 0.0.0-placeholder
        │   ├── tsconfig.json
        │   ├── tsup.config.ts
        │   ├── README.md                      ← "1.1 roadmap"
        │   └── src/
        │       └── index.ts                   ← throw new Error("not implemented in 1.0…")
        │   └── tests/
        │       └── smoke.test.ts              ← asserts import throws
        │
        └── nextjs-query/
            ├── package.json                   ← version: 0.0.0-placeholder
            ├── tsconfig.json
            ├── tsup.config.ts
            ├── README.md
            └── src/
                └── index.ts                   ← throw with exact ADR-012 L140 message
            └── tests/
                └── smoke.test.ts
```

---

## 7. Open questions / ADR conflicts

1. **Brief mis-mapping (already noted in task brief).** The task brief said "ADR-002 = package layout, ADR-005 = build/exports, ADR-012 = CI matrix." Reality: **ADR-001** owns all three. ADR-002 = fetch transport; ADR-005 = live transport; ADR-012 = release channels (which informs the @next vs @latest portion of CI but not the matrix axes).
2. **Monorepo root location (`js/` vs repo root).** ADR-001 L32 leaves this open: "Co-located with the monorepo at `js/` (or repo root, finalized at scaffold)." Spec locks `js/` based on consistent usage in masterplan Phase 2 ("`js/` workspace root", L120). Implementer should NOT relitigate unless they discover a concrete conflict with the existing Go TUI or Phoenix paths.
3. **`packageManager` pnpm version pin.** ADR-001 L21 says "`packageManager: pnpm@<pinned>`" without naming the version. Spec uses `pnpm@9.12.0` (current stable as of 2026-04-17). If implementer finds a known pnpm 9.x bug affecting workspace resolution, downgrade is fine.
4. **`bumpVersionsWithWorkspaceProtocolOnly` (asked in brief).** This is **not a top-level Changesets config option** in the published schema. The brief may have confused it with the experimental flag `___experimentalUnsafeOptions_WILL_CHANGE_IN_PATCH.useCalculatedVersionForSnapshots`. Default behavior already preserves `workspace:^` ranges through bumps. Spec does NOT include the non-existent key.
5. **ADR-005 step-3 Web-Streams heuristic bug (VERIFICATION-REPORT L120).** The ADR's edge-detection literal would mis-fire in browsers; the verification report defers the `typeof window === 'undefined'` refinement to Phase 3 implementation. Phase 2 scaffold should ship the `client/index.ts` stub WITHOUT a literal heuristic — leave a `TODO(ADR-005-step-3-bug)` comment so Phase 3 catches the refinement.
6. **ADR-007 cross-ref naming drift (VERIFICATION-REPORT L116, "must fix").** The verification report flagged `VersionMismatchError` → `SchemaMismatchError` rename in ADR-007. Phase 2 scaffold's `errors.ts` MUST export `BarkparkSchemaMismatchError` (per ADR-009, the canonical taxonomy) and NOT export a `VersionMismatchError`. The ADR-007 text is wrong; the masterplan and ADR-009 are right.
7. **`@cloudflare/vitest-pool-workers` package name stability.** This package's API is still pre-1.0 as of 2026-04. If it has a breaking change before scaffold lands, fall back to running workerd tests via `miniflare` programmatically in a custom vitest reporter — heavier but stable. Document in `vitest.workspace.ts` comments.
8. **Vercel preview workflow secrets.** `VERCEL_TOKEN`, `VERCEL_ORG_ID`, `VERCEL_PROJECT_ID` need to be set on the repo before the workflow runs. Phase 2 scaffold ships the workflow file with `if: secrets.VERCEL_TOKEN != ''` to skip when not configured — surfacing as "not configured" rather than a hard failure.
9. **Phoenix `docker-compose.test.yml`.** Referenced by `contract.yml` (§4.2) but does not exist in the repo. Phase 2 scaffold must NOT block on this — ship the workflow file with a placeholder `echo "wired in Phase 3"` step. Mark as TODO in `contract.yml`.
10. **`Apache-2.0` `NOTICE` file.** Apache-2.0 requires a NOTICE file ONLY if the redistribution itself contains third-party Apache-2.0 NOTICE content. Phase 2 scaffold has no such third-party content; NOTICE is optional and omitted. Reconsider when first Apache-licensed dependency is added at runtime.
11. **CODEOWNERS team name (`@barkpark-maintainers`).** Placeholder per task brief instruction. Replace with the real team handle when GitHub org structure is established.

---

## 8. Dispatch plan

Three workers run in parallel. Files are partitioned so no file is touched by two workers. Worker A finishes first (config-heavy, no source); Workers B and C can start as soon as A's per-package directory `mkdir -p` is committed.

### Worker A — Tooling configs + package.json files
**Theme:** "Wire up the build, test, lint, and exports surface."
**Files to create:**
- `/LICENSE` (repo root, Apache-2.0 verbatim)
- `js/LICENSE`
- `js/package.json`
- `js/pnpm-workspace.yaml`
- `js/.npmrc`
- `js/.gitignore`
- `js/turbo.json`
- `js/tsconfig.base.json`
- `js/eslint.config.js`
- `js/.prettierrc`
- `js/vitest.workspace.ts`
- `js/.changeset/config.json`
- `js/.changeset/README.md`
- For each package in `{core, codegen, nextjs, react, groq, nextjs-query}`:
  - `js/packages/<pkg>/package.json`
  - `js/packages/<pkg>/tsconfig.json`
  - `js/packages/<pkg>/tsup.config.ts`
  - `js/packages/<pkg>/vitest.config.ts`
  - `js/packages/<pkg>/.size-limit.json` (omit for groq/nextjs-query)
- `js/packages/core/wrangler.toml`

### Worker B — Source stubs + test stubs + READMEs
**Theme:** "Make every package importable; make the test runner happy."
**Files to create:**
- For each package, `js/packages/<pkg>/README.md` (1-screen blurb + ADR cross-refs).
- `js/packages/core/src/{index.ts, errors.ts, client.ts, filter-builder.ts, patch.ts, transaction.ts, listen.ts, types.ts}` — stubs that throw or return identity but export the symbols listed in §1.1.
- `js/packages/core/tests/{smoke.test.ts, runtime.workerd.test.ts}`
- `js/packages/codegen/src/{index.ts, cli.ts, types.ts}` + `tests/smoke.test.ts`
- `js/packages/nextjs/src/{index.ts, server/index.ts, client/index.ts, actions/index.ts, webhook/index.ts, draft-mode/index.ts}` + `tests/smoke.test.ts`
- `js/packages/react/src/{index.ts, PortableText.tsx, Image.tsx, Reference.tsx}` + `tests/{smoke.test.ts, PortableText.browser.test.tsx}`
- `js/packages/groq/src/index.ts` + `tests/smoke.test.ts`
- `js/packages/nextjs-query/src/index.ts` + `tests/smoke.test.ts`
- `js/test-utils/msw/{handlers.ts, server.ts}`
- `js/test-utils/vitest.setup.ts`
- `js/docs/README.md` (one-line placeholder)
- `js/README.md` (monorepo overview + ADR cross-refs)

### Worker C — CI workflows + repo hygiene + scripts
**Theme:** "Make CI green and the project welcoming."
**Files to create:**
- `js/SECURITY.md`
- `js/CONTRIBUTING.md`
- `js/.github/CODEOWNERS`
- `js/.github/pull_request_template.md`
- `js/.github/workflows/ci.yml`
- `js/.github/workflows/contract.yml`
- `js/.github/workflows/vercel-preview.yml`
- `js/.github/workflows/release.yml`
- `js/.github/workflows/promote-latest.yml`
- `js/scripts/check-no-node-imports.sh`
- `js/scripts/vercel-preview-smoke.sh` (TODO stub)

**Coordination:** Worker A's outputs (package.json `name` fields, exports map shapes) ARE inputs to Worker B's `src/index.ts` files (must export the symbols A's `exports` map promises) and to Worker C's CI workflow paths. Both B and C should treat the §1 Public Exports table and the §6 file-tree as the single source of truth — they encode A's outputs in advance, so B and C can begin in parallel without a serial handoff. Final verification step (run by Subtaskmaster after all three complete): `cd js && pnpm install && pnpm build && pnpm test && pnpm typecheck && pnpm lint`. All five MUST pass before Phase 2 is signed off.
