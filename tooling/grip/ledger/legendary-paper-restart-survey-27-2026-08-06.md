<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-27 | budget: 1400tok -->
# Restart Survey 27 — CCH29 Studio negative capability and evidence strength

Assignment `restart-survey-27` re-attested `cloud-console-hardening-wave-29-2026-08-03::studio` against restart wave `8a94f6db-1be6-4bbf-ba49-7f3aeed0e737`. Verdict: **partial, high confidence: anonymous/error boundaries proven; authenticated revision parity, roles, MFA, connected reauthorization, and write behavior require controlled sessions**.

## Anonymous and source controls

The Paper remains at exact revision `18768b0a14c2eead927181c4a0e37c18`, 252 blocks, with no draft twin. Published/drafts/raw API reads return the same row. Studio is intrinsically draft-first and ignores `?perspective`, so the query cannot bind it to published identity.

Canonical anonymous Studio repeated 5/5 identical 302 redirects to an internal login return path. Missing project/dataset/type/id, incomplete paths, missing document, and published/drafts/raw/bogus perspective all collapse to the same login boundary, avoiding lower-scope resource disclosure. Unknown workspace instead returns structured JSON 404, exposing a known-versus-unknown workspace distinction.

Hostile target-level external/scheme-relative return_to values are discarded. Login preserves internal absolute paths and normalizes external, scheme-relative, JavaScript, and backslash forms to `/studio`. Percent-encoded CR/LF in a single-slash path survives into the hidden field; downstream authenticated redirect safety was not exercised.

## Taxonomy, cache, and auth boundary

Non-HTML Accept returns correct 406 but mislabeled `internal_error`. OPTIONS, TRACE, and write methods return 404 `not_found`, not 405. Anonymous responses use private must-revalidate caching without validators; login-ticket consumption is no-store.

Static code proves dead-render and connected scope checks, draft-first selection, API-token/user session arms, organization MFA rules, and scope reauthorization. No safe user/MFA/member/grant session was available in this lane, so exact role/MFA behavior, connected cross-scope patches, authenticated errors/cache, and writes remain unproven. Survey 25 separately proves the API-token connected content path, not user/TOTP or authorization permutations.

No session was minted, no mutation or test ran.

## Cycle payload

```json
{"assignment_id":"restart-survey-27","unit":"cloud-console-hardening-wave-29-2026-08-03::studio","verdict":"partial","confidence":"high","authority":{"wave":"8a94f6db-1be6-4bbf-ba49-7f3aeed0e737","paper_rev":"18768b0a14c2eead927181c4a0e37c18"},"source":{"blocks":252,"draft_twin":false},"anonymous":{"valid":"302_login","later_scope_controls":"same_302","unknown_workspace":"404_not_found_json","repeats":"5/5 identical"},"studio":{"perspective_query":"ignored","selection":"draft_first","current_exact_render":"proven separately by survey-25"},"taxonomy":{"non_html_accept":"406_internal_error","unsupported_methods":"404_not_found"},"cache":{"anonymous":"private_must_revalidate","validators":false,"ticket_consume":"no_store"},"auth":{"safe_user_mfa_session_available":false,"api_token_path":"code_plus_survey25","connected_role_matrix":"unvisited"},"mutations":0,"tests_run":0}
```
