<!-- doc-tier: cold | canonical-for: legendary-paper-restart-verify-02 | budget: 1600tok -->
# Restart Verify 02 — sequential reader-route stability

Assignment `restart-verify-02` ran the frozen 480-request sequential public/email route matrix without retries. Verdict: **refuted**.

The harness completed 480/480 supported-route probes with no timeout or stall, but preserved one bad response from at least progress checkpoint 144 through the final `bad_so_far:1` summary. Authored-body hash cardinality was exactly one for seven of eight Paper/surface cells. `pds-wave-44-2026-08-03::email` produced two distinct hashes: the known 98,335-byte success body `c46f46e…7645` and intermittent body `a739256f…940d`. This violates both the zero-failure ceiling and the requirement for one authored hash per Paper/surface.

The last six records, 475–480, were all successful, proving the earlier failure remained counted without a retry overwriting it. Eight separate scoped-dataset controls were excluded from the 480 matrix and all returned the expected `404` with request IDs.

The captured tool output retained the aggregate progress and hash summary but truncated the individual failing record. Its exact round, route form, status, and request ID are therefore unavailable and must not be inferred. The evidence is sufficient to refute the strict stability claim and localize the divergent response to PDS44 email, but it is not sufficient for root-cause attribution. A later availability assignment must preserve append-only per-request JSONL so the failing response can be joined to server logs.

No Barkpark or tracked repository mutation occurred. One verifier read-capture temp file remained outside the repository at `/private/tmp/restart-verify-02-task-ls.json`; it contains task-list evidence only and is not part of the result.

## Cycle payload

```json
{"assignment_id":"restart-verify-02","uuid":"0fcdfd3e-0bc3-4581-b823-62df0e10d847","verdict":"refuted","matrix":{"expected":480,"observed":480,"bad":1,"retries":0},"hash_gate":{"passing_cells":7,"total_cells":8,"failed_cell":"pds-wave-44-2026-08-03::email","hash_count":2},"scoped_dataset_controls":{"observed":8,"status_404":8,"counted_in_matrix":false},"evidence_gap":"individual failing record truncated; exact round/form/status/request-id unavailable","mutations":{"barkpark":0,"tracked_repo":0}}
```
