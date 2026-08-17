# Felix W26 — residue-roster freshness re-derivation (2026-08-17)

Verifier lane [residue-roster-freshness]. Confirms the residue roster holds on
CURRENT origin/main and no concurrent merge paid/claimed any candidate.

PIN: origin/main = 6ea916104c75f5b7364f355b6c94130628f4821f (post-advance from survey's fd6a98d0).

## Re-derivation commands (each row = one claim → one command)

- HEAD pin:
  `git rev-parse origin/main`  → 6ea916104c...

- (a) media.file_path/1 bare Path.join, valid_blob_path? wired ONLY into put_blob:
  `git show origin/main:api/lib/barkpark/media.ex | sed -n '527,529p;603,610p'`
  → file_path = Path.join(upload_dir(), relative_path); valid_blob_path? called only inside put_blob/2.

- (a) two sink controllers route file.path → serve_strategy → local backend → Media.file_path (NO valid_blob_path? on the read path):
  `git show origin/main:api/lib/barkpark_web/controllers/share_link_controller.ex | sed -n '140,145p'`
  `git show origin/main:api/lib/barkpark_web/controllers/tickets_attachments_controller.ex | sed -n '226,230p'`
  → both call `Barkpark.Media.Blobstore.serve_strategy(file.path, ...)`; serve_strategy → impl().serve_strategy → local.ex uses Media.file_path (bare).

- (b) release_capture collect_command 124/125 (+126) branches untested:
  `git show origin/main:api/lib/barkpark/cycle_fleet/release_capture_adapter.ex | sed -n '303,326p'`  → {"",125} on cap, {"",124} on deadline, {"",126} rescue.
  `git grep -n 'collect_command\|@max_command_output_bytes\|exit_status' origin/main -- 'api/test/**' ` → NO hits. branches untested.

- (c) readiness.ex:42 System.cmd, no inline sobelow_skip; skip lives external:
  `git show origin/main:api/lib/barkpark/studio_chat/runtime/codex/readiness.ex | sed -n '38,50p'` → System.cmd at line 42 inside defp version/2, no inline annotation.
  `git show origin/main:api/.sobelow-skips | grep -n readiness` → single entry `CI.System...readiness.ex:42,6CC3DE8` (line MATCHES 42; residue = external-fingerprint vs inline, NOT a line drift).

- Freshness: no advancing commit touched any residue file:
  `git log --oneline fd6a98d0..6ea91610 -- api/lib/barkpark/media.ex api/lib/barkpark/cycle_fleet/release_capture_adapter.ex api/lib/barkpark/studio_chat/runtime/codex/readiness.ex api/.sobelow-skips api/lib/barkpark_web/controllers/share_link_controller.ex api/lib/barkpark_web/controllers/tickets_attachments_controller.ex`
  → EMPTY. (7 commits in range, all connectors/paper-excellence — none residue.)

## Task lifecycle rows (bp task get, dataset default)

| task id | status | claim | verdict |
|---|---|---|---|
| felix-w24-bl-blobstore-runtime-guard | published | none | OPEN/unclaimed |
| task-felix-w18-authority-lock-mutation-proof | published | epoch 6 EXPIRED 2026-07-23, worker=None, digest "DONE building… crit 3 merge-gate open for lead" | OPEN but STRANDED-DONE → close-at-review |
| felix-w19-bl-authority-lock-remaining-sites | published | none | OPEN/unclaimed |
| task-felix-w22-bl-chatlive-overflow-banner | published | none | OPEN/unclaimed |
| task-felix-w22-chatlive-stream-display-cap | published | epoch 6 EXPIRED 2026-07-23, worker=None | OPEN, lapsed null-worker claim |
| task-felix-w22-bl-codex-completion-deadbranch | published | none | OPEN/unclaimed |

NOT FILED AS TASKS (residue (b) release_capture 124/125, residue (c) readiness-inline):
no distinct bp task exists — they are file-level findings only. Decide must file if slicing.

No active felix builder among this session's agents (only cch/dr/connectors builders + review2-*).
