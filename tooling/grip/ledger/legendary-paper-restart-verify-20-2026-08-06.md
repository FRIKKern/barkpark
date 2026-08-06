<!-- doc-tier: cold | canonical-for: legendary-paper-restart-verify-20 | budget: 2100tok -->
# Restart Verify 20 — TUI reconnect and schema-refresh recovery

Assignment `restart-verify-20` tested installed and worktree binaries against forced SSE disconnect, a changed schema manifest, one typed 503 query failure, and later successful recovery for each frozen Paper. Verdict: **refuted; 0/8 cells preserve reader state**.

All eight cells begin in the exact Paper reader, scrolled two pages. Both binaries establish a real SSE connection, reconnect after the forced close, and receive two connections per cell. The proxy then returns one typed 503 with a unique request ID before a later successful mutation/query.

The TUI converts the 503 into `Papers 0 / No documents yet` without surfacing the error or request ID in 8/8 cells. Later success returns the Paper only as an unfocused, top-of-document preview with list focus. Exact reader target, focus, and offset recovery therefore pass 0/8. No generic form or false `not_found` is observed; the prohibited result is the silent empty state.

The server-side schema manifest changes at disconnect, but each binary requests schemas only once. Schema refresh passes 0/8. Source behavior matches: API `Query` collapses transport, non-200, and decode failures to nil; pane rebuilding clears the editor and demotes focus; restoration occurs only when the document is immediately re-found; SSE reconnect never calls schema loading. The separate scope/schema reload path explicitly clears path, selection, and focus.

| Contract arm | Observed |
|---|---:|
| Initial exact Paper reader | 8/8 |
| SSE reconnect | 8/8 |
| Typed 503 shown truthfully | 0/8 |
| Silent empty state | 8/8 |
| Schema reload after change | 0/8 |
| Reader target/focus/offset recovered | 0/8 |

The installed binary SHA-256 begins `7d501025` at commit `f59aaf717`; the worktree binary SHA-256 begins `4d2b3536` at repository commit `88857459`. Per-cell traces have the identical route shape: schema1, structure1, query4, injected503×1, SSE2, drop1, failure mutation1, and recovery mutation1, with no unexpected routes.

Direct `document_type_list` navigation is independently broken by Verify15, so the disposable desk used a supported `list_item → document_type_list` carrier to isolate recovery behavior. It did not mutate the product. Evidence is `/private/tmp/bp-rv20.GDbSfT/cells`; evidence-tree SHA-256 is `557dbe4c3926d9225650ea33a17a50f0a558fdd2cb03362c288eaa76ac544f5d`. Authoritative mutations were zero.

## Cycle payload

```json
{"assignment_id":"restart-verify-20","assignment_uuid":"c59373b3-f3b0-4434-8431-7e02bcc2272e","verdict":"refuted","cells":"0/8","initial_reader":"8/8","sse_reconnect":"8/8","typed_503_silently_empty":"8/8","schema_reload":"0/8","reader_state_recovered":"0/8","focus_recovered":"0/8","offset_recovered":"0/8","false_not_found":"0/8 observed","generic_form":"0/8 observed","authoritative_mutations":0,"evidence_tree_sha256":"557dbe4c3926d9225650ea33a17a50f0a558fdd2cb03362c288eaa76ac544f5d"}
```
