# E09 — evidence truth, idempotence, rollback, and classification safety attack

Canonical Round-3 attack against E04, E05, and E06 using the frozen E03 fixture manifest and thresholds. It runs every candidate twice, compares tracked artifact hashes, checks embedded pre-image restoration, reconciles candidate inputs to E03 raw captures, audits Task classification/authority boundaries, and rejects any dependency on the broken Task pagination path.

Run:

```bash
.omx/state/legendary-experiments/E09/run.sh
```

Expected final verification begins `E09 VERIFY PASS` and reports the explicit `PARTIAL/REWORK` verdict.

The attack intentionally stops classification scoring because the required paired blind records were not sealed before scoring. It does not reconstruct or proxy-pass those records. Authenticated Studio and real-client email remain blocked exactly as frozen by E03. E04 is rejected for guessed/derived Task contract decisions without provenance; E06 is rejected because its dispatcher exercises zero of the six frozen adversarial fixtures; E05 is the strongest non-rejected candidate but remains blocked and is not selected as a winner.

Ordinary replay keeps tracked bytes stable. Fresh wall-clock observations are written only to ignored `.replay/timing.json`; set `E09_REFRESH_TIMING=1` only to intentionally refresh the committed representative timing evidence.
