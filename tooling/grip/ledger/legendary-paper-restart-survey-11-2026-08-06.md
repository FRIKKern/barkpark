<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-11 | budget: 1400tok -->
# Restart Survey 11 — Studio live regression and frozen gates

Assignment `restart-survey-11` re-attested `cloud-console-hardening-wave-28-2026-08-03::studio` against restart wave `8a94f6db-1be6-4bbf-ba49-7f3aeed0e737`. Verdict: **blocked: no existing authenticated Studio session; no proxy pass**.

## Direct answer

The canonical CCH28 Studio URL was tested in Chrome and by HTTP. Anonymous and bearer-only HTTP both returned 302 to the sign-in flow; the existing Chrome profile displayed the Barkpark Studio login page. No Studio editor mounted, no `studio-paper-editor` marker appeared, and zero authenticated 320/390 width cells could be measured. Authentication enforcement is an unchanged auxiliary pass, not Paper-reader evidence.

No login, credential injection, ticket mint, save, or other mutation occurred. The governing baseline requires authenticated Studio evidence and explicitly forbids proxy passage.

## Frozen-gate ruling

Blocked gates: canonical accounting, revision pins, text losslessness, table semantics, mark semantics, callout semantics, spacer migration, navigation, contract provenance, and real-reader capability. Nested-list losslessness, headerless intent, alias conflict, browser geometry, and terminal geometry are non-applicable in the absence of a mounted authenticated reader.

Totals: ten blocked and five N/A; zero regression, improvement, unchanged failure, or reader-gate pass. Session authentication itself remains an unchanged pass.

## What source proves—and does not

Fresh machine source is revision `49c1534d9fb76d0d9adc7b97f25ec471`, with 237 blocks/unique IDs, 43 headings, 18 tables, 57 authored headers, 466 body cells, zero headerless/alias-conflict tables, seven lists/35 flat items, 13 callouts, 103 spacer candidates, and 67 marks. These are editor-input denominators only. They do not prove authenticated Studio displays or preserves any of them.

Repository implementation expects a mounted Paper to expose `studio-paper-editor` and an always-open editor on the default canvas path; repository tests assert the same marker and block rendering. Those are implementation expectations, not deployed authenticated-reader observations.

The tested route and session boundary are facts: browser LiveViews use session credentials, the scoped route mounts through token/session and LiveScope plugs, and missing authorization fails closed to login. The result proves this profile/session was unauthenticated; it does not prove valid credentials do not exist elsewhere.

## Residual scope and risk

Other browser profiles or accounts were not inspected. Neither required width, editor navigation, source losslessness, semantic tables/callouts/marks, revision identity, nor reader capability was observable. The source route also returned 500 for `Accept: application/json` while returning JSON under `Accept: text/html`, an adjacent negotiation defect rather than Studio proof.

## Cycle payload

```json
{"assignment_id":"restart-survey-11","unit":"cloud-console-hardening-wave-28-2026-08-03::studio","verdict":"BLOCKED_NO_EXISTING_AUTHENTICATED_STUDIO_SESSION","canonical_route":"/w/default/p/default/d/production/studio/paper/cloud-console-hardening-wave-28-2026-08-03","anonymous_status":302,"bearer_status":302,"browser_observation":"login page","editor_mounts":0,"studio_paper_editor_markers":0,"authenticated_width_cells":"0/2","auxiliary_auth_enforcement":"unchanged_pass","gates":{"blocked":10,"not_applicable":5,"regression":0,"improvement":0,"unchanged_failure":0,"unchanged_pass":0},"source":{"revision":"49c1534d9fb76d0d9adc7b97f25ec471","blocks":237,"unique_ids":237},"mutations":false}
```
