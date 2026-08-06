<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-20 | budget: 1400tok -->
# Restart Survey 20 — CCH29 email live regression and frozen gates

Assignment `restart-survey-20` re-attested `cloud-console-hardening-wave-29-2026-08-03::email` against restart wave `8a94f6db-1be6-4bbf-ba49-7f3aeed0e737`. Verdict: **byte-identical unchanged failure; delivered-client capability remains blocked**.

## Direct answer

Six live HTTP requests returned 200 without stalls. Five consecutive bodies were byte-identical at 121,072 bytes and SHA-256 `dc57c4d6704a97ba7003a06694f126c25f9de3f5c8e64529aa20351a3b36e331`, exactly matching the frozen baseline for revision `18768b0a14c2eead927181c4a0e37c18`. No current transient failure was reproduced; the historical one-attempt 500 followed by an immediate success remains a carried reliability risk.

## Frozen-gate ruling

The unchanged preview contains 11 presentational tables, 35 visible header cells, zero scoped headers or captions, zero main/article landmarks, one H1 but no document language, zero block/revision carriers, zero links/buttons/tabbable controls, zero semantic strong/code/em elements, and zero accessible callout tone carriers. It has no viewport declaration.

All 11 paragraph-wrapped list items and all 406 words remain absent. The source retains 139 exact-empty spacers. Machine source alias control passes because 35 legacy headers remain and no conflicting modern `head` exists, but human text, table, mark, callout, spacer, revision, and provenance gates remain failures.

Frozen browser measurements remain applicable because live HTML is byte-identical and the static cause is unchanged: requested 320 and 390 widths both resolve to an effective 980-pixel layout, while the tables are roughly 600–612 pixels wide. Geometry passes 0/2. This is re-attestation by exact bytes plus frozen CDP evidence, not a fresh browser capture.

No real delivery backend or Gmail, Outlook, or Apple Mail artifact exists in the bounded evidence. The six required delivered-client cells—two widths across three clients—remain 0/6 blocked and are not proxy-passed by HTTP preview.

## Reliability and scope

Current 6/6 success does not erase the retained transient 500. No ETag was present. Canonical accounting, terminal geometry, and navigation are not applicable to this preview cell. No repository or server mutation occurred.

## Cycle payload

```json
{"assignment_id":"restart-survey-20","unit":"cloud-console-hardening-wave-29-2026-08-03::email","revision":"18768b0a14c2eead927181c4a0e37c18","verdict":"unchanged_failure_with_real_mail_blocked","live_http":{"attempts":6,"successes":6,"stalls":0,"status":200,"bytes":121072,"sha256":"dc57c4d6704a97ba7003a06694f126c25f9de3f5c8e64529aa20351a3b36e331","etag":null},"content":{"nested_items":"0/11","nested_words":"0/406","tables":11,"presentation_tables":11,"header_cells":35,"scoped_headers":0,"captions":0,"revision_carriers":0,"semantic_marks":0,"accessible_callout_carriers":0},"geometry":{"method":"exact-live-byte-identity-plus-frozen-CDP","requested_320_effective":980,"requested_390_effective":980,"pass":"0/2"},"historical_transient_500":{"observed":1,"current_reproduced":false},"real_mail_clients":{"pass":"0/6","status":"blocked"}}
```
