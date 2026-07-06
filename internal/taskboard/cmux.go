package taskboard

// cmux.go — the CMUX × Barkpark bridge worker-id substrate (task-TUI epic,
// wave 14). ONE function, honored by every `bp cmux` subcommand and matched by
// the install shell-line's `export BARKPARK_WORKER_ID=cmux-$CMUX_SURFACE_ID`.
// See .claude/jobs/.../cmux-bridge-design.md §1.

import "os"

// CmuxWorkerID derives the task-claim worker id for a cmux pane. The PANE owns
// the task, not the individual agent, so the id is keyed on the durable,
// pane-unique CMUX_SURFACE_ID — invariant for the pane's life and shared by
// every subagent in the pane (they differ only in CLAUDE_CODE_SESSION_ID). That
// means every subagent's claim renews the pane's ONE lease (re-claim under the
// same worker = renewal, never a 409), and the pane holds exactly one fencing
// lease. A session-keyed id would make a subagent collide with the lead.
//
// Four-tier precedence (first non-empty wins):
//
//  1. BARKPARK_WORKER_ID    — explicit override; also what `bp cmux install`'s
//     shell line exports (`cmux-$CMUX_SURFACE_ID`), so the
//     helper stays stable even if CMUX_SURFACE_ID is later
//     cleared.
//  2. cmux-<CMUX_SURFACE_ID>  — the normal path: pane-stable and cmux-scoped with
//     no install step (an ad-hoc `bp cmux status` reads
//     correctly in any raw cmux pane).
//  3. cmux-<CMUX_WORKSPACE_ID> — coarser cmux fallback (pane-not-unique) when a
//     surface id is somehow absent.
//  4. ResolveWorker()        — the existing `tui-<hostname>` convention outside
//     cmux entirely.
//
// Tiers 1 and 4 are consistent: ResolveWorker ALSO honors BARKPARK_WORKER_ID
// first, so outside cmux the final fallback naturally yields `tui-<hostname>`.
// Empty-string env vars (os.Getenv returns "" for unset AND for explicitly
// blank) fall through each guard, never producing a broken `cmux-` id.
func CmuxWorkerID() string {
	if v := os.Getenv("BARKPARK_WORKER_ID"); v != "" {
		return v
	}
	if s := os.Getenv("CMUX_SURFACE_ID"); s != "" {
		return "cmux-" + s
	}
	if w := os.Getenv("CMUX_WORKSPACE_ID"); w != "" {
		return "cmux-" + w
	}
	return ResolveWorker()
}
