<!-- doc-tier: cold | canonical-for: legendary-paper-restart-experiment-09 | budget: 1600tok -->
# Restart Experiment 09 — terminal and platform attack

Assignment `restart-experiment-09`, UUID `65cda1a4-64a1-45bd-a27d-1256e460210a`, canonical round `attack`, ran hostile terminal/platform probes. Typed verdict: **Attack failed with typed blocks**. Evidence generation passed; candidate behavior did not.

The sixty width cells yield 22 PASS, 18 FAIL, and 20 BLOCKED. E05 is bounded in 20/20 width cells. E06 retains measured carriers but fails 18/20 bounds because identity lines remain 110–130 columns even at hostile widths. E04 exposes no runnable width renderer and is BLOCKED 20/20. All three candidate paths retain hostile C0/ESC bytes, producing three terminal-control hard failures.

The aggregate matrix is 30 PASS, 23 FAIL, and 88 BLOCKED. Interactive mouse/focus/scroll/click/Enter parity; state/history/Related/recovery; capabilities/OpenAPI/help/pagination agreement; and safe typed 401/404/405/406/422/500/timeout behavior remain explicitly BLOCKED. E04 and E06 lack request-ID coverage, E04 has incomplete identity domains, and E04/E05 lack runnable conditional handlers. None of those cells receives proxy credit.

Replay is twice byte-identical at manifest SHA-256 `5bb9013230ea54de8f2fcd05022f1691a9476446a1442e8b957d316a1fcbe404`. The leader independently ran the verifier twice: all 19 evidence checks pass with status `PASS_EVIDENCE_ATTACK_FAILED`. Result SHA-256 is `defa06c2c42464a652ab214af8b48766a8720a37da8f1459f9a3d1a653a16074`; artifact set `f07eccbabe1d4ef6d5d9e40068c6cb14403328784250e87a5f2a7115b4c2dc60`; evidence archive `8706e754a18093abdeeabb57328b18a90882b23742f186c2c230f6420de9ae94`. Credential scan found zero hits.

Terminal sanitization, E06 wrapping, E04 renderer coverage, interactive simulation, and typed-error simulators require repair and a new authorized Attack. No candidate can converge from this evidence.

## Cycle payload

```json
{"assignment_id":"restart-experiment-09","assignment_uuid":"65cda1a4-64a1-45bd-a27d-1256e460210a","round":"attack","verdict":"ATTACK_FAIL_WITH_TYPED_BLOCKS","candidate_selected":false,"width_cells":{"pass":22,"fail":18,"blocked":20},"matrix":{"pass":30,"fail":23,"blocked":88},"control_byte_failures":3,"hard_failures":["terminal_control_leaks:E04","terminal_control_leaks:E05","terminal_control_leaks:E06","bounded_rendering:E06:18_of_20_cells","missing_request_id:E04","missing_request_id:E06","identity_domains_incomplete:E04"],"proxy_passes":0,"artifact_set_sha256":"f07eccbabe1d4ef6d5d9e40068c6cb14403328784250e87a5f2a7115b4c2dc60"}
```
