package cli

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
	"github.com/FRIKKern/barkpark/internal/taskboard"
)

// tasks_lease.go — THE LEASE LINE.
//
// A claim is a LEASE, and until this file existed the CLI printed everything
// about a claim EXCEPT how long it lasts. `bp task claim <id> <worker>` echoed
// the fencing epoch (docReceiptLine) and the server's next-command templates
// (emitHelpHints), and said nothing at all about expiry — so a lead who claimed
// four rows at 21:50Z and dispatched builders had no way to know, without
// reading the TtlSweeper source, that the leases would lapse at 22:35Z. One did,
// 29s before its PR opened: the pr-task-gate refused the PR and `bp task next`
// handed a sibling row to a second lead mid-build. The number the operator
// needed was knowable at claim time on the server and withheld by the receipt.
//
// So the server now sends the lease it just granted as an ADDITIVE top-level
// `lease` object on the claim/next/pulse 2xx envelope
// (BarkparkWeb.TasksController.Params.claim_lease/1), and this file renders it
// as ONE stderr line carrying, together: the epoch, the absolute UTC expiry,
// and the lease length in minutes.
//
// stderr, in every output mode, exactly like emitHelpHints — stdout stays the
// single parseable document under -o json/yaml, and the `lease` object is right
// there in that document for a machine consumer. A server too old to send
// `lease` prints NOTHING: a receipt that invents an expiry from a TTL the
// client guessed would be the same defect wearing a fix's clothes.

// claimLease is the lease a claim/pulse 2xx envelope reported, paired with the
// fencing epoch off the same response doc. Every field is read from the server;
// none is derived here.
type claimLease struct {
	ExpiresAt string
	Minutes   int
	Seconds   int
	Epoch     int
}

// leaseFromEnvelope decodes the top-level `lease` object and the response doc's
// `claim.epoch`, looking first at the raw body (the tasks endpoints emit flat
// envelopes) and then inside a {"result": …} wrapper — the same two-shape walk
// helpEntries does. It reports false unless the envelope carried a lease with a
// usable expiry, so no other verb's 2xx ever grows a line.
func leaseFromEnvelope(body []byte) (claimLease, bool) {
	if l, ok := leaseOf(body); ok {
		return l, true
	}
	return leaseOf(unwrapResult(body))
}

func leaseOf(body []byte) (claimLease, bool) {
	var env struct {
		Lease *struct {
			ExpiresAt string `json:"expires_at"`
			Seconds   int    `json:"seconds"`
			Minutes   int    `json:"minutes"`
		} `json:"lease"`
		Doc struct {
			Claim struct {
				Epoch int `json:"epoch"`
			} `json:"claim"`
		} `json:"doc"`
	}
	if json.Unmarshal(body, &env) != nil || env.Lease == nil || env.Lease.ExpiresAt == "" {
		return claimLease{}, false
	}
	return claimLease{
		ExpiresAt: env.Lease.ExpiresAt,
		Minutes:   env.Lease.Minutes,
		Seconds:   env.Lease.Seconds,
		Epoch:     env.Doc.Claim.Epoch,
	}, true
}

// leaseLine renders the receipt. The epoch, the absolute UTC expiry and the
// length in minutes ride ONE line on purpose: a lead reading a claim receipt
// reads one line, and the two facts that decide whether a dispatch is safe
// (when it lapses, how long you get) must not be separable from the fence they
// belong to. The trailing clause is the OTHER half of the same misinformation:
// the epoch on this line stops being current the moment anything pulses.
func leaseLine(l claimLease) string {
	line := "lease:"
	if l.Epoch > 0 {
		line += fmt.Sprintf(" epoch=%d", l.Epoch)
	}
	line += fmt.Sprintf(" expires_at=%s lease=%dmin", l.ExpiresAt, l.Minutes)
	return line + " — `bp task pulse` renews the lease AND advances the epoch, so re-read the epoch after every pulse"
}

// emitClaimLease prints the lease line for a 2xx that carried one. Called from
// runCommand's post-2xx hook beside emitHelpHints; silent on every envelope
// without a `lease` object.
func emitClaimLease(out *writer, respBody []byte) {
	if l, ok := leaseFromEnvelope(respBody); ok {
		out.errf("%s", leaseLine(l))
	}
}

// ── the stale epoch a pulse produced ────────────────────────────────────────
//
// The other half of the same misinformation. `bp task stamp --help` and
// `bp task close --help` used to call the third positional "the claim epoch
// returned at claim time", and a builder who followed that literally — stored
// the number from its claim, pulsed twice, then closed — got a bare 409
// naming a CAS conflict. The refusal was correct and told the operator nothing
// about the CAUSE: the epoch had not gone wrong, it had MOVED, by their own
// heartbeat. So on a fenced_off refusal the CLI now reads the row back and, when
// the caller still holds the claim, names the current epoch outright.
//
// This never contradicts the server. The 409 stands, the exit code is
// untouched; only an explanatory stderr line is added, and only when the
// read-back can support it (a read that fails, a claim that is GONE, or a claim
// held by somebody else each get their own honest line instead).

// staleEpochReasons are the server refusal codes that mean "the observed_epoch
// you passed is not the current claim epoch". Keyed on the code, not on prose.
var staleEpochReasons = map[string]bool{"fenced_off": true}

// explainStaleEpoch reads the row back after a fenced_off refusal and names the
// epoch the store currently holds. `worker` is the id the refused write was
// attributed to; when the store shows a DIFFERENT holder the refusal is about
// ownership, not staleness, and this says so rather than handing the caller a
// number that would refuse them again.
func explainStaleEpoch(out *writer, ctx manifest.Context, docID, worker string) {
	// The SAME read-back client close, pulse and stamp share
	// (taskReadbackClient, tasks_close_pulse_cmd.go) and the SAME claim decode
	// the pulse read-back uses — one definition, so the epoch this line names
	// can never drift from the epoch the pulse receipt printed.
	stored, _, err := taskboard.FetchPulse(taskReadbackClient(ctx), docID)
	if err != nil {
		out.errf("  (could not read %s back to name the current epoch: %v)", docID, err)
		return
	}
	if stored.ClaimEpoch <= 0 {
		out.errf("  the store holds no claim epoch on %s — the lease is GONE, not merely advanced; re-claim before writing again", docID)
		return
	}
	if w := strings.TrimSpace(worker); w != "" && stored.ClaimWorker != "" && stored.ClaimWorker != w {
		out.errf("  the claim on %s is held by %s, not %s — this refusal is about the HOLDER, not a stale epoch", docID, stored.ClaimWorker, w)
		return
	}
	out.errf("  epoch advanced by pulse to %d — you still hold this claim; every `bp task pulse` advances the epoch, so the number you were given at claim time is stale. Retry with %d.",
		stored.ClaimEpoch, stored.ClaimEpoch)
}
