<!-- doc-tier: cold | canonical-for: legendary-paper-verify-21-evidence | budget: 1800tok -->
# Verify 21 — missing Paper resource contracts

Verdict: `proven`. Missing HTML, source, document, history, and revision resources do not share one status, body, authentication, or error contract. Immediate retries separated stable family behavior from intermittent 500s.

| Resource family | Stable missing result | Machine diagnostics |
| --- | --- | --- |
| flat/scoped HTML | 404 HTML error page | request-id header only |
| public/scoped source | 404, exact plain body `not found` | no Content-Type, code, hint, or body request ID |
| v1 document | 404 canonical JSON | code, message, hint, request ID |
| history | 200 `{"count":0,"revisions":[]}` | absence is an empty collection |
| revision | 404 canonical JSON | resource-specific message, hint, request ID |

Authentication ordering also differs. Flat private history/revision reads return 401 anonymously, while scoped reads return 403 because scope resolution precedes token enforcement. Flat public document/source reads treat a bad bearer as anonymous; Default scoped source can also succeed anonymously, while scoped document access remains 403.

CLI behavior splits by command family:

- `doc get` and `doc revision -o json` preserve canonical code, hint, and request ID with exit 4.
- `doc history` returns the empty collection with exit 0.
- rendered `paper view` uses the source route and reports only plain 404 text.
- JSON `paper view` uses the document route but synthesizes a top-level error from a clipped nested message, losing the server hint and request ID.
- forced human document/revision output shows message and hint; verbose mode also prints code and request ID.

The code seams match the observations. `BulldocsSourceController` explicitly sends `404, "not found"`; `HistoryController.index` always returns a collection; revision lookup and v1 document fallback use the canonical error envelope. In Go, `paper view` has separate source/document fetch paths and its local `paperError` retains only code/message, while manifest-driven document commands use central classification and rendering.

Focused Go API-client and CLI error/Paper tests pass. Phoenix tests were source-inspected but could not run because test dependencies were absent; no dependency installation was performed in this read-only lane. Existing source tests explicitly pin the plain source 404. Intermittent HTML and bad-token 500s recovered immediately to byte-stable family outcomes and remain a separate operational-reliability risk.

No repository, Paper, task, or Cycle state was mutated by the verifier. Evidence was collected at clean commit `25caab758e23407e270e7fe0434bd7487de5afb8`.
