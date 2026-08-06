<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-42 | budget: 1400tok -->
# Restart Survey 42 — PDS44 Studio negative capability

Assignment `restart-survey-42` challenged `pds-wave-44-2026-08-03::studio` at exact revision `8bbd5d874a1b697f1e4e437c473f8e52`. Verdict: **partial**. Unauthenticated gating and exact source identity are proven; safe read-only posture and table preservation are contradicted; fresh role-specific authorization, persistence, reload, zoom, keyboard, and accessibility remain blocked.

Three machine Paper reads and the final read were identical at 328,256 bytes/SHA `4923e1b72da37c384ebc3f7b80ba15a08c9998fde560db0095d349a27457f96d`. Scoped source was 76,255 bytes/SHA `9d63b5e3f844718cb9eccb70507a63c9b2d169d90f558aab18d74344ea80b8d7`.

Fresh GET/HEAD to canonical Studio redirect to login; invalid bearer is identical. Missing and draft-prefixed document slugs also redirect, preventing pre-auth document enumeration. Encoded traversal, NUL, and attacker return targets did not escape login, but legitimate query state including desk/perspective is dropped. Unknown workspace uniquely returns detailed JSON 404 while later scope failures remain login redirects, exposing workspace-existence distinction. Explicit JSON/plain Accept returns 406 `internal_error`; POST/OPTIONS/TRACE return generic HTML 404.

The default canvas opens as an editor labelled “Editing,” with no View/Edit mode and no `editable=false` attribute. That contradicts a safe read-only reader posture; whether a read-only principal receives the same editable-looking surface requires a fresh role matrix. Server capability code is not deployed-role proof.

All source table headers do not survive: the Paper uses `header`, conversion reads `head`, and authenticated connected evidence shows zero TH. Existing tests cover current `head`, not this compatibility path. Production save/reload was intentionally not attempted. Fresh authenticated member/admin/read-only/share/grant roles, disposable-fixture persistence, browser zoom, keyboard/AX, malformed-seed recovery, real mobile activation, and real assistive technology remain unvisited—not proxy-passed. No tests ran and no state changed.

## Cycle payload

```json
{"assignment_id":"restart-survey-42","unit":"pds-wave-44-2026-08-03::studio","verdict":"partial","claims":{"exact_paper":"proven","anonymous_gate":"proven","hostile_navigation":"partial","role_authorization":"blocked","safe_read_only_reader":"contradicted","table_headers_survive":"contradicted","persistence_reload":"blocked","errors_truthful":"partial"},"paper":{"rev":"8bbd5d874a1b697f1e4e437c473f8e52","raw_machine_sha256":"4923e1b72da37c384ebc3f7b80ba15a08c9998fde560db0095d349a27457f96d","raw_source_sha256":"9d63b5e3f844718cb9eccb70507a63c9b2d169d90f558aab18d74344ea80b8d7"},"studio":{"view_edit_mode":false,"default_editable_surface":true,"source_headers":12,"studio_headers":0,"query_state_preserved":false,"workspace_existence_distinction":true},"fresh_authenticated_role_matrix":"blocked","tests_run":0,"mutations":0}
```
