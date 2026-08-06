<!-- doc-tier: cold | canonical-for: legendary-paper-verify-19-evidence | budget: 1800tok -->
# Verify 19 — `doc history` and `doc related` limit forwarding

Verdict: `proven`. The CLI silently consumes `--limit` for both commands but does not put it on the request. The deployed APIs honor the same limits exactly, so the defect is client-side.

| Paper | CLI history at 1/3/5 | HTTP history | CLI related at 1/3/5 | HTTP related |
| --- | --- | --- | --- | --- |
| Cloud Console wave 29 | 14/14/14 | 1/3/5 | 10/10/10 | 1/3/5 |
| PDS wave 45 | 10/10/10 | 1/3/5 | 10/10/10 | 1/3/5 |
| Cloud Console wave 28 | 12/12/12 | 1/3/5 | 10/10/10 | 1/3/5 |
| PDS wave 44 | 12/12/12 | 1/3/5 | 10/10/10 | 1/3/5 |

All 24 CLI observations ignored the requested value; all 24 direct HTTP controls returned the requested count. A local capture server observed six real CLI requests at limits 1, 3, and 5. None contained `?limit=`.

The causal chain is exact:

1. `internal/cli/globals.go` globally recognizes and consumes `--limit` anywhere in argv.
2. It records the value only in `g.limit`.
3. `internal/cli/run.go` forwards that global only when `cmd.Paginated` is true.
4. Capabilities declare local `limit` flags for `doc.history` and `doc.related`, but both omit `paginated:true`; omitted metadata defaults false.
5. Therefore global parsing removes the flag before manifest-local binding, then request construction refuses to forward the captured value.

The server is not at fault. `HistoryController` parses and forwards `limit`; `QueryController` forwards it to related-content lookup; related lookup clamps it to 1–50. Direct deployed requests prove those paths.

Focused CLI tests pass but miss the decisive combination: globally recognized `--limit` + manifest-declared local limit + `paginated:false`. Marking both commands paginated is not yet a safe repair because that also enables `--all`, offset behavior, and pagination-envelope validation. Experiment/Build must choose an isolated forwarding contract and add regression coverage for legal flag placements.

No Paper, task, server record, or repository file was mutated by the verifier. Evidence was collected at clean commit `25caab758e23407e270e7fe0434bd7487de5afb8`.
