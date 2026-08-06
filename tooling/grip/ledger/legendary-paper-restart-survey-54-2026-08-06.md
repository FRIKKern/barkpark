<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-54 | budget: 1400tok -->
# Restart Survey 54 — PDS45 public negative capability

Assignment `restart-survey-54` challenged `pds-wave-45-2026-08-03::public` at exact revision `b992fd8aaa028b0dab30a8da76f077fd`. Verdict: **partial**. Exact public block order is proven; revision binding, negotiation taxonomy, cache validation, and structural accessibility are contradicted or incomplete.

Anonymous flat, dataset, and shared-scoped readers returned 200. Flat DOM contained 227 unique block wrappers in exact source order, including 124 empty paragraph carriers. Correct, incorrect, and alternate revision queries returned identical block/text hashes; the article contains neither pinned revision nor content-revision header. Published/drafts/raw/invalid perspectives were identical because anonymous reads intentionally clamp to published; authorized draft/raw behavior remains blocked.

HTML and `*/*` succeed; JSON, plain text, and XHTML return 406 JSON mislabeled `internal_error`. Missing/path-like slugs and unsupported methods return generic HTML 404 without `Allow`; HEAD returns 200. Flat/dataset declare private must-revalidate without validators. Scoped emits an ETag, but matching `If-None-Match` still returns 200/full body.

Fresh DOM has `lang=en`, main/article, correct heading/list structure, but 12/12 data tables are presentation-only, nine headers lack scope, nine callouts lack roles, authored strong is absent, and the article is unnamed. Sanitization and ambiguous-source fail-closed behavior have static/test support only; no hostile Paper was injected and tests did not run. Connected recovery, authorized drafts, live sanitization, browser AX/AT, keyboard, zoom, and cross-browser behavior remain unvisited. No mutation occurred.

## Cycle payload

```json
{"assignment_id":"restart-survey-54","unit":"pds-wave-45-2026-08-03::public","verdict":"partial","paper_rev":"b992fd8aaa028b0dab30a8da76f077fd","claims":{"public_projection":"proven","revision_binding":"contradicted","anonymous_perspective_clamp":"proven","authorized_draft_raw":"blocked","accept_taxonomy":"contradicted","missing_method_taxonomy":"partial","cache_validation":"contradicted","heading_list_semantics":"proven","table_callout_emphasis_semantics":"contradicted","sanitization":"partial_static_only","connected_recovery":"blocked"},"projection":{"blocks":"227/227 ordered","empty_carriers":124,"source_bytes":91515,"source_sha256":"e19503ef0f854680056c1857d2d9647dbfdafb2a172e7cabc75d67652f1514e8"},"identity":{"revision_queries_ignored":true,"dom_revision":false,"scoped_etag_304":false},"semantics":{"lang":true,"main_article":true,"headings":"1/23/9","lists":"7/44","presentation_tables":"12/12","scoped_headers":"0/9","semantic_callouts":"0/9","strong":0},"tests_run":0,"mutations":0}
```
