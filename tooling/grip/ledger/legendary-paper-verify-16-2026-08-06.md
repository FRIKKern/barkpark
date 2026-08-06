<!-- doc-tier: cold | canonical-for: legendary-paper-verify-16-evidence | budget: 1800tok -->
# Verify 16 — six-surface CLI/API block preservation

Verdict: `proven`. All 24 comparisons preserve exact block order, type, ID, and content across CLI get/query, canonical API get/query, flat public source, and newest history detail for all four pinned Papers.

```text
comparisons=24 passed=24 all_blocks_exact=true
all_broad_docs_exact=true all_current_revs_pinned=true
```

| Paper | Blocks | Canonical block-array SHA-256 | Ordered IDs SHA-256 | Ordered content SHA-256 |
| --- | ---: | --- | --- | --- |
| Cloud Console wave 29 | 252 | `46ed01f7…b1a50` | `89434648…fc3c5` | `7d9388e2…b445d` |
| PDS wave 45 | 227 | `f01937cb…29da` | `143dac06…9ad7` | `64aae296…651a3` |
| Cloud Console wave 28 | 237 | `a9051f7d…e5d09` | `af67ad3c…352ff` | `04b1185e…4e087` |
| PDS wave 44 | 99 | `a89dd730…445cd` | `e88adb73…1767b` | `f04e92fc…13314` |

- Current document `_rev` values exactly match every frozen pin. All IDs are nonblank and unique. Per Paper, the six surfaces produce one block, ordered-ID, ordered-type, and ordered-content hash.
- CLI/API get/query documents are exact object-equal after normal envelope unwrapping. Broad documents and newest history snapshots have `body.blocks == blocks`.
- Newest history entries are published `publish` snapshots: `eed97c1b…`, `4afe0099…`, `7c1135de…`, and `344fe5ee…`. Their stored-content projections equal current content after removing reserved live-document identity keys and outer title.
- Supplementary `fields=title,blocks` probes pass across CLI/API get/query and retain exactly the seven reserved fields plus title and blocks.

Expected projection differences are not loss:

- API get/query wrap `result` with etag, timing, schema hash, and sync tags.
- CLI get unwraps result; CLI query exposes documents/count/limit/offset/perspective.
- Public source narrows deliberately to id/title/_rev/source kind/blocks.
- History puts UUID, document identity, action, status, timestamp, and title outside stored content.

No missing, reordered, duplicated, type-changed, or normalized block was found. Public source unexpectedly returns 406 for explicit `Accept: application/json` but 200 for `Accept: */*`; the Go client sends no explicit Accept and succeeds. One API query returned transient 500 and passed on retry. History UUID and document `_rev` remain separate domains; content equality does not provide an explicit identity join.

Focused API-client tests pass. Live deployed reads provide the decisive evidence because Elixir test dependencies are absent. Evidence lives under `/private/tmp/bp-verify16/`. Scope excludes older history, drafts/raw, weaker-principal redaction, and `_rev`↔history UUID mapping. No repository or Barkpark mutation occurred at commit `36422119ca11`.
