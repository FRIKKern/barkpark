<!-- doc-tier: cold | canonical-for: legendary-paper-restart-experiment-12 | budget: 1600tok -->
# Restart Experiment 12 — platform-truth convergence

Assignment `restart-experiment-12`, UUID `39827795-e05e-4f99-944c-05fd1efdda43`, canonical round `converge`, replayed 144 terminal/platform cells per run and froze an executable replacement-wave contract. Typed verdict: **no winner; replacement wave required**. Candidate selection is false; eligible candidates are empty; Pilot is unauthorized.

The matrix yields 29 PASS, 25 FAIL, and 90 BLOCKED. E04 has 3 FAIL and 45 BLOCKED; E05 21 PASS, 2 FAIL, 25 BLOCKED; E06 8 PASS, 20 FAIL, 20 BLOCKED. Every candidate has exactly 48 required cells with zero missing, unknown, or duplicate cells, so absence cannot hide a failure.

Hard failures include terminal-control leaks in all candidates, E06 bounded rendering in 18/20 cells, incomplete request-ID evidence in E04 and E06, and incomplete identity domains in E04 and E05. E04 renderer coverage; interaction/state/history/Related/recovery; typed 401/404/405/406/422/500/timeout; E04/E05 ETag handlers; capabilities/OpenAPI/help/pagination; and complete error-path request IDs remain BLOCKED.

Two replay manifests are byte-identical at SHA-256 `131925d942020ae2d7de0d238fed43214bdfd274330b2e4ee67a59c845840747`. The leader independently ran the verifier twice; all 24 evidence checks pass with status `PASS_EVIDENCE_NO_WINNER`. Result SHA-256 is `1fc1e64503b4adb8335df8828f4b7811d064127905339f68a205c1c30f64d83b`; artifact set `6d2defd1b94ae6d56ba42c73667b785d78b51c6c45967e6094ef96589e01b8c0`; deterministic archive `a2d1b12cfb125747a297678e7cb424f342e2c446cdf4829cb76767e2a19e2bb4`. Credential scan finds zero hits.

The new wave must implement every contract cell, rerun Attack and Converge, and leave Pilot unauthorized until one candidate passes all 48 cells.

## Cycle payload

```json
{"assignment_id":"restart-experiment-12","assignment_uuid":"39827795-e05e-4f99-944c-05fd1efdda43","round":"converge","verdict":"CONVERGE_NO_WINNER_REPLACEMENT_WAVE_REQUIRED","candidate_selected":false,"eligible_candidates":[],"pilot_authorized":false,"matrix":{"pass":29,"fail":25,"blocked":90},"candidate_nonpass":{"E04":48,"E05":27,"E06":40},"cells_per_candidate":48,"proxy_passes":0,"artifact_set_sha256":"6d2defd1b94ae6d56ba42c73667b785d78b51c6c45967e6094ef96589e01b8c0"}
```
