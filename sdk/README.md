<!-- doc-tier: agent | canonical-for: bulldocs-sdk | budget: 600tok -->
# Bulldocs ingest SDK — NOT the general JS SDK; see js/

`@barkpark/bulldocs-sdk` is a thin TypeScript authoring SDK for **Barkpark Bulldocs** papers — typed block constructors, a `Paper` builder, and an ingest client that publishes papers and submits block-ops over the `/v1/plugins/bulldocs/*` endpoints.

For the general Barkpark JS SDK (query, mutate, listen, etc.) see `js/packages/core/` — that one *is* on npm as `@barkpark/core`.

---

## Install — not published yet

`@barkpark/bulldocs-sdk` is **not published yet** — never on npm;
`npm view @barkpark/bulldocs-sdk version` answers `E404`. Consume it from this repo:

```bash
cd sdk && npm install && npm run build   # tsc -> dist/src
npm install /abs/path/to/barkpark/sdk    # or "@barkpark/bulldocs-sdk": "file:../sdk"
```

In-repo code imports the source (`sdk/examples/author-and-submit.ts` → `../src/index.js`).

Requires global `fetch` (Node 22+) or pass your own.

## Paper builder

```ts
import { paper, heading, ingress, paragraph, diagram } from "@barkpark/bulldocs-sdk";

const doc = paper("2026-06-07-demo", { title: "SDK Demo", style: "article" }).add(
  heading(1, "The Bulldocs SDK"),
  ingress("A thin authoring layer over native PortableDoc blocks."),
  paragraph("Built in TypeScript."),
  diagram("graph TD; A[author] --> B[publish]; B --> C[/papers/:slug]", "Figure 1."),
);
```

Each block constructor mints a deterministic `id` (`b1`, `b2`, …). Output is byte-reproducible — no `Date.now()`/random.

## Publish

The ingest token rides as `Authorization: Bearer` behind the server's `RequireIngestToken` plug.

```ts
import { BulldocsClient } from "@barkpark/bulldocs-sdk";

const client = new BulldocsClient({
  baseURL: "http://localhost:4000",
  ingestToken: process.env.BARKPARK_INGEST_TOKEN!,
});

const receipt = await client.publish(doc);
// PublishReceipt: { ok, slug, rev, liveview_path }
```

## Block ops (`ifRev` optimistic guard)

`submitOps(slug, ops, { ifRev? })` applies a batch atomically. A `ifRev` mismatch throws `BulldocsError` with `code: "precondition_failed"` — re-fetch the current rev and retry.

```ts
import { appendBlock, callout } from "@barkpark/bulldocs-sdk";
await client.submitOps("my-slug", [appendBlock(callout("warning", "Mind the rev."))], { ifRev: 1 });
```

## Error handling

Non-2xx responses with `{ error: { code, message? } }` throw `BulldocsError` (extends `Error`). Key on `err.code`, not `err.status`. Exit-code mapping: see `docs/cli/error-exit-table.md`.

Common codes: `invalid_paper`, `malformed_op`, `invalid_op`, `block_not_found`, `precondition_failed`, `not_found`.

## Build and test

```bash
npm run build   # tsc -> dist/
npm test        # tsc + node --test over dist/test
npm run example # mock-fetch demo: proves 2 requests total (1 publish + 1 batch-ops)
```
