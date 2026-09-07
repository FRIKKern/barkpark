package cli

import (
	"encoding/json"
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
// refusal body's `details` still carries nothing that tells these apart, but it
// is NOT causeless: the server sends a top-level `arm` beside `reason`
// (not_ready_arm/2 — "held_by_other" | "queue_gated" | "not_claimable_status" |
// "unknown") and a message to match. A named arm is a positive reason already
// stated, and claimVerdict must not contradict one.
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
	diagnoseClaimConflict(out, ctx, req, out.lastErrorArm)
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
func diagnoseClaimConflict(out *writer, ctx manifest.Context, req claimRequest, serverArm string) {
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
	case apiclient.DocReadForbidden:
		// The read-back was REFUSED, not missed. Saying "may simply be
		// unreachable" here sent operators to check the network for what is a
		// credentials/permissions answer the server gave in full.
		out.errf("diagnosis: the store refused the read-back of %s (not signed in, or this token has no access) — the refusal is an auth answer, not evidence about the claim", req.docID)
		return
	case apiclient.DocReadServerError:
		out.errf("diagnosis: the store errored reading %s back — the server is up but broken on this read, so this says nothing about whether the row is claimable", req.docID)
		return
	default:
		// Every remaining non-OK class (transport error, unreadable body, any
		// other non-2xx). A default arm, not a DocReadUnreachable case: a new
		// outcome must never fall through to the read-back line below and
		// report a ZERO document as if it had been read.
		if outcome.Failed() {
			out.errf("diagnosis: could not read %s back to explain the refusal — %s, so this is not evidence the row is unclaimable", req.docID, outcome.Describe())
			return
		}
	}
	lifecycle := doc.ContentString("lifecycle_status")
	claim := doc.ClaimInfo()
	out.errf("diagnosis: read-back of %s — lifecycle_status=%s claim.worker=%s released_at=%s expired_at=%s",
		req.docID, orNoneStr(lifecycle), orNoneStr(claim.Worker), orNoneStr(claim.ReleasedAt), orNoneStr(claim.ExpiredAt))
	out.errf("  %s", claimVerdict(req.workerID, lifecycle, claim, queueGateOf(doc), serverArm))
}

// queueGate is content.queue_gate as the read-back holds it: the AUTHOR's own
// hold on the row, evaluated by the server BEFORE lifecycle readiness
// (Barkpark.Tasks.Claim → QueueGate, rendered by not_ready_arm's "queue_gated"
// arm). It is a condition that makes a refusal legitimate, and the read-back
// never looked at it — which is how a correctly-refused human_gated row was
// told, in the same breath, that its refusal was "not a legitimate refusal".
type queueGate struct {
	State  string
	Reason string
}

// gating reports whether this gate is, by itself, a sufficient reason for the
// refusal. Absent gate and the explicitly-executable state are not; every other
// persisted state ("human_gated", "parked", "evidence_stalled" — and any state
// this build has not heard of) is. UNKNOWN STATES COUNT AS GATING on purpose:
// the failure mode being closed here is a local guess overruling a server
// answer, so a state we cannot classify must silence the guess, not license it.
func (g queueGate) gating() bool {
	return g.State != "" && g.State != "executable"
}

// queueGateOf reads content.queue_gate off the read-back document. A missing,
// null or mis-shaped gate reads as the zero queueGate (not gating) — the same
// tolerance ClaimInfo applies, so one odd field costs the gate line and never
// the diagnosis.
func queueGateOf(doc apiclient.Doc) queueGate {
	raw, ok := doc.Extra["queue_gate"]
	if !ok {
		return queueGate{}
	}
	var g struct {
		State  string `json:"state"`
		Reason string `json:"reason"`
	}
	if err := json.Unmarshal(raw, &g); err != nil {
		return queueGate{}
	}
	return queueGate{State: strings.TrimSpace(g.State), Reason: strings.TrimSpace(g.Reason)}
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
// It never claims more than the read-back can prove.
//
// THE INVARIANT: never print "not a legitimate refusal" before checking
// legitimacy. The speculative arm below is the ONE sentence in this CLI that
// asserts a refusal is illegitimate (derivation in the PR: grep for "not a
// legitimate" / "does not match a real" across internal/cli), and it used to be
// the DEFAULT for "no holder, lifecycle open". Two conditions that make such a
// refusal entirely legitimate were never consulted:
//
//   - content.queue_gate — an AUTHOR's hold, which the server evaluates FIRST
//     and which no retry and no holder-field ever reflects. Measured live on
//     task-ed7ae8110c7c8b41: the server said "queue_gate state is human_gated —
//     gated by its AUTHOR", and this function answered, one line later, that
//     the refusal was not legitimate and named an unrelated server bug. What
//     that recommends is an override of a gate the author set deliberately.
//   - the refusal's own `arm` — the server's machine-readable name for which
//     gate fired. A NAMED arm is a positive reason already stated; the local
//     read-back has strictly less information than the predicate that refused,
//     so it may report, never overrule.
//
// The speculation survives for the case it was written for: `arm` absent or
// "unknown" AND no queue gate AND an open row — a refusal with no explanation
// anywhere, which is what task-eb2b6170e19f1611 tracks.
func claimVerdict(requestedWorker, lifecycle string, claim apiclient.ClaimInfo, gate queueGate, serverArm string) string {
	hasWorker := claim.Present && claim.Worker != ""
	if !hasWorker {
		if gate.gating() {
			v := fmt.Sprintf("queue_gate state is %q — this row is gated by its AUTHOR, not by readiness, and no retry will change that", gate.State)
			if gate.Reason != "" {
				v += fmt.Sprintf("; content.queue_gate.reason says: %s", gate.Reason)
			}
			return v
		}
		if lifecycle != "" && !openLifecycleStates[lifecycle] {
			return fmt.Sprintf("genuinely not ready: lifecycle_status is %q, not an open/claimable state", lifecycle)
		}
		if serverArm != "" && serverArm != "unknown" {
			return fmt.Sprintf("the refusal named its own cause (arm=%q) and the read-back finds no holder — the server's answer stands; this read-back adds no evidence against it", serverArm)
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
