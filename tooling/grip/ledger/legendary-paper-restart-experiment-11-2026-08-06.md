<!-- doc-tier: cold | canonical-for: legendary-paper-restart-experiment-11 | budget: 1700tok -->
# Restart Experiment 11 — human-reader convergence

Assignment `restart-experiment-11`, UUID `1f343fdc-85c3-4aeb-a5e8-0fb2a13eaef8`, canonical round `converge`, independently replayed the human-reader evidence and froze eight executable replacement-wave fixture contracts. Typed verdict: **no winner; Pilot unauthorized; replacement wave required**.

| Candidate | PASS | observed FAIL | BLOCKED | Verdict |
|---|---:|---:|---:|---|
| E04 | 12 | 10 | 21 | reject |
| E05 | 2 | 24 | 17 | reject |
| E06 | 16 | 10 | 17 | reject |
| **Total** | **30** | **44** | **55** | **no winner** |

This convergence corrects an over-broad E08 heuristic: eleven intentionally headerless tables—PDS44 two and PDS45 nine—must remain headerless and are not missing-header failures. The 113 authored header cells remain mandatory. This correction does not rescue a candidate. E04 loses authored mark semantics, has unstable anonymous focus identities, and exposes no RFC message. E05 loses table-header and callout semantics, carries fewer than 388 marks, has no focus targets, and omits `From`, `To`, and `Message-ID`. E06 preserves table intent, callouts, landmarks, and MIME headers but carries fewer than 388 marks and unstable anonymous focus identities.

E11 also proves E08’s requested 390 and 320 browser captures actually reported `clientWidth` 500, and complete 32-cell golden-frame coverage was absent for every candidate. Authenticated Studio expiry/reconnect, delivered clients, cache lifecycle, complete golden frames, and real assistive technology remain BLOCKED.

Replay semantic SHA-256 is stable twice at `5bd28d328ada436fb00d2200f1a499ca0d6f1880a453ba9b1587ec54aad9578d`. The leader independently ran the verifier twice with 28/28 checks PASS. Result SHA-256 is `2d3ef451264aefc079fa9093e44992b8d0ea0f4157cc7f2bcb109435ad3fa1b1`; deterministic archive and artifact-set SHA-256 `bf254b6bcaf590724f7b4d52f769167264f4bc5ee92761ed2cfcc0c25f3c7682`. Credential scan passes; its self-scan false-positive attempt is preserved.

The replacement wave must use the eight frozen fixtures and exact browser viewport assertions before any Pilot.

## Cycle payload

```json
{"assignment_id":"restart-experiment-11","assignment_uuid":"1f343fdc-85c3-4aeb-a5e8-0fb2a13eaef8","round":"converge","verdict":"NO_WINNER_PILOT_UNAUTHORIZED_REPLACEMENT_WAVE_REQUIRED","candidate_selected":false,"pilot_authorized":false,"matrix":{"pass":30,"fail":44,"blocked":55},"intentional_headerless_tables":11,"authored_headers_required":113,"viewport_substitution_detected":true,"replacement_fixtures":8,"proxy_passes":0,"artifact_set_sha256":"bf254b6bcaf590724f7b4d52f769167264f4bc5ee92761ed2cfcc0c25f3c7682"}
```
