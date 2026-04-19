# W2 — CLI + Starters Shakedown (Phase 8 slice 8.2)

**Auditor:** Worker W8.2 (b-t8-w2)
**Date:** 2026-04-19
**Subject:** `create-barkpark-app@preview` (published 1.0.0-preview.0) + `@barkpark/*` SDK packages
**Mode:** Read-only audit. No source modifications; only this deliverable.
**Verdict:** ❌ **FAIL** — the scaffolded project cannot install, typecheck end-to-end, run `dev`, or `build` without manual intervention. Three P0 defects.

---

## 1. Environment

| Tool | Version |
|---|---|
| node | v24.14.1 |
| npm | 11.11.0 |
| pnpm | present (not used — see Step 2 rationale) |
| Platform | linux x86_64 |

## 2. npm registry packument (before scaffold)

```text
$ npm view create-barkpark-app dist-tags
{ preview: '1.0.0-preview.0', latest: '1.0.0-preview.0' }

$ for pkg in @barkpark/core @barkpark/client @barkpark/next @barkpark/nextjs \
             @barkpark/react @barkpark/codegen @barkpark/website-starter \
             @barkpark/blog-starter; do ...
Published (1.0.0-preview.0):  @barkpark/core, @barkpark/react,
                              @barkpark/codegen, @barkpark/nextjs
Not found (E404):             @barkpark/client, @barkpark/next,
                              @barkpark/website-starter, @barkpark/blog-starter
```

Peer deps for the installed packages:

```text
@barkpark/nextjs@1.0.0-preview.0 peerDependencies:
  { next: '>=15 <17', react: '>=19', 'react-dom': '>=19', zod: '^3.23.0' }
@barkpark/react@1.0.0-preview.0  peerDependencies:
  { react: '>=19', 'react-dom': '>=19' }
```

## 3. Scaffold transcript (raw)

```text
$ mkdir -p /tmp/bp-cli-test && cd /tmp/bp-cli-test
$ time npm create barkpark-app@preview my-site -- --yes 2>&1 | tee scaffold.log
npm warn exec The following package was not found and will be installed: create-barkpark-app@1.0.0-preview.0

> npx
> "create-barkpark-app" my-site --yes

┌  Barkpark
│
◇  Copied 25 files from templates/website-starter
npm error code ETARGET
npm error notarget No matching version found for @barkpark/core@0.1.0.
npm error notarget In most cases you or one of your dependencies are requesting
npm error notarget a package version that doesn't exist.
npm error A complete log of this run can be found in: ...
Dependency install failed: Command failed with exit code 1: npm install
You can run "npm install" manually from /tmp/bp-cli-test/my-site.
│
└  Done.

Next steps:
  cd my-site
  npm install
  docker compose up -d        # Phoenix API + Postgres on :4000
  npm run barkpark codegen  # generate types from schema
  npm run dev                # Next.js on :3000

Want a free hosted API for prototyping? Pass --hosted-demo. (Defaults to local docker-compose.)

real    0m6.600s
user    0m4.688s
sys     0m0.838s
```

- `--yes` is accepted (non-interactive).
- CLI exits **0** and prints `└  Done.` even though install failed — see DEF-4.

## 4. Generated project layout

```text
my-site/
├── app/
│   ├── about/page.tsx
│   ├── contact/{page.tsx, actions.ts}
│   ├── globals.css
│   ├── hosted-demo-banner.tsx
│   ├── layout.tsx
│   ├── page.tsx
│   ├── posts/[slug]/
│   └── pricing/page.tsx
├── barkpark.config.ts
├── docker-compose.override.yml.example
├── docker-compose.yml
├── .env.example
├── .git/                         # initialised automatically
├── .gitignore
├── lib/barkpark.ts
├── next.config.mjs
├── package.json
├── postcss.config.js
├── README.md
├── schemas/{author,page,post}.ts
├── seeds/seed.ts
├── tailwind.config.ts
└── tsconfig.json                 # 25 files total, matches CLI message
```

### 4.1 Generated `package.json` (verbatim)

```json
{
  "name": "my-site",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "next dev",
    "build": "next build",
    "start": "next start",
    "lint": "next lint",
    "typecheck": "tsc --noEmit",
    "codegen": "barkpark codegen",
    "seed": "tsx seeds/seed.ts"
  },
  "dependencies": {
    "@barkpark/core": "0.1.0",
    "@barkpark/nextjs": "0.1.0",
    "@barkpark/react": "0.1.0",
    "next": "^15.0.0",
    "react": "^18.3.0",
    "react-dom": "^18.3.0"
  },
  "devDependencies": {
    "@types/node": "^20.11.0",
    "@types/react": "^18.3.0",
    "@types/react-dom": "^18.3.0",
    "autoprefixer": "^10.4.0",
    "postcss": "^8.4.0",
    "tailwindcss": "^3.4.0",
    "tsx": "^4.7.0",
    "typescript": "^5.4.0"
  },
  "engines": { "node": ">=20.0.0" }
}
```

**Smell test:** dep pins are `0.1.0` but registry has nothing ≤ `1.0.0-preview.0`; no `@barkpark/codegen` dep despite `scripts.codegen` calling `barkpark`; React 18 is chosen despite `@barkpark/nextjs` peer-requiring React 19; README says `React 18`.

## 5. Install timing

| Attempt | Command | Wall time | Result |
|---|---|---|---|
| A (default) | `npm install` (0.1.0 pins) | 2.603s | ❌ `ETARGET @barkpark/core@0.1.0` |
| B (versions patched to `1.0.0-preview.0`) | `npm install` | 1.067s | ❌ `ERESOLVE` peer `react@>=19` vs `react@18.3.1` |
| C | `npm install --legacy-peer-deps` | 10.738s | ✅ 117 packages, 0 vulnerabilities |

Raw install error extracts:

```text
# Attempt A
npm error code ETARGET
npm error notarget No matching version found for @barkpark/core@0.1.0.

# Attempt B
npm error code ERESOLVE
npm error Could not resolve dependency:
npm error peer react@">=19" from @barkpark/nextjs@1.0.0-preview.0
npm error   @barkpark/nextjs@"1.0.0-preview.0" from the root project
```

**Only attempt C (hacked versions + legacy-peer-deps) progresses to the next step.** A vanilla scaffold cannot install.

## 6. TypeScript check

After Attempt C only:

```text
$ npx tsc --noEmit
(exit 0, zero output, zero errors)
```

**PASS** for E2 zero-TS-errors criterion — but only on the manually patched tree. The shipped template fails install entirely, so a fresh user never reaches `tsc`.

## 7. Dev server boot

```text
$ npm run dev  (background)
> next dev
   ▲ Next.js 15.5.15
   - Local: http://localhost:3000
 ✓ Ready in 1717ms
 ○ Compiling / ...
 ✓ Compiled / in 3.9s (614 modules)
 ⨯ TypeError: (0 , react__WEBPACK_IMPORTED_MODULE_0__.createContext) is not a function
    at eval (webpack-internal:///(rsc)/./lib/barkpark.ts:10:81)
```

```text
$ curl -sI http://localhost:3000
HTTP/1.1 500 Internal Server Error
Content-Type: text/html; charset=utf-8
Content-Length: 7073
```

Root cause (confirmed in installed artifact):

```js
// node_modules/@barkpark/nextjs/dist/chunk-SWNTGJD6.mjs (line 1)
import { createContext, useContext, useEffect } from 'react';
// ...
var ClientContext = createContext(null);
```

`dist/server.mjs` re-exports from `chunk-SWNTGJD6.mjs` at the top, so the `createContext` reference is evaluated as soon as any RSC code imports `@barkpark/nextjs/server`. Under React 18 (`--legacy-peer-deps` path) that export is not callable in the RSC runtime → TypeError.

**FAIL.**

## 8. `next build`

```text
$ npm run build 2>&1 | tail -20
> next build
   ▲ Next.js 15.5.15
   Creating an optimized production build ...
 ✓ Compiled successfully in 5.4s
   Linting and checking validity of types ...
   Collecting page data ...
[Error: Failed to collect configuration for /pricing] {
  [cause]: TypeError: (0 , d.createContext) is not a function
      at 49833 (.next/server/app/pricing/page.js:1:4148)
      ...
}
[Error: Failed to collect configuration for /] {
  [cause]: TypeError: (0 , d.createContext) is not a function
}
> Build error occurred
[Error: Failed to collect page data for /pricing] { type: 'Error' }
```

Exit code **1**. **FAIL** (same root cause as §7).

## 9. Tests

`package.json` defines no `test` script. Skipped silently per task instructions.

## 10. `npm run codegen`

```text
$ npm run codegen
> barkpark codegen
sh: 1: barkpark: not found
```

`@barkpark/codegen` (which ships `bin: {barkpark: dist/cli.mjs}`) is NOT in the scaffolded `dependencies`/`devDependencies`, so the documented `npm run barkpark codegen` step from the CLI's own "Next steps" message fails out of the box.

## 11. Standalone starters (step 9)

Neither `@barkpark/website-starter` nor `@barkpark/blog-starter` is on the registry (E404). Step 9 cannot be executed; filed as DEF-5.

## 12. Papercuts

- `--yes` is honoured but documented only implicitly; CLI help not inspected (binary unavailable pre-install).
- CLI prints `└  Done.` after install failure; misleading UX (DEF-4).
- Next-steps message says `npm run barkpark codegen` which is not a valid npm-scripts form (should be `npm run codegen` or `npx barkpark codegen`). Even if fixed, no binary is installed (DEF-3).
- README says "React 18, TypeScript" — inconsistent with @barkpark/nextjs peer of react ≥19 (DEF-2).
- `.env.example` uses placeholder `changeme-barkpark-dev-token` but CLAUDE.md / server uses `barkpark-dev-token` — a user following both docs will get 401s until they notice.
- Phoenix `SECRET_KEY_BASE=changeme-generate-a-64-char-random-string-before-deploying-anywhere` may cause docker-compose Phoenix to refuse to start until edited; not tested (docker not brought up in this audit).
- Generated project is a fresh `git init` repo, but there is no initial commit, so the first `git status` shows all files untracked — minor.
- Scaffold takes ~6.6s wall including npm registry lookup — acceptable.
- `pnpm` was not attempted because attempt A already proved the package.json is broken; the failure mode is registry-level, not package-manager-specific.

## 13. DEFECTS

| ID | Pri | Task ID | One-liner | Evidence |
|---|---|---|---|---|
| DEF-1 | **P0** | #17 | Scaffold pins `@barkpark/{core,nextjs,react}@0.1.0`; only `1.0.0-preview.0` is published → `ETARGET` on first `npm install`. | §3, §4.1, §5 attempt A |
| DEF-2 | **P0** | #19 | `@barkpark/nextjs` requires React ≥19; starter pins React 18 + README says React 18 → `ERESOLVE` then runtime `createContext` TypeError in dev & build. | §2, §5 attempts B/C, §7, §8 |
| DEF-3 | P1 | #20 | `scripts.codegen` calls `barkpark` but `@barkpark/codegen` is not a dep → `sh: barkpark: not found`. | §10 |
| DEF-4 | P1 | #22 | CLI exits 0 and prints `Done.` after install failure, misleading users. | §3 |
| DEF-5 | P2 | #23 | `@barkpark/website-starter` and `@barkpark/blog-starter` not published (nor is `@barkpark/client`); blocks step-9 starters check and any direct-template install path. | §2, §11 |

## 14. E2 Gate (zero-TS-errors criterion)

- With the **shipped** template: **FAIL** — cannot reach `tsc` (install errors).
- With manual version patch + `--legacy-peer-deps`: **PASS** (`tsc --noEmit` exits 0).

Until DEF-1 and DEF-2 are fixed, `create-barkpark-app@preview` is not usable end-to-end.

## 15. Artefacts

All captured under `/tmp/bp-cli-test/`:
- `scaffold.log` — CLI run transcript (§3)
- `my-site/package.json`, `my-site/package.json.orig` — generated vs. patched
- `my-site/install.log` (A), `install2.log` (B), `install3.log` (C)
- `my-site/tsc.log` — empty (§6)
- `my-site/dev.log` — dev server boot + TypeError (§7)
- `my-site/build.log` — build failure (§8)
