# Task #38 — Worker notes for STM

## Status
- Branch: `chore/hook-allow-force-push-opt-in` (created from `origin/main`)
- Changes: staged (`git diff --cached --stat` shows 5 files, 102 insertions).
- Tests: all 4 required tests pass — see `proof/task-38/*.txt`.

## Why no commit/push/PR yet
Worker `git commit` was intercepted by the upstream `on-pre-tool-use.sh`
VCS guard (line 1066–1076: `_is_direct_vcs_cmd` → `FORWARDED: VCS request
sent to <Team Lead>`). This is the normal worker → STM hand-off — the
staged tree is ready for STM to commit/push/open PR per the standard
flow. The opt-in flag added in this task (`DOEY_ALLOW_FORCE_PUSH=1`) only
affects `git push --force-with-lease`; it does not change the
worker-VCS-forwarding behavior, by design.

## Recommended STM action
1. `cd /home/doey/GitHub/barkpark && git status` (verify staged tree)
2. Commit with the message in the commit-message draft below.
3. `git push -u origin chore/hook-allow-force-push-opt-in`
4. `gh pr create --title "feat(hooks): add DOEY_ALLOW_FORCE_PUSH opt-in (Task #38)" ...`
5. Write resulting PR URL to `proof/task-38/pr_url.txt`.

## Commit message draft
```
feat(hooks): add DOEY_ALLOW_FORCE_PUSH opt-in (Task #38)

Adds a barkpark-local pre-tool-use hook override at
.claude/hooks/on-pre-tool-use.sh that gates `git push --force-with-lease`
on the per-command env flag DOEY_ALLOW_FORCE_PUSH=1, then falls through
to the upstream doey-repo hook so all other rules (Subtaskmaster role
guards, --no-verify, branch-switch guards, etc.) still execute.

Approach: A — barkpark-local override.
Rationale: the project's .claude/hooks was previously a symlink to
~/.claude/hooks (uncommitted, host-global). Replacing the symlink with a
real, committed directory containing only the override script keeps blast
radius scoped to barkpark and lets other hooks fall through to the
upstream resolver via Claude Code's existing project-then-doey-repo
lookup pattern. Modifying the upstream doey-repo hook (Option B) would
have leaked the opt-in to every project.

Constraints honored:
- Only the lease-protected variant is gated. Unsafe `git push --force`
  (no lease) still blocks unconditionally, even with the flag set.
- A command containing both --force and --force-with-lease is treated
  as unsafe and blocks (sed strips lease tokens, then checks for
  residual --force).
- Uses ${DOEY_ALLOW_FORCE_PUSH:-} so the hook is safe under set -u.
- Adds a single new audit line `allow_force_push_opted_in` on the opt-in
  path; existing _dbg_write lines from the upstream block remain
  unchanged.

Tests (proof/task-38/):
  - syntax.txt: bash -n PASS
  - block_no_flag.txt: lease push without flag → exit 2, blocked
  - allow_with_flag.txt: lease push with flag → exit 0, audit hit
  - unsafe_still_blocked.txt: --force alone, and --force + lease → blocked

Unblocks: PR #60 (rebase-update VCS path).
```

## Risks
- Replaces the prior `.claude/hooks` symlink with a real directory.
  Other Claude Code hooks (post-tool-lint, on-prompt-submit, etc.)
  continue to work because settings.local.json's hook commands fall back
  to `~/.local/share/doey-repo/.claude/hooks/<name>.sh` when the
  project-local file is missing — verified in `settings.local.json`.
- Audit log goes to `${DOEY_DEBUG_DIR:-/tmp/doey/${DOEY_PROJECT_NAME:-barkpark}/debug}/pretool.log`
  to match the upstream `_dbg_write` location convention; if that is not
  exactly where upstream writes, the audit line is still recorded but in
  a parallel log file, not the upstream one. STM may want to consolidate
  if upstream's log path differs.

## Files changed
- `.claude/hooks/on-pre-tool-use.sh` (new, +70)
- `proof/task-38/syntax.txt` (new)
- `proof/task-38/block_no_flag.txt` (new)
- `proof/task-38/allow_with_flag.txt` (new)
- `proof/task-38/unsafe_still_blocked.txt` (new)
- `proof/task-38/NOTES.md` (this file)
