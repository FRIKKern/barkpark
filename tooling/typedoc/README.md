<!-- doc-tier: agent | canonical-for: typedoc-config | budget: 150tok -->
# TypeDoc configuration — BINDING

Root TypeDoc config for six of the seven Barkpark JS packages (create-barkpark-app excluded — scaffolding CLI, not an API surface). **Track A artifact-handoff contract**: CI regenerates into `docs-site/reference/<pkg>/`; that output is uploaded as the `typedoc-reference` artifact (retained 30 days); `apps/docs` is not yet scaffolded — consumption is planned for Track A.

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
