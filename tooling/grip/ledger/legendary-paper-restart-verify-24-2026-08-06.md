<!-- doc-tier: cold | canonical-for: legendary-paper-restart-verify-24 | budget: 2100tok -->
# Restart Verify 24 — CLI/API error taxonomy and terminal safety

Assignment `restart-verify-24` combined targeted repository tests, an independent eleven-cell `httptest` overlay, and live controls. Verdict: **refuted with high confidence**. The contract fails independently on false `not_found`, lost header-only request IDs, and raw terminal-control leakage.

Targeted classifier, renderer, JSON-envelope, refusal, and task-stamp tests passed. The overlay then proved gaps outside those assertions:

| Probe | Observed |
|---|---|
| Message-only HTTP 500 containing “not found” | exit 4, empty code: false `not_found` |
| HTTP 503 with header-only `X-Request-ID` | request ID absent from output |
| Hostile JSON request ID in human verbose mode | raw ESC/BEL emitted at four positions |
| Same hostile payload in JSON mode | safely escaped |
| `method_not_allowed` CLI mapping | generic exit 1 |
| Live unsupported `OPTIONS` method | 404 `not_found`, not 405 plus `Allow` |
| Live missing Paper source | bare `not found`; request ID only in header |

Missing, forbidden, refused/conflict, malformed, and body-coded 5xx envelopes preserved their codes and expected exits in the exercised paths. Body-carried request IDs survived all seven applicable local cases. Four applicable canonical live JSON errors matched body and header request IDs. Timeout and connection-refused transport failures both produced `request_failed`, exit 1, with distinguishable messages. A real campaign-Paper control succeeded with 43 blocks and exit 0.

The failures join directly to implementation seams. `internal/cli/errors.go` applies a status-blind message fallback and lacks a `method_not_allowed` exit mapping. `internal/cli/run.go` discards response headers in the generic request path. Human rendering does not sanitize terminal controls. `bulldocs_source_controller.ex` emits a bare missing-source body instead of the canonical typed envelope.

API tests could not run because `api/deps` was absent; live controls and source inspection cover the decisive failures. Residual risk remains that additional endpoints bypass the shared envelope and that existing tests legitimize message-only classification without constraining it by HTTP status. Mutations were zero and the worktree remained clean at `f34d6d9e0f3a3ba16f2e0338da1520a84c02b29c`.

Evidence root is `/private/tmp/bp-restart-verify24.XXWH55`. Probe SHA-256 is `20ce9ecf40d75eff090fb5f2cf525788ec98d5b166d45ec1b7ef3bb325e76da2`; overlay SHA-256 is `b712a3d3736f13180cb92bebdf9d4ab7c32c0fb889dfe5ee4bd09cd586a899ec`.

## Cycle payload

```json
{"assignment_id":"restart-verify-24","assignment_uuid":"4106a881-ac15-46ff-91b2-31ee8c381187","verdict":"refuted","tests":"pass","overlay_cells":11,"false_not_found_500":true,"header_only_request_id_preserved":false,"human_verbose_controls_escaped":false,"json_controls_escaped":true,"method_not_allowed_exit":1,"live_unsupported_method_status":404,"live_missing_source_typed":false,"mutations":0,"probe_sha256":"20ce9ecf40d75eff090fb5f2cf525788ec98d5b166d45ec1b7ef3bb325e76da2","overlay_sha256":"b712a3d3736f13180cb92bebdf9d4ab7c32c0fb889dfe5ee4bd09cd586a899ec"}
```
