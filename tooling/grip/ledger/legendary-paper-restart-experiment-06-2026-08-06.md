<!-- doc-tier: cold | canonical-for: legendary-paper-restart-experiment-06 | budget: 1600tok -->
# Restart Experiment 06 — versioned canonical projection

Assignment `restart-experiment-06`, UUID `1ecba0d8-c709-47f5-8bf8-a230d6bef4c2`, canonical round `diverge`, produced a runnable versioned projection with explicit schema, provenance, validators, and adapters. Typed verdict: **runnable candidate with blocked real readers**. It is not selected.

All four raw sources remain byte-exact. The v1 projection preserves 815/815 blocks, 113/113 authored headers, 1,374/1,374 body cells, and 388/388 marks. Static carrier visibility is 12,910/12,910 across five adapters. Six identities per Paper keep document, revision, release, projection, cache, and Cycle domains pairwise distinct; conditional validators pass 24/24. Replay is twice byte-identical, rollback simulation passes, one conflicting alias is quarantined, and source mutations are zero.

Local gates are 11 PASS, 0 FAIL, and 3 BLOCKED. Six real capabilities remain blocked without proxy credit: public browser, authenticated Studio, installed interactive TUI, delivered mail, live CLI/API route behavior, and real assistive technology. Consequently overflow, reading order, and live error taxonomy are not proven. The projection also introduces version-negotiation and lifecycle surface that Attack must justify against the simpler candidates.

The leader independently ran the verifier twice; both returned `PASS_LOCAL_WITH_BLOCKED_REAL_READERS`. Replay manifest SHA-256 is `09bb4b8772b4cc8c2adc4f2ddf8110b9610dfa3c5db85db593e481ba94901f64`; result SHA-256 `01b9f67604a6f4ea8c556c69cfd6feb607864ac7a4ae83641064c80c6dfa5b61`; artifact set `fcf5887b54914efa8f6e15a308c35831b6d6053e4afda7a2a71b8a0176ccbc8a`; evidence archive `46010e307f38939a267d87645650d80319adc8a430f71325d90df986d2d63cac`. Credential scan found zero hits across 53 files.

Attack must test real-reader behavior and projection lifecycle/version negotiation. No format choice is warranted from static completeness alone.

## Cycle payload

```json
{"assignment_id":"restart-experiment-06","assignment_uuid":"1ecba0d8-c709-47f5-8bf8-a230d6bef4c2","round":"diverge","verdict":"RUNNABLE_DIVERGE_CANDIDATE_WITH_BLOCKED_REAL_READERS","candidate_selected":false,"preservation":"815/815 blocks; 113/113 headers; 1374/1374 body cells; 388/388 marks","static_visibility":"12910/12910","validators":"24/24","hard_gates":{"pass":11,"fail":0,"blocked":3},"blocked_real_capabilities":6,"proxy_passes":0,"artifact_set_sha256":"fcf5887b54914efa8f6e15a308c35831b6d6053e4afda7a2a71b8a0176ccbc8a"}
```
