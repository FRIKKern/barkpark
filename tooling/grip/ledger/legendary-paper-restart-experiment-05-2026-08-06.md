<!-- doc-tier: cold | canonical-for: legendary-paper-restart-experiment-05 | budget: 1500tok -->
# Restart Experiment 05 — shared read-time compatibility core

Assignment `restart-experiment-05`, UUID `656bfc69-da44-4472-842b-b91e74d3925d`, canonical round `diverge`, produced one runnable lossless semantic core with thin adapters. Typed verdict: **candidate blocked on real readers**. It is not selected.

All four raw captures remain byte-exact. The core preserves 815/815 blocks, 113/113 authored headers, 1,374/1,374 body cells, 388/388 marks, and all 406 CCH29 nested-list words. Twenty deterministic adapters cover public, Studio, TUI80, email, and CLI/API; four identity/cache receipts keep document, release, cache, and Cycle domains distinct. TUI80 and CLI/API isolated probes pass. Candidate removal is path-bounded, with zero production writes and unchanged source.

Twelve real-reader cells remain explicitly BLOCKED: authenticated Studio 4/4, public browser plus assistive technology 4/4, and delivered mail clients 4/4. They are never proxy-passed. Local mechanism gates have zero failures, but the candidate is ineligible until those target readers clear every zero threshold.

The leader independently ran the verifier twice. Both returned `E05 VERIFY PASS` with artifact set `eb78ab36905540dec97510a47e331ffcdfe2ce2574de5fb52ec6995f83ef6946`. Twice-identical replay manifest SHA-256 is `9fc3b298fc930a551753060756d38ca4c67d1eeff8025a404ef059544f9df1d8`; current result SHA-256 `f18715a45347f127a0fc4eee5cb73ce7beed69f0037d1c531dd462471871a670`; deterministic evidence archive `0d47bf80fabfbc1f38a52630b03a5397b89dbe95674ea76f563465eb1212d4f2`. Credential scan found zero hits across 35 files.

Attack may carry this candidate only as runnable BLOCKED evidence. Static adapters do not establish authenticated, delivered, or assistive-technology behavior.

## Cycle payload

```json
{"assignment_id":"restart-experiment-05","assignment_uuid":"656bfc69-da44-4472-842b-b91e74d3925d","round":"diverge","verdict":"DIVERGE_CANDIDATE_BLOCKED_REAL_READERS","candidate_selected":false,"preservation":"815/815 blocks; 113/113 headers; 1374/1374 body cells; 388/388 marks; 406/406 nested-list words","adapter_units":"20/20","blocked_real_reader_cells":12,"local_hard_gate_failures":0,"proxy_passes":0,"artifact_set_sha256":"eb78ab36905540dec97510a47e331ffcdfe2ce2574de5fb52ec6995f83ef6946"}
```
