<!-- doc-tier: cold | canonical-for: legendary-paper-verify-27-evidence | budget: 1800tok -->
# Verify 27 — document, history, query, and reader identities

Verdict: `refuted` as written; a narrower generic-v1/Go-client discoverability gap is `carried`. Document `_rev` and document ETag are the same identity, query ETag is an explicit hash over ordered document identities, and document↔history joins exist in database pointers plus scoped Paper headers.

Across all four Papers, body `_rev`, response-body `etag`, and HTTP ETag are identical: `18768b0a…`, `49c1534d…`, `b992fd8a…`, and `8bbd5d87…`. Matching validators return GET 304 for 4/4. Query ETags are distinct—`a7247732…`, `0959abc1…`, `4758f10a…`, `27fdc5d2…`—but independently reproduce `sha256("dataset|type|_id:_rev,...")[0:32]`; matching query validators return 304 for 4/4. Cross-use remains 200 in all 12 checks, proving endpoints do not conflate them.

History UUIDs are separate revision-row identities, but the join is explicit. Documents have `current_revision` and `released_revision` foreign keys; revisions have `document_id`. Migration/backfill and an exact-snapshot trigger bind content/type/scope/title/status before advancing pointers; hostile-snapshot and pointer-equality tests cover the contract.

Scoped Paper HTML publishes the public join directly: `X-Barkpark-Paper-Revision` equals newest released history UUID for all four (`eed97c1b…`, `7c1135de…`, `4afe0099…`, `344fe5ee…`), while `ETag: sha256:<digest>` equals canonical revision-content SHA-256. Canonical hashes of get/query/revision/scoped-source/flat-source blocks agree for all four; scoped and flat source bodies are byte-identical.

Other namespaces remain correctly distinct. Source digest hashes `{kind,blocks}` rather than full revision content. `schemaHash=ffd866302af63751` identifies schema state. Cycle Wave revision is release authority and never appears merely because a Paper slug contains `wave`.

The narrower gap is wire discoverability. Generic v1 get/query/history/revision responses omit current/released revision pointers. History/revision expose UUID/doc_id/content but not document `_rev`; a generic consumer cannot join them directly without the scoped Paper header. The Go `Doc` has no typed revision field, leaving `_rev` in extras, and its revision path discards the revision UUID from the returned document. Current API docs omit both the pointer join and scoped revision-header contract.

Separately, scoped HTML advertises the content ETag but returns 200—not 304—to a matching `If-None-Match` in all four samples; its plug stamps headers without conditional handling. Flat public/source/history/revision surfaces advertise no ETag. Live newest==released equality is sample evidence, not an invariant during unreleased edits.

No production DB query was performed; live headers/history plus pinned schema/migration/tests provide the join proof. No repository or Barkpark state was mutated at `f4817bccc9394c51dd19666970992c29e6b71593`.
