<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-40 | budget: 1400tok -->
# Restart Survey 40 — PDS44 Studio provenance/current pin

Assignment `restart-survey-40` re-attested `pds-wave-44-2026-08-03::studio` at Paper revision `8bbd5d874a1b697f1e4e437c473f8e52`. Verdict: **authenticated Studio server-canvas provenance is exact; immutable revision identity is absent; fresh connected-browser proof did not complete**.

Five raw machine Paper reads were byte-identical: 328,256 bytes, SHA-256 `4923e1b72da37c384ebc3f7b80ba15a08c9998fde560db0095d349a27457f96d`, 99/99 unique blocks. Two scoped source responses were identical: 76,255 bytes, SHA-256 `9d63b5e3f844718cb9eccb70507a63c9b2d169d90f558aab18d74344ea80b8d7`.

Canonicalization boundaries are explicit: `jq -c '.source.blocks'` plus terminal LF is 76,025 bytes/SHA `1c10ec4984826b0b12a0111c64b57bfc2c79de3ae576dd40b74e83c9e183bfce`; the compact block array without LF is 76,024 bytes/SHA `a89dd730f1697b0ce25b86ace3f88d790ef6b13e24e5519d58b3ded2c09445cd`; newline-delimited ordered IDs hash to `1b0a3bf27f0ef9f06046c083109a724ba04595e6b8c1d8b39f542f33de604b58`.

Direct `drafts.<slug>` reads returned 404 `3/3`; bare-slug published/drafts perspectives were semantically identical. Studio's draft-first selection therefore currently falls back to the published revision.

Anonymous Studio redirected to login. An existing saved admin token was submitted through the documented CSRF form; login returned to the exact scoped route. Authenticated HTML returned 200/792,001 bytes with one LiveView carrier, editor, shell, exact slug sentinel, and one decoded 76,024-byte canvas seed. It contained 99/99 unique blocks and was byte-identical to the compact source array. Immutable `_rev` occurs zero times and no active `data-rev` carrier exists. Studio's editor revision uses content `rev || 0`, a different identity domain.

Two fresh connected Playwright attempts hung and were terminated; no connected pass is claimed. Save/autosave, edit, conflict, alternate account/dataset/browser, keyboard, and accessibility remain unvisited. One source and one CLI read transiently returned 500 before successful retries; provenance is stable, availability requires separate proof. Temporary captures were trashed; no repository or Barkpark state changed.

## Cycle payload

```json
{"assignment_id":"restart-survey-40","unit":"pds-wave-44-2026-08-03::studio","verdict":"authenticated server canvas provenance proven; immutable revision carrier absent; connected refresh unvisited","paper":{"rev":"8bbd5d874a1b697f1e4e437c473f8e52","blocks":99,"raw_machine_sha256":"4923e1b72da37c384ebc3f7b80ba15a08c9998fde560db0095d349a27457f96d","raw_source_sha256":"9d63b5e3f844718cb9eccb70507a63c9b2d169d90f558aab18d74344ea80b8d7","compact_blocks_sha256":"a89dd730f1697b0ce25b86ace3f88d790ef6b13e24e5519d58b3ded2c09445cd","draft_twin":false},"studio":{"anonymous":302,"authenticated":200,"server_bytes":792001,"canvas_runs":1,"canvas_blocks":"99/99","slug_exact":true,"document_rev_visible":false},"connected_browser":"unvisited_after_hung_attempts","transient_500s":2,"mutations":0}
```
