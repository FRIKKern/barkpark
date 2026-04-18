# TypeDoc configuration

Root TypeDoc config used to generate HTML API reference pages for the six
Barkpark JS packages:

- `@barkpark/core`
- `@barkpark/codegen`
- `@barkpark/nextjs`
- `@barkpark/react`
- `@barkpark/groq`
- `@barkpark/nextjs-query`

## Layout

| Path                          | Purpose                                              |
| ----------------------------- | ---------------------------------------------------- |
| `tooling/typedoc/typedoc.json`| Single root config (`entryPointStrategy: packages`)  |
| `docs-site/reference/<pkg>/`  | Generated HTML output (one folder per package)       |

Using `entryPointStrategy: "packages"` avoids per-package `typedoc.json`
sprawl — TypeDoc walks each listed package, reads its own `package.json`
+ `tsconfig.json`, and emits an aggregated site.

## Running locally

```sh
# From repo root — installs devDeps that include typedoc.
npm install

# Emits zero errors — fast sanity check.
npm run docs:reference:check

# Full HTML generation into docs-site/reference/
npm run docs:reference
```

Generation needs the JS workspace dependencies installed. Ensure
`cd js && pnpm install --frozen-lockfile` has been run once before the first
generation so that each package's `node_modules` is populated.

## CI

`.github/workflows/typedoc.yml` regenerates on every push to `main` and on
pull requests that touch `js/packages/**`. The generated folder is uploaded
as the `typedoc-reference` artifact; Track A's `apps/docs` build consumes
that artifact and copies it under `apps/docs/public/reference/`.

Generated HTML is **not** committed to `main` — only the initial commit
ships a sample tree under `docs-site/reference/` so that the directory
structure is visible in the PR diff.

## Updating for new packages

1. Add the new package path to `entryPoints` in `typedoc.json`.
2. Confirm the package ships `src/index.ts` and a `tsconfig.json`.
3. Run `npm run docs:reference:check` — resolves entry points without
   emitting HTML, catching config drift early.
