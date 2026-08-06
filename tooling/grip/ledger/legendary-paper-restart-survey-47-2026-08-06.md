<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-47 | budget: 1400tok -->
# Restart Survey 47 — PDS45 CLI/API live regression and frozen gates

Assignment `restart-survey-47` re-attested `pds-wave-45-2026-08-03::cli_api` at exact revision `b992fd8aaa028b0dab30a8da76f077fd`. Verdict: **machine content, structure, route parity, schema, revision, and width gates remain stable; newest-history replay improved from unvisited to proven; human semantic/identity failures remain**.

Public source, raw document, and history each passed `3/3` stable sampling. Source is 91,515 bytes/SHA `e19503ef…14e8`; raw normalized document is SHA `5894db69…aa7`; ten-record history is SHA `a81f7740…2a3b`. Flat/scoped source are byte-identical; flat/scoped raw, query, Paper JSON, and doc get retain the same 227 blocks and revision.

Structure remains exact: 166 paragraphs, 33 headings (1/23/9), 12 tables, nine callouts, seven lists/44 items; 227/227 unique IDs; 124 exact-empty paragraphs; eight mark records/161 characters. Canonical blocks hash to `5c9e77f2…c673`. Newest history UUID `4afe0099…c29d` replays to the exact current block hash—new proof versus Round 1.

Human widths 20/40/60/80/120 remain bounded with 7,952/3,272/2,066/1,537/1,040 lines. Width 80 passed `3/3`, SHA `1c9c67b7…0746`. Density remains failed. Three tables carry nine headers; terminal preserves `0/9`. Visible slug/revision is `0/5` captures; NoColor H2/H3 remain indistinguishable.

Error classes are stable but inconsistent: missing Paper/doc return structured rc4; slug@revision rc4; invalid perspective/width emit human rc2 despite JSON mode; missing source returns plain 404 without Content-Type while missing raw doc is typed JSON. Paper schema v1 exposes seven fields; separate envelope/schema hashes are different identity domains. No state changed.

## Cycle payload

```json
{"assignment_id":"restart-survey-47","unit":"pds-wave-45-2026-08-03::cli_api","verdict":"partial stable machine gates; history replay improved; human failures unchanged","paper":{"rev":"b992fd8aaa028b0dab30a8da76f077fd","blocks":"227/227","canonical_blocks_sha256":"5c9e77f2af56751516862425db7abfbfadc924cb9c5e8aab770cda67e9acc673"},"routes":{"source":"2/2 equal","document":"5/5 equal"},"history":{"count":10,"newest_equal":true,"classification":"improved_proof"},"human":{"width_lines":{"20":7952,"40":3272,"60":2066,"80":1537,"120":1040},"overflow":0,"headers":"0/9","visible_identity":false,"density":"fail"},"errors":{"missing":"typed_rc4","parse_json_mode":"human_rc2","source_missing":"plain_404","doc_missing":"json_404"},"mutations":0}
```
