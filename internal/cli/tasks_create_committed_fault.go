package cli

// A COMMITTED FAULT (task-dbee0d3a56ab4459). Since #26855 the mutate door marks
// its Idempotency-Key committed inside the batch transaction, so a write that
// committed and then answered 5xx is replayed as that 5xx rather than run
// again, and the answer (first and replayed) carries `Idempotency-Committed:
// true`. That header turns "a server fault, which may hide a commit" into "it
// committed": on the publish leg, where bp already knows the id, the task IS
// published and the receipt is printed with exit 0.
//
// The create leg cannot do the same: a 5xx body names no id, so the row exists
// but bp cannot point at it. It stays ambiguous (exit 9) there.

import (
	"encoding/json"
	"net/http"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/manifest"
)

const idempotencyCommittedHeader = "Idempotency-Committed"

// keyedMutationSenderFull is keyedMutationSender plus the response headers.
type keyedMutationSenderFull func(manifest.Context, []map[string]any, string) (int, []byte, http.Header, error)

// sendTaskMutationsFull is sendTaskMutations returning the response headers,
// on the same retrying client doRequest uses.
func sendTaskMutationsFull(ctx manifest.Context, mutations []map[string]any, idempotencyKey string) (int, []byte, http.Header, error) {
	endpoint := apiclient.ScopedURL(ctx.Server, ctx.Workspace, ctx.Project, "/v1/data/mutate/"+ctx.Dataset)
	body, err := json.Marshal(map[string]any{"mutations": mutations})
	if err != nil {
		return 0, nil, nil, err
	}
	headers := map[string]string{"Content-Type": "application/json"}
	if ctx.Token != "" {
		headers["Authorization"] = "Bearer " + ctx.Token
	}
	if idempotencyKey != "" {
		headers[idempotencyHeader] = idempotencyKey
	}
	status, respBody, _, respHeader, err := doRequestUsing(retryingDispatchClient(), "POST", endpoint, headers, body)
	return status, respBody, respHeader, err
}

// sendMutationsIdempotentFull is sendMutationsIdempotent that also returns the
// LAST attempt's response headers.
func sendMutationsIdempotentFull(send keyedMutationSenderFull, ctx manifest.Context, mutations []map[string]any, key string) (status int, body []byte, header http.Header, attempts int, err error) {
	plain := func(c manifest.Context, m []map[string]any, k string) (int, []byte, error) {
		var s int
		var b []byte
		var e error
		s, b, header, e = send(c, m, k)
		return s, b, e
	}
	status, body, attempts, err = sendMutationsIdempotent(plain, ctx, mutations, key)
	return status, body, header, attempts, err
}

// committedFault reports a 5xx the server marked as answering a write that
// committed.
func committedFault(status int, header http.Header) bool {
	return status >= 500 && header.Get(idempotencyCommittedHeader) == "true"
}

// renderCommittedPublishNote says, on stderr, why a 5xx is printed as a
// published receipt, and returns the record that receipt descends from.
func renderCommittedPublishNote(out *writer, bareID string, status int, body []byte) taskCreateRecord {
	out.errf("note: the publish of %s COMMITTED; the server's answer was a fault (%s), marked %s: true. The task is published.",
		bareID, mutateErrorMessage(status, body), idempotencyCommittedHeader)
	return taskCreateRecord{id: bareID, draft: false, hasDraft: true}
}
