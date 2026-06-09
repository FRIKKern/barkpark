<!-- doc-tier: agent | canonical-for: typedoc-config | budget: 150tok -->
# TypeDoc configuration — BINDING

Root TypeDoc config for the six Barkpark JS packages. **Track A artifact-handoff contract**: CI regenerates into `docs-site/reference/<pkg>/`; that output is uploaded as the `typedoc-reference` artifact and consumed by `apps/docs` at build time.

`entryPointStrategy: "packages"` — avoids per-package `typedoc.json` sprawl; TypeDoc walks each listed package and emits an aggregated site.

## Running locally

```sh
npm install
npm run docs:reference:check   # zero errors, fast sanity (no HTML emitted)
npm run docs:reference         # full HTML generation into docs-site/reference/
```

Ensure `cd js && pnpm install --frozen-lockfile` has run once first.

## Adding a new package

1. Add the path to `entryPoints` in `typedoc.json`.
2. Confirm the package ships `src/index.ts` + `tsconfig.json`.
3. Run `npm run docs:reference:check`.
