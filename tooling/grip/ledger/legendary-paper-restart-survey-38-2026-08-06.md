<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-38 | budget: 1400tok -->
# Restart Survey 38 — PDS44 public live regression and frozen gates

Assignment `restart-survey-38` re-attested `pds-wave-44-2026-08-03::public` at exact Paper revision `8bbd5d874a1b697f1e4e437c473f8e52`. Verdict: **unchanged partial failure, high confidence**. Content parity, structure, route availability, focus visibility, desktop containment, and 390px containment reproduce; 320px overflow, document length, semantics, revision identity, cache behavior, and error taxonomy remain failed.

## Frozen-gate result

Hash boundaries are intentionally distinct: raw source response SHA-256 is `9d63b5e3f844718cb9eccb70507a63c9b2d169d90f558aab18d74344ea80b8d7`; this audit's canonical whole-document JSON hash is `2c0b65b64ad255a7645a94dd9ad2fed3b38d54bb93709b28efc52011fdfb6d6b`; its canonical block projection hash is `a89dd730f1697b0ce25b86ace3f88d790ef6b13e24e5519d58b3ded2c09445cd`; and its browser-serialized extracted article hash is `18bcd8aedf634df01df9114f4a7b27d25470ad40a28834b6d204618bb09c2b8a`. These are not interchangeable with Survey 37's raw-machine, canonical-array, raw-article, or Nokogiri-normalized hashes.

Source passed `3/3`; public routes passed `8/8`; extracted article bytes were stable `8/8`. Article/source parity is 99/99 block IDs in exact order and 99/99 normalized block texts. Structure: H1/H2/H3 `1/24/7`, 33 visible paragraphs plus 15 empty keyed wrappers, ten lists/85 items, five tables/12 headers/54 rows/203 cells, and four callouts. Source contains no authored marks, so mark survival is dormant rather than passed.

Fresh geometry:

- 1440×1000: 640px content, 29,937px document, no horizontal overflow.
- 390×844: 310px content, 51,107px document, no page overflow.
- 320×568: 240px content, 62,827px document, 462px scroll width, **142px page overflow**.

All five narrow tables are internally scrollable. Fixed view controls occupy 75px vertically. Focus visibility passed `2/2` desktop and `7/7` narrow targets, but there are no content links, outline, section jumps, or back-to-top target.

Semantics remain unsafe: 5/5 data tables declare `role=presentation`, 0/12 headers have `scope`, 0/4 callouts have role/label, and the article lacks an accessible name. Chromium's narrow-width AX exposure is only a browser proxy; real AT remains unvisited and is not passed. The DOM shows `data-rev="0"`, not Paper `_rev`.

No ETag or Last-Modified was observed on the sampled routes; conditional requests returned `0/2` 304. Width/theme parameters were ignored. Non-HTML Accept returned `2/2` 406 mislabeled `internal_error`; missing/draft slugs returned correct 404; OPTIONS/TRACE returned misleading document-not-found 404s. Four Mix files and one Node test executed zero tests/assertions because dependencies were absent. No state changed.

## Cycle payload

```json
{"assignment_id":"restart-survey-38","unit":"pds-wave-44-2026-08-03::public","verdict":"partial_unchanged_failure","confidence":"high","paper":{"revision":"8bbd5d874a1b697f1e4e437c473f8e52","canonical_document_sha256":"2c0b65b64ad255a7645a94dd9ad2fed3b38d54bb93709b28efc52011fdfb6d6b","raw_source_sha256":"9d63b5e3f844718cb9eccb70507a63c9b2d169d90f558aab18d74344ea80b8d7","canonical_block_projection_sha256":"a89dd730f1697b0ce25b86ace3f88d790ef6b13e24e5519d58b3ded2c09445cd"},"public":{"routes":"8/8 200","serialized_article_sha256":"18bcd8aedf634df01df9114f4a7b27d25470ad40a28834b6d204618bb09c2b8a","block_ids":"99/99 ordered","block_texts":"99/99"},"geometry":{"desktop":"pass","390":"pass","320_overflow_px":142},"semantics":{"data_tables":"0/5","scoped_headers":"0/12","labelled_callouts":"0/4","real_at":"unvisited"},"keyboard":{"desktop":"2/2","narrow":"7/7"},"cache":{"conditional_304":"0/2"},"errors":{"accept_taxonomy":"0/2","unsupported_method_taxonomy":"0/2"},"tests":{"executed":0},"mutations":0}
```
