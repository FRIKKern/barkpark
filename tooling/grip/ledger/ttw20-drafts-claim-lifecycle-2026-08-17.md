# ttw20 drafts-claim-lifecycle re-derivation recipe (2026-08-17)

Claim: claiming a `drafts.*`-namespaced task writes `content.lifecycle_status="in_progress"`
identically to a plain task — so the ttw19-bl-drafts-now-drop premise is DEAD api-side; nothing
routes cross-fence.

## Re-derive

```
# The single lifecycle write (shared by BOTH claim paths):
git show origin/main:api/lib/barkpark/tasks/claim.ex | sed -n '313,316p'
#   313  new_content =
#   314    doc.content
#   315    |> Map.put("lifecycle_status", "in_progress")   <-- unconditional, no namespace branch
#   316    |> Map.put("assignee", worker_id)

# Both paths land in do_claim -> do_claim_resolved (the block above):
git show origin/main:api/lib/barkpark/tasks/claim.ex | grep -n 'do_claim(\|defp do_claim\|defp do_claim_resolved'
#   44   do_claim(doc, worker_id, [], opts)       (queue claim)
#   103  do_claim(doc, worker_id, resources, opts) (claim_by_id)
#   242  defp do_claim ...
#   284  defp do_claim_resolved ...  -> line 315 write

# `drafts.` is a doc_id PREFIX, not a schema/namespace. It only affects RESOLUTION:
git show origin/main:api/lib/barkpark/tasks/claim.ex | sed -n '119,140p'
#   fetch_task_by_doc_id: exact doc_id first; if not found AND no drafts. prefix,
#   retry with "drafts." <> doc_id. Resolves to a normal type=="task" Document,
#   then do_claim proceeds — the content write does not read doc_id.
```

Verdict: DROP PREMISE REFUTED api-side. drafts.* claims get in_progress. Slice ttw19-bl-drafts-now-drop
is purely an in-fence NOW-completeness ruling (board.go:357 client gate + the limit=1000 window). No
api/ cross-fence paperwork owed.
