package taskboard

// criterion_readback.go — the typed SECOND READ behind the PDS success-claim
// law (charter PDS-D359/D361): a ledger writer may not report a write it never
// read back. `bp task stamp` POSTs its criterion flip and then calls
// FetchCriterion to ask the STORE what that row now holds, so a write dropped
// by a transport ceiling, a holder gate, or a bad minute on the box cannot be
// reported as a success by an exit code alone.
//
// The decode lives HERE, not in internal/apiclient, because taskboard already
// owns the acceptance_criteria shape and its exact server-matching tolerance
// contract (decodeAcceptanceCriteria / decodeCriterion in fetch.go). apiclient
// stays the transport: it hands back doc.content verbatim.

import (
	"fmt"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// FetchCriterion re-reads task docID and decodes acceptance_criteria[idx] into
// the same CriterionItem the board renders. idx is ZERO-BASED — the index the
// stamp verb takes and the index the server writes at.
//
// Every failure mode is an HONEST read failure, never a verdict: a transport
// error, an ok:false envelope, a task with no criteria and an out-of-range
// index all return an error naming what went wrong. A caller must not read any
// of them as "the write landed" — it means the store could not be asked.
//
// It also returns the IDENTITY of the row that answered. A read-back that
// cannot say WHICH row it read cannot tell a caller whether the value it found
// is on the board: GET /v1/tasks/:doc_id falls back to the `drafts.` twin when
// no published row exists, so a criterion can be found, and be real, and still
// live somewhere no board will ever render it. The verdict belongs to the
// caller — this reports what answered and never judges it.
func FetchCriterion(c *apiclient.Client, docID string, idx int) (CriterionItem, apiclient.TaskReadback, error) {
	if idx < 0 {
		return CriterionItem{}, apiclient.TaskReadback{}, fmt.Errorf("criterion index %d is negative — indices are zero-based", idx)
	}
	rb, err := c.TaskGetContent(docID)
	if err != nil {
		return CriterionItem{}, apiclient.TaskReadback{}, err
	}
	items := decodeAcceptanceCriteria(rb.Content)
	if idx >= len(items) {
		return CriterionItem{}, rb, fmt.Errorf(
			"the store holds %d acceptance criteria on %s — index %d (0-based) does not exist",
			len(items), docID, idx)
	}
	return items[idx], rb, nil
}
