<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-52 | budget: 1400tok -->
# Restart Survey 52 — PDS45 public provenance

Assignment `restart-survey-52` re-attested `pds-wave-45-2026-08-03::public` at revision `b992fd8aaa028b0dab30a8da76f077fd`. Verdict: **found with partial revision identity**. Current source-to-public content parity is exact; the article cannot independently name its document revision.

Machine document samples were 3/3 identical (392,184 bytes, SHA `5894db69…aa7`); nine flat/dataset/scoped source reads were identical (91,515 bytes, SHA `e19503ef…1e8`). Document, source, and newest immutable history revision `4afe0099-26af-40eb-8943-f6935c16c29d` share the exact 227-block SHA `f01937cb…9da`.

Nine valid public renders returned 200. Their extracted articles were identical: 105,430 bytes/SHA `aa005781…f15`, 227/227 ordered block carriers, 536/536 authored fragments, zero missing characters, headings `1/23/9`, seven lists/44 items, 12 tables, and nine callouts. The scoped-dataset reader was 3/3 404 although its source route succeeds.

The article exposes only LiveView `data-rev=0`, not `_rev` or the released UUID. Scoped public alone emits an ETag and `X-Barkpark-Paper-Revision`; flat/dataset/source routes do not. A matching scoped ETag returns 200/full body, while document API conditional reads correctly return 304. Theme remains dynamic; task/query/link resolvers are dormant. Connected state, concurrent publication, mobile, keyboard, browser AX, and real AT remain unvisited. No mutation or test ran.

## Cycle payload

```json
{"assignment_id":"restart-survey-52","unit":"pds-wave-45-2026-08-03::public","verdict":"found_with_partial_revision_identity","confidence":"high","paper":{"rev":"b992fd8aaa028b0dab30a8da76f077fd","blocks":227,"document_samples":"3/3","document_sha256":"5894db69f3d9ddc0416bd5e5e6b50dc72c1d962efb56ac7fd863b1a8d1caa7","source_samples":"9/9","source_sha256":"e19503ef0f854680056c1857d2d9647dbfdafb2a172e7cabc75d67652f1514e8","blocks_sha256":"f01937cbc0c28fc4f381136ba1ec8174591b1d60abc7b99454aaefd8a7f829da","released_revision":"4afe0099-26af-40eb-8943-f6935c16c29d"},"public":{"valid_routes":"9/9","article_bytes":105430,"article_sha256":"aa0057810e756e63164cd87cf2fb8c2661382a867fab60d780bac95a8baeaf15","block_ids":"227/227 ordered","text_fragments":"536/536","missing_chars":0,"data_rev":"0","document_rev_visible":false},"identity":{"scoped_revision_header":true,"flat_dataset_headers":false,"page_conditional_304":false,"api_conditional_304":true},"route_ambiguity":{"scoped_dataset_status":404},"dynamic":{"theme":"iris","task_query_link_resolvers":"dormant"},"connected_browser":"unvisited","mutations":0,"tests_run":0}
```
