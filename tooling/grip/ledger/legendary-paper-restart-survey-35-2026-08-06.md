<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-35 | budget: 1400tok -->
# Restart Survey 35 — PDS44 email live regression and frozen gates

Assignment `restart-survey-35` re-attested `pds-wave-44-2026-08-03::email` at exact revision `8bbd5d874a1b697f1e4e437c473f8e52`. Verdict: **unchanged partial failure, high confidence**.

Eight preview reads passed identically: HTTP 200, 98,335 bytes, SHA-256 `c46f46e5172fa878f0a2ae8216cf75e4bfb265dc7cec350691d7e5dca2957645`. Three source reads matched the exact revision and 76,255-byte hash. All 369 authored text leaves and 84 non-empty visible structures survived in order; 15 empty paragraphs compacted away. DOM census: H1/H2/H3 1/24/7, 33 paragraphs, ten lists/85 items, five tables, 12 TH, 54 body rows/203 TD, and four callouts.

Desktop containment passed at 1440×900. Actual 390px and 320px CSS viewports failed: document width stayed 611px, overflowing by 221px and 291px; table containment was `0/10`. Mobile emulation appeared contained only because missing viewport metadata created an effective 980px layout viewport, so it is not narrow-client proof.

Semantics remain failed: all five data tables use `role=presentation`; `0/12` TH have scope; `0/4` callouts have role/label; no lang, landmark, block IDs, or visible revision identity exists. Cache provenance fails: no ETag/Last-Modified and conditional controls returned `0/2` 304. `?width=320` and `?theme=dark` are ignored; text/plain Accept returns 406 `internal_error`; OPTIONS/TRACE return mislabeled 404s.

Four selected Elixir test files executed zero tests because Mix dependencies were absent. HTTP preview is proven, while MIME assembly, SMTP, Gmail, Outlook, and Apple Mail remain unvisited. A 5,269-task snapshot found 11 indirect references and no dedicated title match. No email was sent and no state changed.

## Cycle payload

```json
{"assignment_id":"restart-survey-35","unit":"pds-wave-44-2026-08-03::email","verdict":"partial_unchanged_failure","preview":{"samples":"8/8","bytes":98335,"sha256":"c46f46e5172fa878f0a2ae8216cf75e4bfb265dc7cec350691d7e5dca2957645"},"source":{"samples":"3/3","text_leaves":"369/369"},"geometry":{"desktop":"1/1","narrow":"0/2","tables":"0/10","mobile_emulation_valid":false},"semantics":{"data_tables":"0/5","scoped_headers":"0/12","labelled_callouts":"0/4"},"cache":{"etag":false,"last_modified":false,"conditional_304":"0/2"},"tests":{"selected":4,"executed":0},"delivery":{"mime":false,"smtp":false,"real_clients":false},"mutations":0}
```
