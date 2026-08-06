<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-51 | budget: 1400tok -->
# Restart Survey 51 — PDS45 email negative capability

Assignment `restart-survey-51` challenged `pds-wave-45-2026-08-03::email` at exact revision `b992fd8aaa028b0dab30a8da76f077fd`. Verdict: **partial**. Exact active-origin preview bytes, public visibility, missing/method behavior, and static sanitization boundaries are proven; negotiation, perspective validation, semantics, cache validation, MIME delivery, and real-client safety are failed or blocked.

Flat/dataset/shared-scoped active-origin reads return identical 200 `text/html`, 119,290 bytes/SHA `3e29bd38…a900`. The inline-style document has doctype/charset and zero style/script elements, but no MIME envelope, sender/subject, text alternative, slug/revision, validator, or Content-Disposition.

HTML and `*/*` Accept succeed; JSON/plain/XHTML return 406 JSON `internal_error`; no plain-text preview exists. Published/drafts/raw/invalid `sideways` perspectives return identical bytes. Invalid bearer does not alter public/shared output, consistent with route visibility—not an auth bypass. Missing/path-like slugs return plain 404; HEAD succeeds; POST/PUT/DELETE/OPTIONS return generic 404 without Allow. Cache is private must-revalidate without ETag/Last-Modified.

All 12 data tables are presentation-only; nine TH lack scope; no HTML language, viewport, landmark, ARIA, media rule, semantic strong, or plain-text alternative exists. Repository search found no Paper-specific Swoosh/Mailer delivery, multipart construction, sender identity, or text body. Actual MIME/provider/client delivery, Gmail/Outlook/Apple Mail, dark mode, zoom, AT, and client clipping remain blocked/unvisited.

Fail-closed conflicting sources and link sanitization exist in inspected tests/code, but were not live-injected and are only partial evidence. No tests ran and no state changed.

## Cycle payload

```json
{"assignment_id":"restart-survey-51","unit":"pds-wave-45-2026-08-03::email","verdict":"partial","claims":{"active_preview":"proven","standalone_html":"proven","accept_negotiation":"contradicted","plain_text":"contradicted","perspective_validation":"contradicted","public_visibility":"proven","method_taxonomy":"partial","cache_validation":"contradicted","table_accessibility":"contradicted","mime_delivery":"blocked","real_clients":"blocked","sanitization":"partial"},"preview":{"bytes":119290,"sha256":"3e29bd380466e0db716ec4bc67a197a38206a757ebf7f5157f98da70fd39a900"},"delivery":{"mime":false,"sender":false,"receipt":false,"clients":"unvisited"},"tests_run":0,"mutations":0}
```
