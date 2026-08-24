package cli

import (
	"fmt"
	"strings"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/manifest"
)

// runTaskClaim is the client-side wrapper around the manifest `task claim`
// verb, in the same shape as runTaskStamp: the real POST rides runCommand
// UNCHANGED, and this only ADDS a diagnosis when the claim is refused.
//
// `bp task claim` returns a bare `not_ready` (or a sibling task-claim/close
// contention code — exit 6, docs/cli/error-exit-table.md) for at least three
// operationally different causes: the row is genuinely not ready, someone
// else holds it live, or a STALE-BUT-PRESENT claim.worker was left behind by
// a third writer (`bp task stage` moves lifecycle_status without clearing
// claim.worker) that refuses every id except the original holder. The
// refusal body carries no `details` that would tell these apart (verified:
// classifyError's {"ok":false,"reason":…} branch has no distinguishing
// field for this shape), so a bare "not_ready" reads the same for all three.
//
// This wrapper performs a SECOND read — GET the task doc right after the
// refusal — and renders what the store currently holds. It never asserts a
// cause the read-back cannot support (a read failure says exactly that and
// nothing more); the true predicate is server-side (task-eb2b6170e19f1611
// tracks that half) and this stays purely diagnostic.
func runTaskClaim(out *writer, g globals, ctx manifest.Context, m *manifest.Manifest, cmd manifest.Command, tail []string) int {
	rc := runCommand(out, g, ctx, m, cmd, tail)
	if rc != exitConflict {
		return rc
	}
	// Exit 6 is the WHOLE task claim/close contention row of the exit table
	// (docs/cli/error-exit-table.md:110), and this read-back only explains the
	// reasons that are ABOUT THE TARGET ROW'S CLAIM. resource_conflict is not
	// one: the fence is held by a DIFFERENT row, so reading this row back finds
	// no holder and claimVerdict then announced
	//
	//   "the store shows NO holder and an apparently-open row — this does not
	//    match a real conflict; likely the server-side predicate defect … not a
	//    legitimate refusal"
	//
	// over a refusal that was entirely legitimate and whose holder the server
	// had already named. Measured live: claiming a fresh row with a path another
	// live claim fences printed exactly that, at rc=6, on both channels. Telling
	// an operator a working fence is a known server bug is worse than saying
	// nothing, so the diagnosis stands down and the refusal's own
	// conflicts[]-backed holder lines (classifyError → resourceConflictLines)
	// are what the caller reads.
	if out.lastErrorCode == "resource_conflict" {
		return rc
	}
	req, ok := claimRequestOf(cmd, tail)
	if !ok {
		return rc
	}
	diagnoseClaimConflict(out, ctx, req)
	return rc
}

// claimRequest is what `bp task claim` asked for — the doc it targeted and
// the worker id it claimed under.
type claimRequest struct {
	docID    string
	workerID string
}

// claimRequestOf resolves the SAME docID/workerID the dispatch just sent, via
// the same splitArgs+bindArgs the manifest request builder uses, so the
// diagnosis can never target a different row than the POST that failed.
func claimRequestOf(cmd manifest.Command, tail []string) (claimRequest, bool) {
	pos, _, err := splitArgs(cmd, tail)
	if err != nil {
		return claimRequest{}, false
	}
	argMap, err := bindArgs(cmd, pos)
	if err != nil {
		return claimRequest{}, false
	}
	docID := strings.TrimSpace(argMap["doc_id"])
	workerID := strings.TrimSpace(argMap["worker_id"])
	if docID == "" || workerID == "" {
		return claimRequest{}, false
	}
	return claimRequest{docID: docID, workerID: workerID}, true
}

// diagnoseClaimConflict reads the task doc back and prints ONE extra stderr
// block naming what the store holds, then the verdict claimVerdict derives
// from it. stdout is untouched (the failed POST's -o json/yaml envelope stays
// the single parseable document); this rides stderr exactly like
// emitHelpHints and the stamp wrapper's read-back confirmation.
func diagnoseClaimConflict(out *writer, ctx manifest.Context, req claimRequest) {
	client := apiclient.New(apiclient.Config{
		BaseURL:   ctx.Server,
		Token:     ctx.Token,
		Workspace: ctx.Workspace,
		Project:   ctx.Project,
		Dataset:   ctx.Dataset,
		// "drafts" so a just-moved lifecycle_status/claim (draft overlay) is
		// visible in the diagnosis, not masked behind the published view —
		// the same reasoning GetPerspective's own doc picks for the cmux hook.
		Perspective: "drafts",
	})
	doc, outcome := client.GetPerspectiveResult("task", req.docID, "drafts")
	switch outcome {
	case apiclient.DocReadNotFound:
		out.errf("diagnosis: task %s names no document on read-back — the refusal may have raced a delete/rename", req.docID)
		return
	case apiclient.DocReadUnreachable:
		out.errf("diagnosis: could not read %s back to explain the refusal — the store may simply be unreachable, not necessarily unclaimable", req.docID)
		return
	}
	lifecycle := doc.ContentString("lifecycle_status")
	claim := doc.ClaimInfo()
	out.errf("diagnosis: read-back of %s — lifecycle_status=%s claim.worker=%s released_at=%s expired_at=%s",
		req.docID, orNoneStr(lifecycle), orNoneStr(claim.Worker), orNoneStr(claim.ReleasedAt), orNoneStr(claim.ExpiredAt))
	out.errf("  %s", claimVerdict(req.workerID, lifecycle, claim))
}

func orNoneStr(s string) string {
	if s == "" {
		return "(none)"
	}
	return s
}

// openLifecycleStates are the lifecycle_status values a bare not_ready ought
// to be compatible with — anything else (done, cancelled, blocked, …) is a
// legitimate "genuinely not ready" on its own, independent of any claim.
var openLifecycleStates = map[string]bool{
	"open":        true,
	"considering": true,
	"researching": true,
	"in_progress": true,
}

// claimVerdict is the PURE decision at the center of this wrapper: given what
// the read-back showed and who asked, name which of the causes it supports.
// It never claims more than the read-back can prove — a shape it cannot
// confidently classify gets an honest "does not match a real conflict"
// answer pointing at the known predicate defect, never a guess.
func claimVerdict(requestedWorker, lifecycle string, claim apiclient.ClaimInfo) string {
	hasWorker := claim.Present && claim.Worker != ""
	if !hasWorker {
		if lifecycle != "" && !openLifecycleStates[lifecycle] {
			return fmt.Sprintf("genuinely not ready: lifecycle_status is %q, not an open/claimable state", lifecycle)
		}
		return "the store shows NO holder and an apparently-open row — this does not match a real conflict; likely the server-side predicate defect task-eb2b6170e19f1611 tracks, not a legitimate refusal"
	}
	if claim.Worker == requestedWorker {
		return fmt.Sprintf("the store already lists YOU (%s) as the holder — re-claim under your own worker id to renew the lease", claim.Worker)
	}
	isLive := claim.ReleasedAt == "" && claim.ExpiredAt == ""
	if isLive {
		return fmt.Sprintf("held live by %s — wait for them to release or close it, or ask them to hand it off", claim.Worker)
	}
	return fmt.Sprintf("RELEASED but claim.worker is still stale-set to %s (bp task stage can leave it behind across a lifecycle move) — you are the WRONG WORKER for this stale field; only %s can currently re-enter", claim.Worker, claim.Worker)
}
