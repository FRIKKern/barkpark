<!-- doc-tier: cold | canonical-for: legendary-paper-restart-experiment-07 | budget: 1500tok -->
# Restart Experiment 07 — preservation and schema attack

Assignment `restart-experiment-07`, UUID `028be543-f502-427c-8940-5d0a6f386b2e`, canonical round `attack`, ran eleven hostile preservation/schema probes against each Diverge candidate. Typed verdict: **Attack complete; no candidate clears all hard gates**. No candidate is selected.

| Candidate | Passed | Failed | Failed probes |
|---|---:|---:|---|
| E04 write-time migration | 8/11 | 3 | malformed list, missing fields, long-token geometry |
| E05 read-time core | 8/11 | 3 | conflicting `header`/`head`, malformed payload preservation, write CAS |
| E06 versioned projection | 7/11 | 4 | conflicting aliases, malformed-list schema, long-token geometry, write CAS |

E04 records two schema failures and one overflow. E05 silently chooses one conflicting alias, loses malformed payload content, and lacks a write-CAS conflict path. E06 fails alias conflict, unconstrained malformed-list schema, public/email long-token geometry, and write CAS. These are frozen hard-gate failures; scores cannot average them away.

All three candidates pass twice-idempotent replay and exact rollback. Each emits quarantine and rollback receipts. Real readers remain BLOCKED with zero proxy passes. The attack tree replayed byte-identically at SHA-256 `a6ca24501dbeff6943843fa645accc0b1d3cf64902c6870ae2aabb5aa04d8394`; the leader independently ran the verifier twice with 13/13 checks PASS. Result SHA-256 is `02ae1d3b66a692fb2179bd89df9c2bf88e6da01570cf7103e65961a299043b42`; deterministic evidence archive `145d2bdcfc8d4358fb9a7b61a7fc913f620f2fd7d38ddaf8905f6d02d989f6be`. Credential scan found zero hits.

Converge must reject or repair the schema, alias, geometry, and CAS failures. The current candidates are not selectable.

## Cycle payload

```json
{"assignment_id":"restart-experiment-07","assignment_uuid":"028be543-f502-427c-8940-5d0a6f386b2e","round":"attack","verdict":"ATTACK_COMPLETE_NO_CANDIDATE_CLEARS_ALL_HARD_GATES","candidate_selected":false,"matrix":{"E04":{"pass":8,"fail":3},"E05":{"pass":8,"fail":3},"E06":{"pass":7,"fail":4}},"idempotence":"3/3","rollback":"3/3","proxy_passes":0,"attack_tree_sha256":"a6ca24501dbeff6943843fa645accc0b1d3cf64902c6870ae2aabb5aa04d8394"}
```
