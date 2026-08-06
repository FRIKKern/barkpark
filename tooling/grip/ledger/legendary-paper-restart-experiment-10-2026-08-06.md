<!-- doc-tier: cold | canonical-for: legendary-paper-restart-experiment-10 | budget: 1500tok -->
# Restart Experiment 10 — core and migration convergence

Assignment `restart-experiment-10`, UUID `a91f9813-3b34-4f62-96ff-8d817d5544f6`, canonical round `converge`, independently reproduced the rejection evidence and froze a replacement-wave repair contract. Typed verdict: **no winner; replacement wave required**. Candidate selection is false and Pilot is unauthorized.

All ten E07 preservation/schema hard failures reproduce in two byte-identical runs. E08 remains 32 PASS, 24 FAIL, 52 BLOCKED; E09 remains 30 PASS, 23 FAIL, 88 BLOCKED with three terminal-control leaks and eighteen E06 width failures. E04, E05, and E06 each retain hard FAIL and/or BLOCKED cells under unchanged zero thresholds.

The executable repair manifest freezes seven mechanisms: explicit alias-conflict quarantine, recursive malformed-structure validation, width 1/20/40/80/120 long-token geometry, revision-fenced write CAS, exact rollback and quarantine, terminal sanitization, and five real-reader adapters. Evidence is preserved; no failed gate is deleted or averaged away.

The leader independently ran the verifier twice. Both runs pass all 27 evidence checks byte-identically at SHA-256 `7db758e05c475b64012dab6da1cbc1cd72da82d0f2bf8d07de8ea4acb08ae703`. Result SHA-256 is `8d600b433db83741fb9a60ad41728d23e4912819b61616849223b61366f90de7`; deterministic evidence archive `552c5b7b9d9a854ac086ec9f697bb9132a67687b45acf32f6cec23d8a984d1a8`. Credential scan found zero hits across 37 files.

This wave must close unsuccessful. A new immutable wave must implement and attack the repair manifest before any Pilot assignment exists.

## Cycle payload

```json
{"assignment_id":"restart-experiment-10","assignment_uuid":"a91f9813-3b34-4f62-96ff-8d817d5544f6","round":"converge","verdict":"CONVERGE_COMPLETE_NO_WINNER_REPLACEMENT_WAVE_REQUIRED","candidate_selected":false,"winner":null,"pilot_authorized":false,"e07_hard_failures_reproduced":10,"e08":{"pass":32,"fail":24,"blocked":52},"e09":{"pass":30,"fail":23,"blocked":88,"control_leaks":3,"width_failures":18},"repair_mechanisms":7,"proxy_passes":0}
```
