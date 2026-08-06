<!-- doc-tier: cold | canonical-for: legendary-paper-restart-verify-01 | budget: 1600tok -->
# Restart Verify 01 — public/email revision identity

Assignment `restart-verify-01` tested whether every public and email response intrinsically identifies its exact immutable Paper revision and ordered projection. Verdict: **refuted, strict pass 0/8**.

All four frozen Papers were fetched twice through public and email readers. All 16 reader requests returned `200` and echoed the caller's synthetic request ID. Public HTML preserved the exact canonical `data-block-id` order for 815/815 blocks, but none of the eight surface cells exposed the document `_rev`, released-history UUID, `ETag`, `Digest`, `Last-Modified`, `Content-Location`, or `X-Barkpark-Paper-Revision`. Public `data-rev="0"` is derived from mutable `content["rev"] || 0`; it is not the document revision.

Email returned stable bodies across immediate repeats for 4/4 Papers, but exposed 0/815 block-ID carriers and no published mapping between a body digest and document/history identity. A verifier-computed body hash therefore cannot become an intrinsic response validator. Public whole-body hashes were also unstable because request/session bytes changed between repeats.

| Paper | Document `_rev` | Released history UUID | Blocks | Public ordered IDs |
|---|---|---|---:|---:|
| CCH29 | `18768b0a14c2eead927181c4a0e37c18` | `eed97c1b-e395-40ef-aee5-be408329ec81` | 252 | 252/252 |
| CCH28 | `49c1534d9fb76d0d9adc7b97f25ec471` | `7c1135de-733c-4325-aea6-31b9dbbda4d1` | 237 | 237/237 |
| PDS45 | `b992fd8aaa028b0dab30a8da76f077fd` | `4afe0099-26af-40eb-8943-f6935c16c29d` | 227 | 227/227 |
| PDS44 | `8bbd5d874a1b697f1e4e437c473f8e52` | `344fe5ee-c8a0-4bb9-8b5e-17a3562992d5` | 99 | 99/99 |

The code path confirms the boundary. `bulldocs.ex` mounts flat public/source/email routes through `:public_root`; `bulldocs_live.ex` emits ordered public block wrappers but its displayed revision is the mutable content field; `bulldocs_email_controller.ex` adds no revision/digest carrier; `portable_doc/render.ex` concatenates email blocks without ID wrappers. `paper_revision_headers.ex` can stamp scoped HTML with a content digest and released-history UUID, but does not match the flat public/email routes tested here and does not expose document `_rev`.

This proves current public projection order, not immutable response identity. Delivered MIME/provider copies remain outside scope and cannot be inferred from the HTTP preview.

## Cycle payload

```json
{"assignment_id":"restart-verify-01","cycle_uuid":"591d1beb-30a2-43e7-9328-4cf28158663b","verdict":"refuted","strict_pass":"0/8","samples":{"source":"4/4_200","public":"8/8_200","email":"8/8_200","request_id_echo":"20/20"},"identity":{"document_rev":"0/8","released_history_uuid":"0/8","revision_bound_validator":"0/8"},"projection":{"public_ordered_block_ids":"815/815","email_block_ids":"0/815"},"distinction":"document _rev and released history UUID are separate identities","mutations":0}
```
