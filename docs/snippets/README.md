<!-- doc-tier: agent | canonical-for: snippets-authoring-contract | budget: 300tok -->
# Barkpark runnable snippets

Every file in this directory is a **single, self-contained** TypeScript example. Type-checked locally (`tsc --noEmit`); no CI gate currently covers this directory. Intended for verbatim inclusion in MDX guides via Fumadocs' include directive (wiring not yet in place).

## Authoring contract

- Valid TypeScript/TSX, passes `tsc --noEmit` against `js/tsconfig.base.json` (`strict: true`, `noUncheckedIndexedAccess: true`, `exactOptionalPropertyTypes: true`).
- Imports **only** from `@barkpark/*`, `next/*`, `react`, `server-only`, and the Node standard library. No imports between snippets.
- First block comment is the "expected output" — concrete enough to smoke-test end-to-end. `_meta.json` duplicates this in structured form.
- Each file exports a single function (or App Router convention: `GET` / `POST` / `default`).

## Required env vars

Snippets assume a Phoenix API at `https://cms.example.com` and:

| Var | Purpose |
|---|---|
| `BARKPARK_TOKEN` | read-tier bearer token |
| `BARKPARK_SERVER_TOKEN` | server-only bearer token |
| `BARKPARK_WEBHOOK_SECRET` | webhook HMAC secret |

## Type-check the whole directory

```bash
tsc --noEmit -p docs/snippets/tsconfig.json   # run from repo root
```

## Index

| File | Purpose |
|---|---|
| `01-create-document.ts` | Transaction: create draft, then publish |
| `02-query-with-filters.ts` | DocsBuilder: where / order / limit / findOne |
| `03-listen-for-updates.ts` | Async-iterate `client.listen()` SSE events |
| `04-mutate-optimistic.tsx` | Client form with `useOptimisticDocument` |
| `05-publish-unpublish.ts` | `defineActions` publish + unpublish round-trip |
| `06-server-component-fetch.tsx` | App Router RSC via `barkparkFetch` |
| `07-server-action-mutate.tsx` | `'use server'` module wiring defineActions |
| `08-revalidate-on-webhook.ts` | Webhook route: HMAC + dedup + revalidate |
