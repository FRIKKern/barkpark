<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-12 | budget: 1400tok -->
# Restart Survey 12 — Studio negative capability and evidence strength

Assignment `restart-survey-12` re-attested `cloud-console-hardening-wave-28-2026-08-03::studio` against restart wave `8a94f6db-1be6-4bbf-ba49-7f3aeed0e737`. Verdict: **authentication and server payload proven; connected editor blocked; dataset closure contradicted**.

## Direct answer

Using the documented browser login with the existing admin token proves authenticated Studio access and a stable server-rendered Paper payload. It does not prove JavaScript/LiveView connection, ProseMirror initialization, caret behavior, editing, autosave, conflict handling, or preservation after writing; no editor mutation event was exercised.

## Authentication and positive control

`GET /login` returned 200 with CSRF/cookie; `POST /login` returned 302 to the exact canonical deep link; authenticated canonical GET returned 200 and 871,795 bytes. Five subsequent session reads were 5/5 HTTP 200 with identical size, one LiveView session carrier, one canvas payload, and all 237 unique source-style block IDs.

The payload also contained save/autosave affordances, 18 raw table-header structures, 26 strong marks, and 41 code marks. It contained zero exact immutable source-revision carriers. Exact slug, block inventory/IDs, raw structures, and sampled prose support an inferred link to revision `49c1534d9fb76d0d9adc7b97f25ec471`; they do not prove it.

Anonymous existing and missing Papers both redirected to login, preventing pre-auth existence enumeration. Bearer-only Studio access also redirected. Invalid and missing login tokens returned the login form with explicit errors. Hostile absolute and scheme-relative return targets both normalized to `/studio`, proving local-path-only redirect sanitization.

## Negative and adversarial controls

- Missing Paper: HTTP 200 Studio shell, zero canvas payload, explicit human “could not open”/missing-Paper message.
- Unknown document type: HTTP 200 shell, zero canvas, explicit missing-section error.
- Unknown workspace/project: 404/404.
- Invalid dataset: 302 to the same Paper in `production`, contradicting fail-closed dataset identity even though the substitution is visible.
- Published, drafts, and bogus perspective queries: 3/3 HTTP 200 with identical payload; this route ignores the parameter and it cannot prove selected revision class.
- Flat and legacy scoped Studio routes: 2/2 canonical 302 redirects.

Proven: browser-session authentication, anonymous closure, hostile-return sanitization, canonical redirects, stable server payload, 237-block payload identity, and human-readable missing/type errors.

Blocked: connected LiveView, ProseMirror, caret/focus, keyboard/responsive behavior, save/autosave success, conflicts/write loss, screen readers, alternate browsers, and real draft/published divergence. Server payload makes those plausible, never proven. Missing-document closure is partial because UI error is clear while HTTP 200 prevents status-only monitoring. Invalid dataset closure and immutable Studio revision identity are contradicted.

The result complements rather than erases Survey 11: a clean existing Chrome profile had no authenticated session; this lens deliberately established a new signed browser session through the documented login flow. Neither obtained connected-editor or write evidence.

## Cycle payload

```json
{"assignment_id":"restart-survey-12","unit":"cloud-console-hardening-wave-28-2026-08-03::studio","revision":"49c1534d9fb76d0d9adc7b97f25ec471","verdict":"AUTH_AND_SERVER_PAYLOAD_PROVEN_CONNECTED_EDITOR_BLOCKED_DATASET_CLOSURE_CONTRADICTED","auth_login_status":302,"canonical_status":200,"authenticated_stability":"5/5","server_bytes":871795,"canvas_payloads":1,"payload_block_ids":"237/237","payload_table_headers":18,"payload_strong_marks":26,"payload_code_marks":41,"revision_carriers":0,"anonymous_existing":302,"anonymous_missing":302,"invalid_login_controls":"2/2_closed","hostile_return_to":"2/2_sanitized","missing_document":{"status":200,"canvas":0,"human_error":true},"invalid_type":{"status":200,"canvas":0,"human_error":true},"invalid_workspace":404,"invalid_project":404,"invalid_dataset":"302_to_production","perspective_queries":"3/3_ignored_200","legacy_redirects":"2/2_canonical_302","connected_liveview_cells":0,"editor_write_cells":0,"classifications":{"proven":7,"inferred":1,"blocked":8,"contradicted":2,"partial":1}}
```
