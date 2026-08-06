<!-- doc-tier: cold | canonical-for: legendary-paper-restart-verify-03 | budget: 1600tok -->
# Restart Verify 03 — reader cache validators

Assignment `restart-verify-03` tested whether supported public/email routes publish revision-bound validators and honor conditional reads. Verdict: **refuted**.

All 24 supported reader cells returned `200` for baseline GET and HEAD. Scoped public exposed a content-digest `ETag` plus released-history UUID for 4/4 Papers; flat public, dataset public, and every email route exposed neither `ETag` nor `Last-Modified` in 20/24 cells. No reader route returned `304` for an exact `If-None-Match`: all 24 returned `200` with full current bodies, including the four scoped-public cells whose published ETag was replayed verbatim. Stale ETags returned `200` in 24/24 cells, while future `If-Modified-Since` also returned `200` in 24/24 because no reader publishes or evaluates `Last-Modified`.

The document API control proves conditional handling is available in the stack. Its four ETags exactly matched the frozen document `_rev`; exact `If-None-Match` returned `304` with zero bytes in 4/4 controls, and stale validators returned `200` with current content in 4/4.

The implementation matches the observed boundary. `PaperRevisionHeaders` stamps scoped-public responses with digest/release identity but performs no request-condition comparison. `BulldocsEmailController` sends HTML directly without validators or conditional logic. `QueryController` explicitly compares `If-None-Match` and issues the working document-control `304`.

Therefore the scoped-public ETag is content-bound metadata but nonfunctional as an HTTP cache validator, and validator policy is not route-equivalent. The current/stale path passes narrowly, but it cannot compensate for absent validators or the missing exact-match short circuit. Public request-scoped bytes limit raw-body stability claims; real delivered email remains outside this HTTP-reader verification. Neither limitation affects the refutation.

## Cycle payload

```json
{"assignment_id":"restart-verify-03","uuid":"714aba1c-03c8-4f2b-8f96-72d7bc32ea08","verdict":"refuted","supported_cells":24,"baseline_get_200":24,"baseline_head_200":24,"validator_cells":4,"missing_validator_cells":20,"exact_304_empty":0,"exact_200_full":24,"stale_200":24,"ims_future_200":24,"route_equivalent":false,"document_controls":{"cells":4,"etag_equals_document_rev":4,"exact_304_empty":4,"stale_200":4},"mutations":0}
```
