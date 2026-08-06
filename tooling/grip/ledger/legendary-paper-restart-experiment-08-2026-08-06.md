<!-- doc-tier: cold | canonical-for: legendary-paper-restart-experiment-08 | budget: 1700tok -->
# Restart Experiment 08 — public, Studio, and email attack

Assignment `restart-experiment-08`, UUID `ef4bc3aa-adbe-487a-813a-87ba2b27e142`, canonical round `attack`, ran 108 hostile human-reader cells. Typed verdict: **reject all candidates; failed or blocked**. No candidate is selected.

| Candidate | PASS | FAIL | BLOCKED | Verdict |
|---|---:|---:|---:|---|
| E04 write-time migration | 14 | 2 | 20 | reject |
| E05 read-time core | 0 | 20 | 16 | reject |
| E06 versioned projection | 18 | 2 | 16 | reject |
| **Total** | **32** | **24** | **52** | **reject all** |

Local Chrome exercised public and decoded-email adapters at desktop, 390, 320, and 200%-equivalent zoom. It measured DOM semantics, table/callout/landmark structure, focus order, MIME structure, and overflow. E05 tables lack scoped header semantics across static, public-browser, and email-browser cells; all four E05 messages lack `From`, `To`, and `Message-ID`. E04 and E06 fail PDS45 intentionally-headerless-table semantic cells. These are hard failures, not styling preferences.

Authenticated Studio with session expiry/reconnect, delivered mail clients, real assistive-technology reading order, and deployed cache freshness remain explicitly BLOCKED and never receive proxy credit. Browser/decoded-message evidence does not claim those surfaces.

The first browser pair exposed one timeout classification drift and was retained in `nondeterministic-browser-attempt.json`. The official pair, with a corrected timeout, replayed identically at SHA-256 `e1d24ad354e23a1c1819e36d7d584bb80bc7ee9f7b6818f596412b6a77ddaac0`. A first credential scan falsely matched its own private-key regex; that failed attempt is retained. The corrected scoped scan excludes scanner source and its own report, covers twelve evidence files, and finds zero hits.

The leader independently ran the final verifier twice; both returned `E08 VERIFY PASS`. Result SHA-256 is `41338ba91f4d6ad49fdc2d5eb3b523f8e66c78ce2a62129899a53bd308a294f2`; deterministic evidence archive and artifact-set SHA-256 are `3f2b45aadd2fca904c56391ddbde910d58b833b5ecd696bfe5fa4b8a7256d251`. Official replay two took 46.140410833 seconds.

Converge cannot select a candidate. Table semantics, email identity headers, headerless-table handling, and the unavailable real-reader gates require repair and a new authorized Attack.

## Cycle payload

```json
{"assignment_id":"restart-experiment-08","assignment_uuid":"ef4bc3aa-adbe-487a-813a-87ba2b27e142","round":"attack","verdict":"REJECT_ALL_CANDIDATES_BLOCKED_OR_FAILED","candidate_selected":false,"matrix":{"pass":32,"fail":24,"blocked":52},"candidates":{"E04":{"pass":14,"fail":2,"blocked":20},"E05":{"pass":0,"fail":20,"blocked":16},"E06":{"pass":18,"fail":2,"blocked":16}},"replay_sha256":"e1d24ad354e23a1c1819e36d7d584bb80bc7ee9f7b6818f596412b6a77ddaac0","credential_scan":"PASS_ZERO_HITS","proxy_passes":0,"artifact_set_sha256":"3f2b45aadd2fca904c56391ddbde910d58b833b5ecd696bfe5fa4b8a7256d251"}
```
