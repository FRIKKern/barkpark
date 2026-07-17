#!/usr/bin/env bash
# boundary-setup.sh <cell-worktree>
#
# Stage the boundary chore ("where Scaffy loses"): re-introduce the ExecRunner
# deadline bug by reverting internal/agent/report.go + report_test.go to their
# state BEFORE the fix commit 4adadf0e0 ("fix(agent): bound ExecRunner.Run with an
# internal deadline"). The duel arm must re-derive the fix by JUDGEMENT — no scaffy
# command expresses it (arm C = no expression, D65).
#
# Gate for the boundary arm (D67), checked by run-cell.sh + a human reviewer:
#   * go vet ./internal/agent/...
#   * go test ./internal/agent/... -count=1  (must pass = deadline restored)
#   * reviewer confirms the arm's new test covers BOTH stuck-command-times-out AND
#     fast-path-unchanged, and the CommandRunner interface signature is untouched.

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

WT="${1:?usage: boundary-setup.sh <cell-worktree>}"
[[ -d "$WT/.git" || -f "$WT/.git" ]] || die "not a worktree: $WT"

FIX_COMMIT="4adadf0e0"
note "reverting internal/agent/report.go + report_test.go to ${FIX_COMMIT}~1 (pre-fix, bug re-introduced)"
git -C "$WT" checkout "${FIX_COMMIT}~1" -- \
  internal/agent/report.go \
  internal/agent/report_test.go \
  || die "checkout of pre-fix boundary files failed"

note "boundary bug staged in $WT — the arm must restore the deadline by hand"
git -C "$WT" --no-pager diff --stat -- internal/agent/ >&2 || true
