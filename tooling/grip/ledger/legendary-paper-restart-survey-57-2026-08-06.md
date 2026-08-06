<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-57 | budget: 1400tok -->
# Restart Survey 57 — PDS45 Studio negative capability

Assignment `restart-survey-57` challenged `pds-wave-45-2026-08-03::studio` at exact revision `b992fd8aaa028b0dab30a8da76f077fd`. Verdict: **blocked, with fresh negative findings**.

Anonymous, invalid-bearer, and service-bearer canonical requests all redirect to login; a service token is not a browser session. Valid/missing/malformed Papers, valid/dead revisions, and published/drafts/raw/invalid perspectives are masked by authentication. JSON/plain Accept returns 406 `internal_error`; `*/*` redirects normally. Missing workspace returns typed 404, while missing project/dataset redirects, creating a possible pre-auth scope-taxonomy leak that still needs enumeration proof.

Exact source has 227 blocks/SHA `f01937cb…9da`. Production conversion preserves count/order and zero untouched operations, yet three legacy-header tables produce zero header nodes and eight marked paragraphs flatten. A pure malformed-source matrix is permissive: null lists empty, null/missing IDs mint synthetic IDs/operations, malformed paragraph content becomes `[object Object]`, malformed tables normalize to an empty cell, and unknown opaque payloads survive. Canvas JSON parse failure silently retains an empty seed without a visible error. None proves DOM exploitability or persistence.

Runtime roles/session/grant expiry, authenticated missing-Paper behavior, revision/perspective switching, reconnect/cache, controls, keyboard/AX, and malformed mounting remain blocked. Static authorization layers were inspected but not proxy-passed. No test or mutation ran.

## Cycle payload

```json
{"assignment_id":"restart-survey-57","unit":"pds-wave-45-2026-08-03::studio","paper_rev":"b992fd8aaa028b0dab30a8da76f077fd","verdict":"blocked","fresh":{"source_blocks":227,"projection_blocks":227,"order_preserved":true,"untouched_ops":0,"lost_legacy_header_tables":3,"flattened_marked_blocks":8},"negative_findings":["permissive malformed-source normalization","silent empty seed on JSON parse failure","unsupported Accept classified internal_error","pre-auth scope taxonomy divergence"],"blocked":["authenticated roles/session expiry","runtime perspective/revision","connectivity/cache","controls/keyboard/AX","malformed DOM mount"],"tests_run":0,"mutations":0}
```
