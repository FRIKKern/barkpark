<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-55 | budget: 1400tok -->
# Restart Survey 55 — PDS45 Studio provenance

Assignment `restart-survey-55` re-attested `pds-wave-45-2026-08-03::studio` at revision `b992fd8aaa028b0dab30a8da76f077fd`. Verdict: **authenticated server-canvas provenance is exact; immutable revision identity is absent; connected-client projection is unvisited**.

Machine document (3/3, 392,184 bytes/SHA `5894db69…aa7`), scoped source (3/3, 91,515 bytes/SHA `e19503ef…1e8`), newest history revision `4afe0099-26af-40eb-8943-f6935c16c29d`, and Studio seed share the exact 227-block SHA `f01937cb…9da`. No draft twin exists; draft-first selection falls back to published.

Anonymous canonical Studio redirects to login. A CSRF-protected API-token login returned to the exact scoped route; authenticated GETs were 3/3 HTTP 200 and 820,652 bytes. Each server response contains one LiveView carrier, editor, exact slug/title, theme `iris`, and one 91,347-byte exact canvas seed. Whole-page hashes vary with session/CSP material. No canvas token is embedded.

Neither document `_rev` nor history UUID appears in HTML; Studio `paper_rev` derives from `content.rev || 0`, a separate identity domain. Dead HTML proves seed provenance, not JavaScript connection, block DOM, semantics, websocket state, reload/reconnect, save, conflict, or persistence. Role/MFA/grant matrices and alternate browsers remain unvisited. Credential-bearing temporary captures were trashed. No mutation or test ran.

## Cycle payload

```json
{"assignment_id":"restart-survey-55","unit":"pds-wave-45-2026-08-03::studio","verdict":"server_canvas_proven_revision_identity_partial","confidence":"high","paper":{"rev":"b992fd8aaa028b0dab30a8da76f077fd","blocks":227,"document_samples":"3/3","document_sha256":"5894db69f3d9ddc0416bd5e5e6b50dc72c1d962efb56ac7fd863b1a8d1caa7","source_samples":"3/3","source_sha256":"e19503ef0f854680056c1857d2d9647dbfdafb2a172e7cabc75d67652f1514e8","blocks_sha256":"f01937cbc0c28fc4f381136ba1ec8174591b1d60abc7b99454aaefd8a7f829da","history_revision":"4afe0099-26af-40eb-8943-f6935c16c29d","draft_twin":false},"auth":{"anonymous":302,"login_get":200,"token_login":302,"authenticated_samples":"3/3","authenticated_bytes":820652},"studio":{"liveview_carrier":true,"editor":true,"canvas_blocks":"227/227","canvas_sha256":"f01937cbc0c28fc4f381136ba1ec8174591b1d60abc7b99454aaefd8a7f829da","theme":"iris","canvas_token_embedded":false,"document_rev_visible":false},"connected_browser":"unvisited","mutations":0,"tests_run":0}
```
