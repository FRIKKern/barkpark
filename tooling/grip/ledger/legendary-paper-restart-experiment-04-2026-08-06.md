<!-- doc-tier: cold | canonical-for: legendary-paper-restart-experiment-04 | budget: 1500tok -->
# Restart Experiment 04 — revision-fenced write-time migration

Assignment `restart-experiment-04`, UUID `911a7d27-80a5-4bdd-93a9-5ce33f0d15c1`, canonical round `diverge`, produced a runnable isolated migration candidate. Typed verdict: **mechanism pass; real readers blocked**. It is not selected.

The candidate preserved 815/815 blocks, 113/113 authored headers, 1,374/1,374 body cells, 388/388 marks, all eleven intentionally headerless tables, and all 381 exact-empty boundaries. Thirty-five unambiguous migration actions replayed byte-identically. Revision-CAS conflict and ambiguity quarantine passed; four raw sources rolled back byte-exactly; authored loss, invented intent, schema invalidity, non-idempotence, rollback failure, and proxy passes were zero.

All twenty static adapter receipts were generated across public, Studio, TUI80, email, and CLI/API. They are mechanism evidence only. Deployed public/AT, authenticated Studio, interactive TUI, delivered email clients, and deployed CLI/API were 20/20 BLOCKED and 0/20 passed. Therefore `missing_target_reader` remains a hard failure and this candidate cannot win.

The leader independently ran the verifier twice: 18/18 checks passed both times. Replay tree SHA-256 is `93300914ad6c861b9db6f189fe808eca108f2a49f86c7ac7965e30a9f023eddf`; result SHA-256 `2c2bc61a0c4bf88e44fc16a2451d7d2e0ff2e65b65b42204098fe8dc4e689cee`; artifact set `96821b3c516b7c4b07d1194cd9c66b736cf880b0896c1baf72a059231c0f15fa`; evidence archive `b88f9695187ae0fde99d510009aa824250e9416f9e91857b1f62178d26c895fa`. Credential scan found zero hits.

Attack must exercise deployed revision-fenced writes and credentialed, interactive readers. Adapter success may never substitute for those cells.

## Cycle payload

```json
{"assignment_id":"restart-experiment-04","assignment_uuid":"911a7d27-80a5-4bdd-93a9-5ce33f0d15c1","round":"diverge","verdict":"COMPLETED_MECHANISM_PASS_REAL_READERS_BLOCKED","candidate_selected":false,"preservation":"815/815 blocks; 113/113 headers; 1374/1374 body cells; 388/388 marks","idempotence":"4/4","rollback":"4/4 raw-byte exact","adapter_units":"20/20","real_readers":"0/20 PASS; 20/20 BLOCKED","hard_gate_failures":["missing_target_reader"],"proxy_passes":0,"artifact_set_sha256":"96821b3c516b7c4b07d1194cd9c66b736cf880b0896c1baf72a059231c0f15fa"}
```
