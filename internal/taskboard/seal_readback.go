package taskboard

// seal_readback.go — the typed SECOND READ behind `bp task close` and
// `bp task pulse`, the two siblings of `bp task stamp` on the same ledger
// (charter PDS-D359/D361: a ledger writer may not report a write it never read
// back).
//
// `stamp` got its read-back in wave 26 and these two were left reporting
// success on an exit code alone: close is the SEAL — it writes lifecycle_status
// and criteria in one atomic update — and pulse writes the now-line the board
// renders. A close that half-lands, or a pulse whose now-line never appears,
// exited 0.
//
// The decodes live HERE, not in internal/apiclient, for the same reason
// FetchCriterion's does: taskboard owns these shapes and their exact
// server-matching tolerance contract (decodeAcceptanceCriteria, decodePulse).
// apiclient stays the transport.

import (
	"encoding/json"
	"fmt"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// SealRow is the post-close state a close receipt may speak about: the seal the
// store took, and the criteria ledger under it.
type SealRow struct {
	// LifecycleStatus is what the STORE holds — "done", "cancelled", "blocked",
	// or still "open" when the close did not land.
	LifecycleStatus string
	// Met and Total count the stored acceptance_criteria. A close that was asked
	// to write criteria in the same atomic update either moved these or did not.
	Met, Total int
	// ClaimWorker is the claim still standing on the row after the close, empty
	// when the close released it. A close that seals the row but leaves a live
	// claim behind has half-landed.
	ClaimWorker string
}

// FetchSeal re-reads task docID and decodes the post-close state, alongside the
// identity of the row that answered (see FetchCriterion for why the identity is
// load-bearing: the route falls back to the `drafts.` twin).
//
// Every failure mode is an HONEST read failure, never a verdict. A caller must
// not read one as "the close landed" — it means the store could not be asked.
func FetchSeal(c *apiclient.Client, docID string) (SealRow, apiclient.TaskReadback, error) {
	rb, err := c.TaskGetContent(docID)
	if err != nil {
		return SealRow{}, apiclient.TaskReadback{}, err
	}
	items := decodeAcceptanceCriteria(rb.Content)
	row := SealRow{LifecycleStatus: rb.LifecycleStatus, Total: len(items)}
	for _, it := range items {
		if it.Met {
			row.Met++
		}
	}
	// lifecycle_status is surfaced at the top level by render_doc, but fall back
	// to content for any envelope that carries it only there — an absent seal
	// must mean "the server did not say", never a silently-invented "open".
	if row.LifecycleStatus == "" {
		var content struct {
			LifecycleStatus string `json:"lifecycle_status"`
		}
		if json.Unmarshal(rb.Content, &content) == nil {
			row.LifecycleStatus = content.LifecycleStatus
		}
	}
	var claim struct {
		Worker string `json:"worker"`
	}
	if len(rb.Claim) > 0 && json.Unmarshal(rb.Claim, &claim) == nil {
		row.ClaimWorker = claim.Worker
	}
	return row, rb, nil
}

// PulseRow is the post-pulse state a pulse receipt may speak about: the now-line
// the store holds and the claim it hangs off.
type PulseRow struct {
	// Now is the decoded content.claim.now, nil when the store holds no pulse.
	// decodePulse's tolerance applies: a malformed or empty-text pulse decodes
	// to nil rather than to a plausible-looking one.
	Now *ClaimPulse
	// ClaimWorker and ClaimEpoch are the lease the pulse renewed.
	ClaimWorker string
	ClaimEpoch  int
}

// FetchPulse re-reads task docID and decodes content.claim.now — what the store
// holds for the now-line — alongside the answering row's identity.
//
// The claim is read from the TOP-LEVEL `doc.claim`, not from content: the server
// deletes "claim" out of content before rendering it, so a decode that looked in
// content would find no pulse on every task and report every pulse as lost.
func FetchPulse(c *apiclient.Client, docID string) (PulseRow, apiclient.TaskReadback, error) {
	rb, err := c.TaskGetContent(docID)
	if err != nil {
		return PulseRow{}, apiclient.TaskReadback{}, err
	}
	if len(rb.Claim) == 0 {
		return PulseRow{}, rb, fmt.Errorf("the store holds no claim on %s — a pulse renews a lease, and there is none to read", docID)
	}
	var claim struct {
		Worker string          `json:"worker"`
		Epoch  int             `json:"epoch"`
		Now    json.RawMessage `json:"now"`
	}
	if err := json.Unmarshal(rb.Claim, &claim); err != nil {
		return PulseRow{}, rb, fmt.Errorf("decode claim on %s: %w", docID, err)
	}
	return PulseRow{
		Now:         decodePulse(claim.Now),
		ClaimWorker: claim.Worker,
		ClaimEpoch:  claim.Epoch,
	}, rb, nil
}
