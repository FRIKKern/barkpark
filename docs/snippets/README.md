# Barkpark runnable snippets

Every file in this directory is a **single, self-contained** TypeScript
example. They are type-checked as part of the docs CI (`tsc --noEmit` on
the workspace) and are included verbatim into the MDX guides via
Fumadocs' include directive.

## Contract

- Each snippet is valid TypeScript/TSX and passes `tsc --noEmit` against
  the workspace tsconfig (`js/tsconfig.base.json`, `strict: true`,
  `noUncheckedIndexedAccess: true`, `exactOptionalPropertyTypes: true`).
- Snippets import only from `@barkpark/*`, `next/*`, `react`, and the Node
  standard library. No imports between snippets.
- The first block comment is the "expected output" for the snippet —
  concrete enough to smoke-test the example end-to-end. `_meta.json`
  duplicates this in a structured form.
- Each file exports a single function (or, for App Router route files,
  the App Router convention: `GET` / `POST` / `default`).

## Index

| File                             | Purpose                                        |
| -------------------------------- | ---------------------------------------------- |
| `01-create-document.ts`          | Transaction: create a draft, then publish it.  |
| `02-query-with-filters.ts`       | DocsBuilder: where / order / limit / findOne.  |
| `03-listen-for-updates.ts`       | Async-iterate `client.listen()` SSE events.    |
| `04-mutate-optimistic.tsx`       | Client form with `useOptimisticDocument`.      |
| `05-publish-unpublish.ts`        | `defineActions` publish + unpublish round-trip.|
| `06-server-component-fetch.tsx`  | App Router RSC reading via `barkparkFetch`.    |
| `07-server-action-mutate.tsx`    | `'use server'` module wiring defineActions.    |
| `08-revalidate-on-webhook.ts`    | Webhook route with HMAC + dedup + revalidate.  |

See [`_meta.json`](./_meta.json) for machine-readable metadata including
which framework-guide pages embed each snippet.

## Running locally

Snippets are reference code; they assume the Phoenix API is running at
`https://cms.example.com` (swap for your own project URL) and that the
relevant environment variables are set (`BARKPARK_TOKEN`,
`BARKPARK_SERVER_TOKEN`, `BARKPARK_PREVIEW_SECRET`,
`BARKPARK_WEBHOOK_SECRET`).

To type-check the whole directory:

```bash
cd js
pnpm typecheck      # runs turbo across all workspace packages, incl. docs
```
