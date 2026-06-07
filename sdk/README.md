# `@barkpark/bulldocs-sdk`

Thin TypeScript authoring SDK for **Barkpark Bulldocs** papers — typed block
constructors, typed block-ops, a `Paper` builder, and a tiny ingest client that
publishes a paper and submits a batch of ops in single requests.

Field names are not invented: every block/op shape mirrors exactly what the
server reads (`Barkpark.PortableDoc.Render` and `Barkpark.PortableDoc.Patch`).
The SDK is a thin layer over the same `/v1/plugins/bulldocs/*` ingest endpoints
the `bp bulldocs` CLI verbs hit.

---

## Install

The package is ESM (`"type": "module"`) and ships compiled JS under `dist/src`.

```bash
npm install @barkpark/bulldocs-sdk
```

Requires a global `fetch` (Node 22+), or pass your own `fetch` to the client.

```ts
import {
  paper,
  heading,
  ingress,
  paragraph,
  diagram,
  callout,
  appendBlock,
  patchBlock,
  moveBlock,
  BulldocsClient,
  BulldocsError,
} from "@barkpark/bulldocs-sdk";
```

---

## Author a paper with block constructors

`paper(slug, opts?)` returns a chainable `Paper` builder. `.add(...blocks)`
appends blocks in order; `.toJSON()` produces the exact publish body the ingest
endpoint accepts (`{ slug, blocks, title?, style? }`).

Each block constructor mints a deterministic `id` (`b1`, `b2`, …) when you omit
one — no `Date.now()`/random, so output is byte-reproducible. Pass an explicit
id as the last argument to pin it.

```ts
import { paper, heading, ingress, paragraph, diagram } from "@barkpark/bulldocs-sdk";

const doc = paper("2026-06-07-demo", { title: "SDK Demo", style: "article" }).add(
  heading(1, "The Bulldocs SDK"),
  ingress("A thin authoring layer over native PortableDoc blocks."),
  paragraph("This entire paper was constructed in TypeScript."),
  diagram("graph TD; A[author] --> B[publish]; B --> C[/papers/:slug]", "Figure 1. The flow."),
);
```

### Block constructors

All return a typed `Block` with an auto-minted `id`. `content` accepts a plain
string (the common case) or an array of inline nodes.

| Constructor | Shape produced |
|---|---|
| `heading(level, text, id?)` | `{ type:"heading", level, text }` — level is `1\|2\|3` |
| `paragraph(content, id?)` | `{ type:"paragraph", content }` |
| `ingress(content, id?)` | `{ type:"ingress", content }` |
| `pullquote(content, id?)` | `{ type:"pullquote", content }` |
| `eyebrow(text, id?)` | `{ type:"eyebrow", text }` |
| `byline(items, id?)` | `{ type:"byline", items }` |
| `list(items, { ordered? }?, id?)` | `{ type:"list", ordered, items }` |
| `callout(tone, content, { title? }?, id?)` | `{ type:"callout", tone, content, title? }` — tone is `info\|success\|warning\|danger\|note` |
| `action(href, label, { priority? }?, id?)` | `{ type:"action", href, label, priority? }` |
| `code(value, id?)` | `{ type:"code", value }` (renderer reads `value`, not `lang`/`code`) |
| `diagram(source, caption?, id?)` | `{ type:"diagram", source, caption? }` (renderer reads `source`, not `mermaid`) |
| `asciicast(src, caption?, id?)` | `{ type:"asciicast", src, caption? }` |
| `image(src, alt, { width?, height? }?, id?)` | `{ type:"image", src, alt, width?, height? }` |
| `table(rows, { head? }?, id?)` | `{ type:"table", rows, head? }` |
| `divider(id?)` | `{ type:"divider" }` |
| `section(title, blocks, id?)` | `{ type:"section", title?, blocks }` |

`resetBlockIds()` and `nextBlockId()` are exported for tests that need
reproducible ids.

---

## Publish

`BulldocsClient` is the HTTP layer over the ingest endpoints. The token rides as
a `Bearer` header (the `ingest`-tier credential, behind the server's
`RequireIngestToken` plug). `publish(paper)` sends the whole paper in **one**
POST and returns a typed receipt.

```ts
import { BulldocsClient } from "@barkpark/bulldocs-sdk";

const client = new BulldocsClient({
  baseURL: "http://localhost:4000",
  ingestToken: process.env.BARKPARK_INGEST_TOKEN!,
  // fetch: customFetch,   // optional; defaults to global fetch
});

const receipt = await client.publish(doc);
// PublishReceipt: { ok, slug, rev, liveview_path }
console.log(receipt.liveview_path); // -> /papers/2026-06-07-demo
```

---

## Submit a batch of ops in one call

`submitOps(slug, ops, opts?)` sends `N` block-ops as the batch shape
`{ ops: [...], ifRev? }` in **one** request; the server applies them atomically.
`ifRev` is an optional optimistic-concurrency guard — a mismatch rejects the
whole batch with a `precondition_failed` error.

Op constructors mirror `Barkpark.PortableDoc.Patch` exactly; the discriminator
key is the hyphenated `op` string.

```ts
import { appendBlock, patchBlock, moveBlock, callout } from "@barkpark/bulldocs-sdk";

const ops = [
  appendBlock(callout("warning", "Mind the rev.", { title: "Heads up" })),
  patchBlock("b3", { content: ["Revised body text."] }),
  moveBlock("b4", { after: "b1" }),
];

const opsReceipt = await client.submitOps("2026-06-07-demo", ops, { ifRev: 1 });
// SubmitOpsReceipt: { ok, slug, op_count, rev, block_ids }
console.log(`applied ${opsReceipt.op_count} ops -> rev ${opsReceipt.rev}`);
```

### Op constructors

| Constructor | Shape produced |
|---|---|
| `appendBlock(block)` | `{ op:"append-block", block }` |
| `insertAfter(afterId, block)` | `{ op:"insert-after", afterId, block }` |
| `patchBlock(id, patch)` | `{ op:"patch-block", id, patch }` (shallow-merge; `id`+`type` immutable) |
| `replaceBlock(id, block)` | `{ op:"replace-block", id, block }` |
| `removeBlock(id)` | `{ op:"remove-block", id }` |
| `moveBlock(id, { after? })` | `{ op:"move-block", id, after }` — `after: null` (default) moves to head |

---

## Errors — the typed `BulldocsError`

A non-2xx response carrying `{ error: { code, message? } }` is thrown as a
`BulldocsError`. It extends `Error` and carries the contract `code`, the HTTP
`status`, and the parsed `body`. The `code` is the stable contract string — key
your handling on it, not the HTTP status.

```ts
import { BulldocsError } from "@barkpark/bulldocs-sdk";

try {
  await client.submitOps("2026-06-07-demo", ops, { ifRev: 1 });
} catch (err) {
  if (err instanceof BulldocsError) {
    console.error(`bulldocs ${err.code} (HTTP ${err.status}): ${err.message}`);
    if (err.code === "precondition_failed") {
      // re-fetch the current rev and retry the batch
    }
  } else {
    throw err;
  }
}
```

Codes you will see from these endpoints include `invalid_paper`, `malformed_op`,
`invalid_op`, `block_not_found`, `precondition_failed`, and `not_found` — the
same contract codes the `bp` CLI maps to its exit codes (see
`docs/cli/error-exit-table.md`).

---

## Runnable example

A no-server demo lives at `examples/author-and-submit.ts`. It uses an injected
mock `fetch` to prove publish + batch-ops each issue exactly one request:

```bash
npm run example
# builds the SDK, runs dist/examples/author-and-submit.js, prints both request
# bodies and "TOTAL requests issued: 2 (1 publish + 1 batch-ops)"
```

Build and test:

```bash
npm run build   # tsc -> dist/
npm test        # tsc + node --test over dist/test
```
