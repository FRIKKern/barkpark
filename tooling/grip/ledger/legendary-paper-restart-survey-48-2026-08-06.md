<!-- doc-tier: cold | canonical-for: legendary-paper-restart-survey-48 | budget: 1400tok -->
# Restart Survey 48 — PDS45 CLI/API negative capability

Assignment `restart-survey-48` challenged `pds-wave-45-2026-08-03::cli_api` at exact revision `b992fd8aaa028b0dab30a8da76f077fd`. Verdict: **partial**. Exact machine projections/query/history replay are proven, while history limits, content negotiation, perspective validation, auth-error preservation, JSON-mode parse errors, and schema completeness are contradicted.

Published/drafts/raw Paper and doc-get projections are identical: 392,184 bytes/SHA `5894db69…aa7`, 227 blocks, canonical block SHA `5c9e77f2…c673`. Filtered query retains exact identity/content. Newest history UUID replays exactly.

Negative controls:

- `doc history --limit 1|2|5|10` always returns ten records.
- Public source returns JSON under `Accept: text/html`; JSON, vendor JSON, and plain text return 406 `internal_error`.
- Source silently accepts `perspective=sideways`, identical to published/drafts/raw.
- Scoped direct doc API correctly returns 403 without/with invalid bearer.
- Manifest `doc get` declares auth tier none and succeeds despite invalid token/unknown workspace/project; this is surface-contract divergence, not a proven bypass.
- Invalid-bearer `paper view` converts upstream 403 into `not_found`, rc4.
- Invalid CLI perspective under JSON mode emits human usage text, rc2.
- Path-like malformed identifiers do not escape routes; built-in Paper error double-wraps upstream JSON.
- Live Paper schema has seven metadata fields and omits blocks/PortableDoc dialect.

Ordinary reads use one request with a five-second timeout and no retry loop. Immediate refusal fails clearly; slow live timeout/retry remains unvisited. Fresh `CGO_ENABLED=0 go test ./internal/apiclient ./internal/cli` passed, but deployed contract failures remain. No mutation occurred.

## Cycle payload

```json
{"assignment_id":"restart-survey-48","unit":"pds-wave-45-2026-08-03::cli_api","verdict":"partial","claims":{"exact_projections":"proven","query":"proven","newest_revision":"proven","history_limit":"contradicted","accept_negotiation":"contradicted","perspective_validation":"contradicted","scoped_auth":"proven","surface_auth_consistency":"partial","forbidden_error_preservation":"contradicted","json_parse_errors":"contradicted","schema_complete":"contradicted","timeout_retry":"partial"},"paper":{"rev":"b992fd8aaa028b0dab30a8da76f077fd","sha256":"5894db69f3d9ddc0416bd5e5e6b50dc72c1d962efb56ac7fd863b1a8d1caa7","blocks":227},"tests":{"packages":["./internal/apiclient","./internal/cli"],"passed":true},"mutations":0}
```
