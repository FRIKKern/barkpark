package cli

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

// tasks_stranded_claim.go — THE INVISIBILITY WINDOW.
//
// A task row that leaves `in_progress` WITHOUT being closed keeps its claim
// map. `bp task stage <id> open` is the ordinary door to that state (Stage
// "never reads or writes `content.claim`"), and the row it leaves behind is
// lifecycle-open, still wearing a dead holder's name, with a LIVE lease. Such a
// row is invisible to BOTH lifecycle surfaces at once:
//
//   - `bp task pulse` refuses it — `not_in_progress:open`, nothing written. So
//     nothing heartbeats it.
//   - `bp task ready` / `bp task next` withhold it —
//     `Barkpark.Tasks.QueueGate.executable_query/0`, whose first four arms admit
//     a row only when `claim.worker` is BLANK, or a close stamp is present, or
//     `claim.ts_iso` has aged past `:task_lease_ttl_seconds`. A live lease
//     satisfies none of them. So nobody is offered it.
//
// MEASURED ON PRODUCTION, 2026-09-15 (task-d790755a7eeac639). Two scratch rows
// were claimed and staged back to `open`; a FULL `bp task ready --all` page
// (916 ids) held neither. Releasing one of them — which keeps the claim OBJECT,
// its epoch and its `ts_iso` and only nulls `claim.worker` — put it in the very
// next read of the same page (917 ids), 62 seconds into a 2700-second lease.
// That isolates the discriminator: the CLAIM OBJECT does not withhold a row,
// `claim.worker`'s VALUE does, for exactly as long as the lease runs.
//
// THE SWEEPER DOES NOT SHORTEN THE WINDOW. `Tasks.TtlSweeper` selects only
// `lifecycle_status = 'in_progress'` rows, so a staged-open row is never a reap
// candidate; its only exit is the clock inside the ready query itself.
//
// WHY THIS IS A NOTICE AND NOT A WIDER QUEUE. Making the row visible while the
// lease is live is not safe: `Tasks.Claim.claim/2` rides the SAME
// `ready_query/1`, so widening the gate would hand a live-leased row to a
// second worker — two holders, one row. The window is therefore the correct
// answer, and the fix is to put it where a lead reads it, with its bound.
//
// Shape-keyed, not verb-keyed, on purpose: the state is a SHAPE a document
// carries, so `bp task get` on a stranded row says it too, not only the `stage`
// that made it. Every number on the line is read from the server's own
// `claim.lease_expires_at`; a server too old to send one prints NOTHING, the
// same discipline tasks_lease.go keeps — an expiry invented from a TTL the
// client guessed would be the same defect wearing a fix's clothes.

// strandedClaim is a lifecycle-open row still held by a live lease, decoded
// from a 2xx response document. Every field is read from the server.
type strandedClaim struct {
	DocID     string
	Worker    string
	Epoch     int
	ExpiresAt time.Time
	Raw       string
}

// strandedClaimStatuses are the lifecycle states a row can sit in while NOT
// being heartbeatable — the claimable statuses (`Validation.claimable_statuses/0`
// server-side), which is precisely the set `bp task pulse` refuses and the ready
// queue would otherwise offer.
var strandedClaimStatuses = map[string]bool{"open": true, "blocked": true}

// strandedClaimFrom decodes the stranded shape out of a response envelope,
// looking at the raw body and then inside a {"result": …} wrapper — the same
// two-shape walk leaseFromEnvelope does.
//
// It reports false unless ALL of the following hold, because each one alone is
// a false positive this notice must not produce:
//
//   - lifecycle is `open`/`blocked` — an `in_progress` row is the NORMAL held
//     shape; pulse renews it and the queue is right to withhold it.
//   - `claim.worker` is non-blank — a RELEASED row keeps the claim object, its
//     epoch, `released_at`/`released_by` and the `worker` KEY present-and-null,
//     so `claim != null`, `epoch != 0` and key-presence are each false
//     positives. Only the VALUE discriminates.
//   - no close stamp — `close` deliberately leaves `claim.worker` behind beside
//     `closed_by`/`closed_at`, and the queue admits such a row already.
//
// ON THE WORKER CHECK'S REDUNDANCY, STATED RATHER THAN HIDDEN. Against TODAY'S
// server the worker check cannot fire on its own: `lease_expires_at` is stamped
// by `TasksController.Params.with_lease_horizon/1`, whose head matches only
// `%{"worker" => worker} when is_binary(worker)`, so on the wire a present
// expiry ALREADY implies a non-blank worker, and a released row (worker null)
// arrives with no expiry at all. The check is kept as the FORWARD guard — it is
// the rule the server's own ready gate keys on
// (`QueueGate.executable_query/0`: `btrim(claim->>'worker') = ”`), so if the
// envelope ever carries an expiry beside a null worker this file still agrees
// with the queue. `TestStrandedClaimSilentCases/released_row_with_a_stale_horizon`
// is that synthetic shape, and it is labelled synthetic on purpose: a control
// that cannot differ from its subject is a memory of the discovery, not a
// control.
//   - `claim.lease_expires_at` is in the FUTURE — a lapsed lease is already back
//     in the ready queue, so there is no window left to report.
func strandedClaimFrom(body []byte, now time.Time) (strandedClaim, bool) {
	if s, ok := strandedClaimOf(body, now); ok {
		return s, true
	}
	return strandedClaimOf(unwrapResult(body), now)
}

func strandedClaimOf(body []byte, now time.Time) (strandedClaim, bool) {
	var env struct {
		Doc *struct {
			DocID           string `json:"doc_id"`
			LifecycleStatus string `json:"lifecycle_status"`
			Claim           *struct {
				Worker    string `json:"worker"`
				Epoch     int    `json:"epoch"`
				ClosedAt  string `json:"closed_at"`
				ClosedBy  string `json:"closed_by"`
				ExpiresAt string `json:"lease_expires_at"`
			} `json:"claim"`
		} `json:"doc"`
	}
	if json.Unmarshal(body, &env) != nil || env.Doc == nil || env.Doc.Claim == nil {
		return strandedClaim{}, false
	}
	d, c := env.Doc, env.Doc.Claim
	if !strandedClaimStatuses[strings.TrimSpace(d.LifecycleStatus)] {
		return strandedClaim{}, false
	}
	if strings.TrimSpace(c.Worker) == "" {
		return strandedClaim{}, false
	}
	if strings.TrimSpace(c.ClosedAt) != "" || strings.TrimSpace(c.ClosedBy) != "" {
		return strandedClaim{}, false
	}
	expires, err := time.Parse(time.RFC3339, strings.TrimSpace(c.ExpiresAt))
	if err != nil || !expires.After(now) {
		return strandedClaim{}, false
	}
	return strandedClaim{
		DocID:     strings.TrimSpace(d.DocID),
		Worker:    strings.TrimSpace(c.Worker),
		Epoch:     c.Epoch,
		ExpiresAt: expires,
		Raw:       strings.TrimSpace(c.ExpiresAt),
	}, true
}

// strandedClaimLines renders the notice: what the state is, how long it lasts,
// and the one command that ends it. The bound is in SECONDS because that is the
// unit the decision is made in — a lead deciding whether to wait or to release
// needs the number, not an adjective.
func strandedClaimLines(s strandedClaim, now time.Time) []string {
	remaining := int(s.ExpiresAt.Sub(now).Round(time.Second) / time.Second)
	epoch := "<epoch>"
	if s.Epoch > 0 {
		epoch = fmt.Sprintf("%d", s.Epoch)
	}
	return []string{
		fmt.Sprintf("bp: STRANDED CLAIM — %s is lifecycle-open but still carries claim.worker=%s on a LIVE lease, so it is invisible to BOTH lifecycle doors at once: `bp task pulse` refuses it (not_in_progress) and `bp task ready`/`bp task next` withhold it. Nothing heartbeats this row and nobody is offered it.",
			s.DocID, s.Worker),
		fmt.Sprintf("  window: %ds — it re-enters the ready queue at %s and not before. The TtlSweeper does NOT shorten this: it reaps `in_progress` rows only, so the clock is this row's only exit.",
			remaining, s.Raw),
		fmt.Sprintf("  end it now: bp task release %s %s %s — release nulls claim.worker and the row is claimable in the same second; the ready gate keys on that VALUE, not on the claim object's presence.",
			s.DocID, s.Worker, epoch),
	}
}

// emitStrandedClaim prints the notice for a 2xx whose document carries the
// stranded shape. Called from runCommand's post-2xx hook beside emitClaimLease;
// stderr in every output mode, so stdout stays one parseable document, and
// silent on every envelope that is not this shape.
func emitStrandedClaim(out *writer, respBody []byte) {
	if s, ok := strandedClaimFrom(respBody, time.Now().UTC()); ok {
		for _, line := range strandedClaimLines(s, time.Now().UTC()) {
			out.errf("%s", line)
		}
	}
}
