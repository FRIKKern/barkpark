# V5 — LiveView fence-exception safety (item_share.ex) re-derivation

Verifier row for the ARPSS share-authz wave. Certifies the one-line
`barkpark_web/live` fence exception needed to thread the actor workspace into
`Links.revoke/2` from the LiveView `item_share_revoke` caller is SAFE.

## Claims and how to re-derive each

1. item_share.ex is COLD (last real edit weeks ago, no branch touching it newer):
   ```
   git log origin/main -1 --format='%h %cr %ci' -- api/lib/barkpark_web/live/studio/studio_live/handlers/item_share.ex
   #  => 659f118fc6  6 weeks ago  2026-07-08 16:53:14 +0200  (merged #1504)
   git log --all --oneline -1 -- api/lib/barkpark_web/live/studio/studio_live/handlers/item_share.ex
   #  => same sha across ALL refs — no branch anywhere has a newer commit
   ```

2. No worktree holds uncommitted edits to the file (wave6 builder trees checked):
   ```
   for wt in wf_1e3d0cfb-113-25 wf_1e3d0cfb-113-26 wf_1e3d0cfb-113-27 wf_1e3d0cfb-113-28; do
     git -C ".claude/worktrees/$wt" status --porcelain -- \
       api/lib/barkpark_web/live/studio/studio_live/handlers/item_share.ex; done
   #  => empty everywhere (clean)
   ```

3. Wave6 is SEALED and item_share_revoke was FILED out-of-fence (so no live session owns the file):
   ```
   bp task get api-read-path-security-sweep-wave-6-log -o json
   #  lifecycle_status = "done"; closed_by = decide-w6-liveview; closed_at 2026-08-18T15:52:50Z
   #  close_reason: "... wave Paper api-read-path-security-sweep-wave6-liveview-2026-08-18
   #                 sealed with debrief (grade A), epic wave_status stamped complete ..."
   #  description: "... the item_share_revoke unscoped Links.revoke IDOR (filed out-of-fence) ..."
   ```
   (Wave paper slug is api-read-path-security-sweep-wave6-liveview-2026-08-18 — NOT arpss-wave6-*.)

4. socket.assigns.current_workspace.id is available in the handler:
   ```
   grep -n 'current_workspace' api/lib/barkpark_web/live/studio/studio_live/handlers/item_share.ex
   #  line 49: item_share_create already reads socket.assigns[:current_workspace]
   grep -n 'current_workspace.id' api/lib/barkpark_web/live/studio/studio_live/shared.ex
   #  lines 65,90,120,160: ws_id = socket.assigns[:current_workspace] && socket.assigns.current_workspace.id
   #  studio_live.ex:207 confirms it is a struct: is_map(ws) and is_binary(Map.get(ws,:id))
   ```

5. revoke(id, opts \\ []) is arity-compatible for BOTH callers — exactly two real callers:
   ```
   grep -rn 'Links.revoke\|Sharing.Links.revoke' api/lib api/test internal js
   #  api/lib/.../handlers/item_share.ex:69   Barkpark.Sharing.Links.revoke(id)      <- LiveView, unchanged compiles
   #  api/lib/.../controllers/share_link_controller.ex:220  case Links.revoke(id)    <- HTTP, threads opts[:workspace_id]
   #  api/lib/barkpark/tasks/compactor.ex:469  # (comment only, mirrors ...)
   #  api/test/.../share_link_test.exs:287     # (comment only)
   ```
   Current def: `def revoke(id) when is_binary(id)` (links.ex:91) resolves via bare
   `Repo.get(ShareLink, uuid)` (links.ex:99) — the confirmed unscoped IDOR.
   Default-arg + guard (`def revoke(id, opts \\ []) when is_binary(id)`) keeps the
   LiveView zero-arg-opts call compiling untouched.

VERDICT: fence exception is SAFE. File cold + uncontended, wave6 sealed A with the
finding filed out-of-fence, workspace id available, arity change breaks neither caller.
