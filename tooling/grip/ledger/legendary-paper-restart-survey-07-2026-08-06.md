<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-07 | budget: 1400tok -->
# Restart Survey 07 — public provenance and current pin

Assignment `restart-survey-07` re-attested `cloud-console-hardening-wave-28-2026-08-03::public` against restart wave `8a94f6db-1be6-4bbf-ba49-7f3aeed0e737`. Verdict: **current source and authored DOM identity reproduced across routes; public HTML is not revision-self-pinning**.

## Direct answer

The public reader resolves the published Paper source at revision `49c1534d9fb76d0d9adc7b97f25ec471`. Eight successful reader captures across flat, dataset, and scoped routes produced an identical authored `article#paper-body`: 237 unique block IDs in exact source order, article SHA-256 `44b8fb94a62c78697aa05ed96fbb58482981cc6c2673aa88bcb68a4e69098461`, and visible-text SHA-256 `0bc0fe37d665614ca899affc10a6d5d841ce2f9e5f98b3e9442703e48ce77a2e`.

The DOM exposes `data-rev="0"`, not the actual document revision, because the LiveView reads optional content field `rev` rather than `_rev`. Exact revision identity appears only in the separately fetched source. Public provenance is reproducible through a contemporaneous source-plus-DOM chain, but is neither self-contained nor atomically pinned.

## Current provenance chain

- Source: kind `blocks`, 237 blocks, response SHA-256 `34332ee5666902161af9abe4f96c8243374f93f1f143ba567d2d5bc2b51fba8b`.
- Canonical compact blocks SHA-256: `a9051f7ad1d7739ccaaca7e80f6d8079c7c78206b0cd723a8e29d0570c9e5d09`.
- Ordered source-ID SHA-256: `af67ad3cfd899b3d55414bd062f85f4f46997200bc95309f80dd28b0d83352ff`.
- Three source routes: 3/3 HTTP 200 and byte-identical.
- Reader: nine requests, eight HTTP 200 and one initial flat-route HTTP 500; successful distribution flat 2/3, dataset 3/3, scoped 3/3.
- Every successful article: 237 IDs/237 unique; zero missing/extra; exact source order; 140,418 bytes; 94,483 visible characters; 14,483 words; H1 ×1, H2 ×24, H3 ×18; one main and one article; language `en`.

Whole-page bytes vary because request-bound shell/LiveView material differs: flat 315,953 bytes, dataset 315,966, scoped 316,205. The authored article and normalized text are stable identities; raw response bytes are not.

## Found, partial, and risk

Found: exact source revision/count/hashes; route-equal source bytes; route-independent authored DOM/text; exact top-level identity and order; and the `data-rev="0"` contradiction. No route-specific authored drift, missing/extra/duplicate/reordered ID, actual `_rev` in HTML, or stable whole-page identity was found.

Atomic provenance is partial because source and reader are separate HTTP observations without a shared revision assertion. A concurrent publication can race the composed proof. Live task/value projections can also change reader bytes independently of Paper `_rev`. One reader 500 and a capability timeout contradict clean availability; their causes are unproven.

Browser layout, screenshots, AX/keyboard behavior, historical revisions, negative controls, regression thresholds, fine-grained per-block semantics, publication races, and failure root cause were outside this provenance lens.

## Cycle payload

```json
{"assignment_id":"restart-survey-07","unit":"cloud-console-hardening-wave-28-2026-08-03::public","paper_revision":"49c1534d9fb76d0d9adc7b97f25ec471","source":{"kind":"blocks","count":237,"response_sha256":"34332ee5666902161af9abe4f96c8243374f93f1f143ba567d2d5bc2b51fba8b","blocks_sha256":"a9051f7ad1d7739ccaaca7e80f6d8079c7c78206b0cd723a8e29d0570c9e5d09","ordered_ids_sha256":"af67ad3cfd899b3d55414bd062f85f4f46997200bc95309f80dd28b0d83352ff","routes_equal":true},"reader_samples":{"total":9,"http_200":8,"http_500":1,"flat":"2/3","dataset":"3/3","scoped":"3/3"},"article":{"data_rev":"0","block_ids":237,"unique_ids":237,"source_order_equal":true,"missing":0,"extra":0,"bytes":140418,"sha256":"44b8fb94a62c78697aa05ed96fbb58482981cc6c2673aa88bcb68a4e69098461","text_sha256":"0bc0fe37d665614ca899affc10a6d5d841ce2f9e5f98b3e9442703e48ce77a2e"},"whole_page_stable":false,"self_identifying_revision":false,"verdict":"current source and authored DOM identity reproduced across routes; public HTML is not revision-self-pinning"}
```
