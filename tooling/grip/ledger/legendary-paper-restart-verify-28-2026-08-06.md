<!-- doc-tier: cold | canonical-for: legendary-paper-restart-verify-28 | budget: 2100tok -->
# Restart Verify 28 — append-only availability and traceability

Assignment `restart-verify-28` completed twenty strict sequential rounds over four frozen Papers and seven routes. Verdict: **refuted as an availability/traceability conjunction**. One unretried connection reset occurred and carried no request ID, so the non-client failure cannot join server logs.

| Measure | Observed |
|---|---:|
| Planned / observed cells | 560 / 560 |
| Unique sequence IDs | 560/560 |
| Cells per round | 28 × 20 |
| HTTP 200 / 5xx | 559 / 0 |
| Curl/subprocess timeouts | 0 |
| Transport failures | 1 |
| Hidden retries | 0 |
| Successful unique request IDs | 559/559 |
| Failed request IDs | 0/1 |
| Successful content unchanged | 559/559 |

At sequence 292, round 11, CCH29 `email_flat`, curl returned connection reset by peer, status zero, empty headers/body, and no request ID. The cell was preserved append-only and never replayed. The literal zero-timeout subclaim passes, but the broader zero non-client failure and traceability gates fail.

All 28 Paper×route successful semantic domains had cardinality one. The pair ledger contains 560/560 observations and 28 frozen baselines. For public HTML, raw hashes vary with request-scoped material; its declared semantic boundary is visible text after entity decoding and whitespace collapse, excluding script/style. Source comparison uses exact ordered canonical `source.blocks`. Raw headers and bodies remain preserved separately for every cell.

Deployment identity stayed at commit `b73723b7e`, version 0.2.25.2450, with database/migrations/plugins unchanged; status objects differed only by `checked_at` and uptime. All four Paper revisions, block counts, and source hashes matched before/after. Epic Task, Cycle authority, and campaign Paper raw JSON were byte-equal before/after.

Content, Task, Paper, Cycle, and tracked-repository mutations were zero. Literal zero server-row mutation remains unprovable because authenticated GETs may touch token `last_used`; this side effect is explicitly carried. Credential strings occurred in zero evidence files. Local HEAD remained `e80d068fff75d984d4444e51b9d89f516472e8d9` with empty tracked/staged diff.

Evidence root is `/private/tmp/bp-restart-verify28.132bebc5-20260806T0953Z`. Matrix SHA-256 is `eb47944871f43d70c333268f79a6df8d37eda613d951eb1c640bbc2fd55c7448`; pair-ledger SHA-256 is `4b0d062e5a81bf852984b31468019485b1c3c09cd9b893ba15aa8cfc6480bece`; summary SHA-256 is `56ec3d2819b4d1a7f765b71306c0ce259a9153c44590ada26b32acdffb62e1d0`; before/after content SHA-256 is `a764c477c3a3099160ce7645e66ea991fd85b31957a12aea89e1649e59639abb`; full manifest SHA-256 is `9420b504d478f27ed17f99c38369ab3ff1736e27fa2d9b86d31322cc64e19c6f`.

## Cycle payload

```json
{"assignment_id":"restart-verify-28","assignment_uuid":"132bebc5-86c5-44be-9a4a-5bc331610a0d","verdict":"refuted_non_client_failure_untraceable","cells":{"planned":560,"observed":560,"http_200":559,"http_5xx":0,"curl_timeouts":0,"transport_failures":1,"hidden_retries":0},"traceability":{"success_request_ids_unique":"559/559","failure_request_ids":"0/1"},"content":{"successful_unchanged":"559/559","paper_before_after":"4/4"},"deployment":{"commit":"b73723b7e","version":"0.2.25.2450","identity_stable":true},"mutations":{"content_task_paper_cycle":0,"tracked_repo":0,"literal_server_rows":"unprovable_token_last_used"},"matrix_sha256":"eb47944871f43d70c333268f79a6df8d37eda613d951eb1c640bbc2fd55c7448"}
```
