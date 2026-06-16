/**
 * Barkpark cache-tag scheme — mirrors the webhook wire contract
 * (`docs/contracts/webhook-realtime.md`). Three tags per touched document:
 *
 *   bp:ds:<dataset>:_all          — any read of the dataset
 *   bp:ds:<dataset>:doc:<id>      — one published document id
 *   bp:ds:<dataset>:type:<type>   — all documents of a type
 *
 * Tagging reader/finder caches with these means a published change in Studio
 * → Phoenix `Webhooks.Dispatcher` → our `/api/barkpark/webhook` →
 * `revalidateTag(...)` busts exactly the affected caches. The dispatcher emits
 * the doc/type tags (scoped + flat); `_all` is reconstructed handler-side.
 */

import { DATASET } from "./config";

// Re-exported so existing `import { DATASET } from "@/lib/bp-tags"` call sites
// keep working while the literal lives in ONE place (lib/config.ts).
export { DATASET };

export const bpAll = (dataset: string = DATASET): string =>
  `bp:ds:${dataset}:_all`;

export const bpType = (type: string, dataset: string = DATASET): string =>
  `bp:ds:${dataset}:type:${type}`;

export const bpDoc = (docId: string, dataset: string = DATASET): string =>
  `bp:ds:${dataset}:doc:${docId}`;
