<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-36 | budget: 1400tok -->
# Restart Survey 36 — PDS44 email negative capability and evidence strength

Assignment `restart-survey-36` re-attested `pds-wave-44-2026-08-03::email` at exact revision `8bbd5d874a1b697f1e4e437c473f8e52`. Verdict: **partial: preview stable and structurally complete; revision identity, mobile containment, accessibility, MIME delivery, and real-client proof fail or remain absent**.

Three live previews passed identically at HTTP 200, 98,335 bytes and SHA-256 `c46f46e5172fa878f0a2ae8216cf75e4bfb265dc7cec350691d7e5dca2957645`. Flat, dataset-flat, and scoped-default routes matched. The body and headers contain no slug, revision, history UUID, digest, ETag, or Last-Modified.

JSON/text/XML Accept returns 406 `internal_error`, while HTML/wildcard/default returns 200 JSON/HTML preview. Missing+JSON masks 404 as 406; missing+HTML is raw 404; POST produces two other 404 dialects. Published/drafts/raw/bogus perspective parameters return identical bytes because the controller ignores perspective. Bogus If-None-Match returns full 200. Anonymous/invalid bearer succeeds for this public Paper; private/non-default auth is unvisited.

Fresh Chromium measured desktop 1440×25,474 with no overflow; at 390px the 611px document overflowed 221px, and at 320px it overflowed 291px. All five tables overflowed both narrow viewports and expose no local scroll surface.

DOM contains 1/24/7 headings, 33 paragraphs, ten UL/85 LI, five tables/three THEAD/12 TH/203 TD, and four callout-style divs. All five genuine data tables are `role=presentation`; no scopes, header associations, captions, lang, landmarks, ARIA, IDs, block IDs, viewport meta, or callout labels exist. This target has zero marks/links/images/control characters, so hostile/link/mark behavior remains unexercised live.

The route is HTTP HTML only. No Paper-specific sender, multipart builder, plain-text alternative, SMTP transfer, encoding expansion, provider receipt, or real-client capture exists. No email was sent. Static sanitization tests were inspected but not run. Scratch evidence was trashed and state remained unchanged.

## Cycle payload

```json
{"assignment_id":"restart-survey-36","unit":"pds-wave-44-2026-08-03::email","verdict":"partial","preview":{"samples":"3/3","bytes":98335,"sha256":"c46f46e5172fa878f0a2ae8216cf75e4bfb265dc7cec350691d7e5dca2957645","revision_intrinsic":false},"http":{"json_accept":406,"missing_json_masks_404":true,"perspective_ignored":true,"validator":false},"geometry":{"desktop_overflow":0,"390_overflow":221,"320_overflow":291,"tables_mobile":"5/5"},"semantics":{"data_tables_presentation":"5/5","scoped_headers":"0/12","labelled_callouts":"0/4","lang":false,"landmarks":false},"delivery":{"mime":false,"plain_text":false,"smtp":false,"real_clients":false},"hostile_content":"unexercised","mutations":0}
```
