package cli

import (
	"encoding/json"
	"fmt"
	"strings"
)

// tasks_arrears_claim.go — THE ARREARS SHAPE, the exact complement of
// tasks_stranded_claim.go.
//
// tasks_stranded_claim.go reports a row whose claim is still HELD (claim.worker
// non-blank) on a LIVE lease — invisible to both lifecycle doors. This file
// reports the OTHER half of the same lifecycle: the claim is GONE (lapsed or
// released), the row is back in the ready queue and perfectly visible, and it
// is the CRITERIA that are in arrears. The builder stamped N-1, the PR merged,
// and nobody came back for the merge-gated criterion. Nothing about that row is
// broken, nothing refuses it, and so nothing says anything about it — which is
// precisely why the arrears grew: the shape is silent by construction.
//
// MEASURED ON PRODUCTION, 2026-09-17 (cchi-w46-bl-lapsed-claim-arrears-close-path,
// scratch row task-b189f81094ce474a). `bp task release` on a claimed row leaves:
//
//	lifecycle_status: "open"
//	claim.worker:     null          <- the ONLY discriminator the ready gate reads
//	claim.epoch:      2             <- PRESERVED, and BUMPED by the release
//	claim.released_at / released_by: set
//	claim.lease_expires_at:          ABSENT — release strips the horizon
//
// That is the arrears shape on the wire, and it is why a reader cannot key on
// the claim OBJECT (present), on the epoch (present, non-zero), or on an expiry
// (absent). `claim.worker == null` beside `claim.epoch > 0` is the shape, and it
// is the same filter the row's own filing used (`lifecycle_status==open AND
// claim.worker is null AND claim.epoch is not null`).
//
// THE CLOSE PATH IS DIRECT, AND THAT IS ALSO MEASURED. Re-claiming the released
// row took the epoch 2 -> 3 with no release step in between: a lapsed claim is
// DIRECTLY RE-CLAIMABLE. The handle is doc.doc_id — the SLUG. `bp task get
// <uuid>` answers not_found, which is how sweeps lose the very rows they set
// out to pay.
//
// THE TWO SERVER REFUSALS ON THAT PATH ARE CORRECT AND ARE NAMED HERE SO THE
// NEXT SWEEP DOES NOT READ THEM AS BREAKAGE. Both were provoked on the same
// scratch row:
//
//   - `criteria_unmet:0` — close refuses to flip a criterion inside itself
//     ("that would be the closer grading its own homework"). Stamp first.
//   - `merge_gated_criterion` — stamp refuses a DECLARED gate (`merge_gate:
//     true` on the criterion) without `--merge-gated`.
//
// WHY THE NOTICE NAMES THE MERGE GATE SEPARATELY. An arrears row whose unmet
// criterion is an ordinary one is closable by its builder; an arrears row whose
// unmet criterion is a declared gate is NOT, and a worker who reads the generic
// path will hit `merge_gated_criterion` and read it as breakage. The gate line
// is emitted only when an UNMET criterion carries `merge_gate: true` — the
// structural flag, never the prose fallback, because this notice must not
// repeat the 3.5% prose false-positive rate the server's own guard documents.
//
// stderr, in every output mode, beside emitClaimLease and emitStrandedClaim, so
// stdout stays one parseable document. Shape-keyed on the response, so `bp task
// get`, `bp task release` and a `stage` that produces the shape all say it.

// arrearsClaim is a lifecycle-open row whose claim has lapsed or been released
// while criteria remain unmet. Every field is read from the server.
type arrearsClaim struct {
	DocID      string
	Epoch      int
	Unmet      int
	Total      int
	MergeGate  bool
	ReleasedBy string
}

// arrearsClaimStatuses are the lifecycle states in which an unclaimed row is
// genuinely offerable — the same claimable set tasks_stranded_claim.go keys on.
// An `in_progress` row is somebody's live work and is never arrears; a `done` or
// `cancelled` row has left the board.
var arrearsClaimStatuses = map[string]bool{"open": true, "blocked": true}

// arrearsClaimFrom decodes the arrears shape out of a response envelope, looking
// at the raw body and then inside a {"result": …} wrapper — the same two-shape
// walk leaseFromEnvelope and strandedClaimFrom do.
//
// It reports false unless ALL of the following hold:
//
//   - lifecycle is `open`/`blocked`.
//   - a claim object is present with `epoch > 0` — a row NEVER claimed carries
//     no claim at all, and has no arrears to pay.
//   - `claim.worker` is BLANK — the exact complement of strandedClaim. A
//     non-blank worker is either a live holder (stranded, that file's job) or a
//     closed row's preserved holder name.
//   - no close stamp — `close` leaves `closed_at`/`closed_by` behind, and a
//     closed row is not in arrears whatever its criteria say.
//   - at least one criterion is UNMET. A lapsed claim over a fully-stamped row
//     is just an idle row; the arrears IS the unmet criterion.
func arrearsClaimFrom(body []byte) (arrearsClaim, bool) {
	if a, ok := arrearsClaimOf(body); ok {
		return a, true
	}
	return arrearsClaimOf(unwrapResult(body))
}

func arrearsClaimOf(body []byte) (arrearsClaim, bool) {
	var env struct {
		Doc *struct {
			DocID           string `json:"doc_id"`
			LifecycleStatus string `json:"lifecycle_status"`
			Claim           *struct {
				Worker     string `json:"worker"`
				Epoch      int    `json:"epoch"`
				ClosedAt   string `json:"closed_at"`
				ClosedBy   string `json:"closed_by"`
				ReleasedBy string `json:"released_by"`
			} `json:"claim"`
			Content struct {
				AcceptanceCriteria []struct {
					Criterion string `json:"criterion"`
					Met       bool   `json:"met"`
					MergeGate bool   `json:"merge_gate"`
				} `json:"acceptance_criteria"`
			} `json:"content"`
		} `json:"doc"`
	}
	if json.Unmarshal(body, &env) != nil || env.Doc == nil || env.Doc.Claim == nil {
		return arrearsClaim{}, false
	}
	d, c := env.Doc, env.Doc.Claim
	if !arrearsClaimStatuses[strings.TrimSpace(d.LifecycleStatus)] {
		return arrearsClaim{}, false
	}
	if c.Epoch <= 0 || strings.TrimSpace(c.Worker) != "" {
		return arrearsClaim{}, false
	}
	if strings.TrimSpace(c.ClosedAt) != "" || strings.TrimSpace(c.ClosedBy) != "" {
		return arrearsClaim{}, false
	}
	a := arrearsClaim{
		DocID:      strings.TrimSpace(d.DocID),
		Epoch:      c.Epoch,
		ReleasedBy: strings.TrimSpace(c.ReleasedBy),
	}
	for _, crit := range d.Content.AcceptanceCriteria {
		a.Total++
		if crit.Met {
			continue
		}
		a.Unmet++
		if crit.MergeGate {
			a.MergeGate = true
		}
	}
	if a.Unmet == 0 {
		return arrearsClaim{}, false
	}
	return a, true
}

// arrearsClaimLines renders the notice: the shape, the discriminator that makes
// it invisible, and the close path keyed to THIS doc_id. The counts are printed
// because "one criterion short" is the population this row is about, and a
// reader deciding whether to pay it now needs the number, not an adjective.
func arrearsClaimLines(a arrearsClaim) []string {
	by := ""
	if a.ReleasedBy != "" {
		by = fmt.Sprintf(" (last released by %s)", a.ReleasedBy)
	}
	lines := []string{
		fmt.Sprintf("bp: CRITERIA IN ARREARS — %s is lifecycle-open with a LAPSED claim (claim.worker is null, claim.epoch=%d survives)%s and %d of %d criteria still unmet. Nothing refuses this row and the ready queue offers it normally, so nothing else will ever mention the arrears.",
			a.DocID, a.Epoch, by, a.Unmet, a.Total),
		fmt.Sprintf("  pay it: bp task claim %s <worker> --yes  — a lapsed claim is DIRECTLY re-claimable; no release step is needed. The handle is the doc_id SLUG above: `bp task get <uuid>` answers not_found, which is how sweeps lose these rows.",
			a.DocID),
		"  then STAMP before you close: `bp task close` refuses a criterion flipped inside itself (code criteria_unmet:N) — that refusal is CORRECT, not breakage. Stamp each one as you prove it, wording from a FILE: bp task stamp <id> <worker> <epoch> --criterion N --met --criterion-text-file <file> --evidence \"…\".",
	}
	if a.MergeGate {
		lines = append(lines,
			"  MERGE GATE: an unmet criterion here carries \"merge_gate\": true, so a plain stamp is refused with code merge_gated_criterion — also CORRECT. The LEAD stamps it with --merge-gated, and only after the four-part check on THIS row: PR merged, merge commit an ancestor of origin/main, the gate green on the PR head, and the artifact actually present on main. One row at a time; a batch close fabricates a done.")
	}
	return lines
}

// emitArrearsClaim prints the notice for a 2xx whose document carries the
// arrears shape. Called from runCommand's post-2xx hook beside
// emitStrandedClaim — the two are mutually exclusive by construction
// (claim.worker blank here, non-blank there), so no envelope ever gets both.
func emitArrearsClaim(out *writer, respBody []byte) {
	if a, ok := arrearsClaimFrom(respBody); ok {
		for _, line := range arrearsClaimLines(a) {
			out.errf("%s", line)
		}
	}
}
