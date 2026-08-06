<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-37 | budget: 1400tok -->
# Restart Survey 37 — PDS44 public provenance and current pin

Assignment `restart-survey-37` re-attested `pds-wave-44-2026-08-03::public` at exact Paper revision `8bbd5d874a1b697f1e4e437c473f8e52`. Verdict: **source-to-public article identity, block carriers, route parity, and current released-content identity are proven; exact Paper `_rev` self-identification and conditional caching are not**.

## Proven identity

Hash names below deliberately identify different byte/canonicalization boundaries:

- Raw `bp paper view -o json` output: `3/3`, 328,256 bytes, SHA-256 `4923e1b72da37c384ebc3f7b80ba15a08c9998fde560db0095d349a27457f96d`.
- Raw published source response: flat/dataset/scoped `3/3` byte-identical, 76,255 bytes, SHA-256 `9d63b5e3f844718cb9eccb70507a63c9b2d169d90f558aab18d74344ea80b8d7`.
- Canonical current 99-block array: SHA-256 `1c10ec4984826b0b12a0111c64b57bfc2c79de3ae576dd40b74e83c9e183bfce`; ordered block IDs hash to `1b0a3bf27f0ef9f06046c083109a724ba04595e6b8c1d8b39f542f33de604b58`.
- Raw extracted `article#paper-body`: 82,330 bytes, SHA-256 `34daeb6637255bc76d0126c4bc0d775676468614fc8291961a42c632f2a30739`.
- Nokogiri-normalized article: 81,863 bytes, SHA-256 `1d30a9b06b9b55a603e5a8a519a9bb7a8dd8af7e887b5222f60085790ccc114c`.

Nine flat/dataset/scoped public dead renders returned HTTP 200. All nine whole-page hashes differed because route/session/CSP wrapper bytes vary, while normalized article and `main.bp-paper-shell` hashes were stable across routes. The article carries 99/99 unique block IDs in exact source order and all 369 authored text leaves sequentially. Structure remains exact: H1/H2/H3 `1/24/7`, 33 visible paragraphs plus 15 keyed empty wrappers, ten lists/85 items, five tables/54 body rows/12 headers/203 cells, and four callouts.

## Revision and dynamic boundary

The public DOM contains zero exact `_rev` occurrences. `data-rev="0"` is not the Paper revision: it reads optional content `rev`, not document `_rev`. Flat and dataset routes expose neither content ETag nor released-revision header. The scoped route stably exposes content ETag `sha256:12d846d529b8b5e7d3534627741b73137501d6ab79a076992bc665a8d8147676` and released revision `344fe5ee-c8a0-4bb9-8b5e-17a3562992d5`; that release's canonical blocks equal current source blocks. A matching `If-None-Match` still returns 200/full body, not 304.

Theme, backlinks, driven tasks, queries, and goal events resolve outside `_rev`. This Paper currently has no task/query/link/reference nodes or adjacent rails, so those resolvers are inert; live theme `iris` remains mutable. Exact release/header-to-render atomicity under concurrent publication was not induced.

Connected browser capture did not complete; no connected LiveView claim is made. Mobile, real assistive technology, keyboard, historical-revision, and forced dynamic-resolver trials are outside this lens. Mix tests could not run because dependencies are absent. Temporary captures were trashed; repository and Barkpark state were unchanged.

## Cycle payload

```json
{"assignment_id":"restart-survey-37","unit":"pds-wave-44-2026-08-03::public","verdict":"current article identity and block carriers proven; exact rev self-identification partial","paper":{"revision":"8bbd5d874a1b697f1e4e437c473f8e52","raw_machine_samples":"3/3","raw_machine_sha256":"4923e1b72da37c384ebc3f7b80ba15a08c9998fde560db0095d349a27457f96d","raw_source_sha256":"9d63b5e3f844718cb9eccb70507a63c9b2d169d90f558aab18d74344ea80b8d7","canonical_blocks_sha256":"1c10ec4984826b0b12a0111c64b57bfc2c79de3ae576dd40b74e83c9e183bfce","blocks":99},"public":{"routes":"9/9 200","block_ids":"99/99 ordered","text_leaves":"369/369","raw_article_sha256":"34daeb6637255bc76d0126c4bc0d775676468614fc8291961a42c632f2a30739","normalized_article_sha256":"1d30a9b06b9b55a603e5a8a519a9bb7a8dd8af7e887b5222f60085790ccc114c","exact_rev_visible":false,"data_rev":"0"},"cache":{"scoped_identity_headers":true,"flat_dataset_identity_headers":false,"conditional_304":false},"connected_browser":"not_proven","tests":"not_run_dependencies_absent","mutations":0}
```
