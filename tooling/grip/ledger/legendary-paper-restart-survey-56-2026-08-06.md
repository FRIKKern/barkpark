<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-56 | budget: 1400tok -->
# Restart Survey 56 — PDS45 Studio frozen gates

Assignment `restart-survey-56` re-attested `pds-wave-45-2026-08-03::studio`. Verdict: **blocked without an existing authenticated connected-browser session**. Authentication routing passes; live Studio completeness, responsive geometry, controls, and connection gates do not.

Canonical Paper/open routes were each 3/3 HTTP 302 to login with exact return paths; flat compatibility was 3/3 302 to canonical. The headless browser held only an unauthenticated session cookie and mounted zero Studio shells, editors, or LiveView roots at 1440, 390, and 320px. Login-page measurements are not Studio evidence.

Fresh source remains exact at revision `b992fd8aaa028b0dab30a8da76f077fd`, 227 blocks/SHA `f01937cb…9da`. Current production `runToTiptap` preserves 227→227 blocks and produces zero untouched operations, but imports 0/9 legacy header cells and 0/8 marked runs. This independently confirms silent projection loss; it is not a live UI pass. Current three-column topbar CSS still lacks a phone override, but the frozen phone clipping claim cannot be freshly classified without authentication.

Blocked gates include content/order, visible parity, semantics, desktop/phone overflow, table/keyboard reachability, action visibility, wheel/focus isolation, LiveView connection/reconnect, and revision exposure. Role/MFA/grant behavior, draft identity, saves, presence, Safari/Firefox, AT, touch, zoom, and themes remain unvisited. No mutation occurred.

## Cycle payload

```json
{"assignment_id":"restart-survey-56","unit":"pds-wave-45-2026-08-03::studio","verdict":"blocked_no_authenticated_session","paper_rev":"b992fd8aaa028b0dab30a8da76f077fd","routes":{"canonical":"3/3 302 login","canonical_open":"3/3 302 login","flat":"3/3 302 canonical"},"authenticated_width_cells":"0/3","editor_mounts":0,"static_projection":{"blocks":"227→227","ops":0,"headers":"0/9","bold_marks":"0/8"},"live_gates":"blocked","mutations":0}
```
