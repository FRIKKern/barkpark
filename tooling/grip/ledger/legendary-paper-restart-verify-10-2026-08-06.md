<!-- doc-tier: cold | canonical-for: legendary-paper-restart-verify-10 | budget: 2100tok -->
# Restart Verify 10 — public/email HTTP contracts

Assignment `restart-verify-10` ran a 264-cell live HTTP/1.1/HTTP/2 contract matrix across availability, Accept, methods, perspectives, and slug failures. Verdict: **refuted, high confidence**.

The final post-recovery matrix completed 132 cells per protocol: 48 availability, 60 Accept, 72 methods, 48 perspectives, and 36 slug cells. Status totals were 144×200, 36×406, 60×404, 18×400, and six HTTP/2 parser/no-response cells. TSV SHA-256 is `c38c3a10088a75bcbdc68b853a5ed65bb5c93dcdbba54db24f3f438311f52dea` (65,955 bytes). Current email availability passes 24/24 across all frozen Papers, route forms, and protocols.

Unsupported Accept returns status 406 in 36/36 but labels every response `internal_error`; negotiation-specific codes pass 0/36. POST/PUT/DELETE/OPTIONS return 404 in 48/48 with no `Allow`, not 405. Missing slugs return 404 in 12/12 but never a `not_found` envelope: public emits generic HTML and email a bare nine-byte `not found` without Content-Type. Malformed inputs yield 18×400 with no `bad_request`; encoded `%ZZ` over HTTP/2 closes six connections with curl exit 92/status 000/no body.

All 48 perspective cells return 200, including invalid `sideways` in 12/12. Email responses for published/drafts/raw/sideways are byte-identical within each route/protocol, proving the parameter is ignored. Request IDs are unique in 252/264 responses and absent exactly from the twelve malformed-parser cells. No 500 occurred, but all 36 negotiation failures are falsely labeled internal errors.

| Contract | Required | Observed |
|---|---:|---:|
| Negotiation-specific 406 code | 36/36 | 0/36; `internal_error` 36/36 |
| Unsupported method 405 + Allow | 48/48 | 0/48; 404 48/48 |
| Missing `not_found` envelope | 12/12 | 0/12 |
| Malformed `bad_request` | 24/24 | 0/24 |
| Invalid perspective rejected | 12/12 | 0/12; 200 12/12 |

The code matches the results: only GET routes are declared; email ignores perspective and emits its bare missing response; generic JSON error rendering collapses non-404 errors to unknown/internal-error; anonymous perspective parsing maps invalid values to published.

The isolated worktree briefly disappeared and two partial passes were discarded. The complete 264-cell matrix reran after recovery, leaving no denominator gap. No test or live write ran.

## Cycle payload

```json
{"assignment_id":"restart-verify-10","cycle_uuid":"b30f7b3c-05ab-45db-ab5e-97fb6bb0a217","verdict":"refuted","matrix":{"total":264,"availability":48,"accept":60,"methods":72,"perspectives":48,"slugs":36,"h1":132,"h2":132,"statuses":{"200":144,"406":36,"404":60,"400":18,"000":6}},"threshold":{"accept_406_status":"36/36","accept_specific_code":"0/36","false_internal_error":"36/36","method_405_allow":"0/48","missing_404":"12/12","missing_not_found":"0/12","malformed_bad_request":"0/24","perspective_invalid_rejected":"0/12"},"email_availability":"24/24_200","request_ids":"252/264_unique","matrix_sha256":"c38c3a10088a75bcbdc68b853a5ed65bb5c93dcdbba54db24f3f438311f52dea","mutations":{"tracked":0,"task":0,"paper":0,"cycle":0,"live_write":0}}
```
