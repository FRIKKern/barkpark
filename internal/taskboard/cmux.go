package taskboard

// cmux.go — the CMUX × Barkpark bridge worker-id substrate (task-TUI epic,
// wave 14). ONE function, honored by every `bp cmux` subcommand and matched by
// the install shell-line's `export BARKPARK_WORKER_ID=cmux-$CMUX_SURFACE_ID`.
// See .claude/jobs/.../cmux-bridge-design.md §1.

import "os"

// CmuxWorkerPrefix is the ONE worker-id namespace for cmux panes. Tier-2 and
// tier-3 of CmuxWorkerID prepend it, and the `bp cmux install` shell-line plus
// its help echoes derive from it too. Keeping every site on this single constant
// is the whole point of the slice: a prefix rename touches ONE place and both the
// hook's derivation and the installed shell export move together, so an installed
// pane can never claim under a worker the hook doesn't recognize.
const CmuxWorkerPrefix = "cmux-"

// CmuxSurfaceExport is the tier-2 worker id with $CMUX_SURFACE_ID left
// unexpanded — the value the install shell-line exports and the help text echoes.
// Deriving it from CmuxWorkerPrefix keeps the PRINTED value equal to what
// CmuxWorkerID() computes for the same surface id (the tripwire proves it).
const CmuxSurfaceExport = CmuxWorkerPrefix + "$CMUX_SURFACE_ID"

// CmuxShellLine is the guarded shell-profile line `bp cmux install` prints: it
// exports the SAME value CmuxWorkerID() derives at tier 2, guarded on
// CMUX_SURFACE_ID so a non-cmux shell never exports a broken/empty worker id
// (outside cmux, CmuxWorkerID falls through to tui-<hostname>).
func CmuxShellLine() string {
	return "# Barkpark: one worker id per cmux pane, derived from the durable surface id.\n" +
		`[ -n "$CMUX_SURFACE_ID" ] && export BARKPARK_WORKER_ID="` + CmuxSurfaceExport + `"`
}

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
		return CmuxWorkerPrefix + s
	}
	if w := os.Getenv("CMUX_WORKSPACE_ID"); w != "" {
		return CmuxWorkerPrefix + w
	}
	return ResolveWorker()
}
