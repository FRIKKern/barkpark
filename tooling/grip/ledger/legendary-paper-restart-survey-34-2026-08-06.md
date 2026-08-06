<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-34 | budget: 1400tok -->
# Restart Survey 34 — PDS44 email provenance and current pin

Assignment `restart-survey-34` re-attested `pds-wave-44-2026-08-03::email` at revision `8bbd5d874a1b697f1e4e437c473f8e52`. Verdict: **current source-to-preview projection is exactly reproducible; intrinsic revision and delivered MIME proof are absent**.

## Direct answer

Full machine Paper passed `3/3`: 328,256 bytes, corrected SHA-256 `4923e1b72da37c384ebc3f7b80ba15a08c9998fde560db0095d349a27457f96d`. Published source passed `3/3`: 76,255 bytes, SHA-256 `9d63b5e3f844718cb9eccb70507a63c9b2d169d90f558aab18d74344ea80b8d7`. The 99-block hash is `1c10ec4984826b0b12a0111c64b57bfc2c79de3ae576dd40b74e83c9e183bfce`; ordered IDs hash to `1b0a3bf27f0ef9f06046c083109a724ba04595e6b8c1d8b39f542f33de604b58`.

Flat, dataset, and scoped-default email routes returned byte-identical HTTP 200 responses; repeated flat sampling also passed `3/3`. Each preview is 98,335 bytes, SHA-256 `c46f46e5172fa878f0a2ae8216cf75e4bfb265dc7cec350691d7e5dca2957645`.

Source-to-DOM accounting is exact: 99 blocks become 84 visible top-level structures in exact order; 32 headings become 1/24/7 H1/H2/H3; 48 paragraphs become 33 visible paragraphs with 15 empty scaffolds suppressed; ten lists/85 items survive; five tables/54 rows survive; three header bands/12 cells become three THEAD/12 TH; four callouts survive. All 369 authored text leaves appear sequentially with zero misses, and `xmllint` passes.

## Provenance and delivery boundary

The HTML and headers contain zero slug, revision, digest, block-id, ETag, or Last-Modified carriers. A detached preview cannot prove its source without this external ledger. Task queries and workspace theme resolve live outside the Paper revision. This Paper currently has zero task/query/link nodes, so task resolution and link rewriting are inert; theme remains a mutable dependency.

The response is standalone HTML, not RFC 5322/MIME: no MIME-Version, Message-ID, transfer encoding, From/To/Subject, multipart boundary, provider receipt, mailbox artifact, or delivery adapter was found. The controller ends in HTTP `send_resp`, and no Paper-specific Swoosh/provider sender exists. No email was sent and no Gmail/Outlook/Apple Mail behavior is claimed.

This assignment also corrects a transcription error: Surveys 31–33 and their immutable result payloads recorded a 63-character full-document SHA by omitting `c3`. The fresh `3/3` value above is authoritative; immutable history is preserved and the reports now carry explicit errata. Targeted Mix tests could not run because dependencies/build are absent. Temporary captures were trashed; no state mutation occurred.

## Cycle payload

```json
{"assignment_id":"restart-survey-34","unit":"pds-wave-44-2026-08-03::email","verdict":"current projection proven; intrinsic revision and delivery unproven","paper":{"revision":"8bbd5d874a1b697f1e4e437c473f8e52","samples":"3/3","sha256":"4923e1b72da37c384ebc3f7b80ba15a08c9998fde560db0095d349a27457f96d","blocks":99,"blocks_sha256":"1c10ec4984826b0b12a0111c64b57bfc2c79de3ae576dd40b74e83c9e183bfce"},"preview":{"routes":"3/3 equal","samples":"3/3","bytes":98335,"sha256":"c46f46e5172fa878f0a2ae8216cf75e4bfb265dc7cec350691d7e5dca2957645","structures":"84/84 ordered","text_leaves":"369/369","revision_carrier":false},"dynamic":{"tasks_inert":true,"theme_revision_bound":false},"mime":{"artifact":false,"delivery":false,"real_clients":false},"corrects":"surveys31-33 malformed 63-character document hash","mutations":0}
```
