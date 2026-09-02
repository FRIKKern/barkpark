// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

package cli

import (
	"net/http"
	"sync"
	"time"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// THE READ HALF OF THE TRANSIENT-500 RETRY: the client every manifest dispatch
// sends on.
//
// `bp` already printed, on 2026-08-23 and again through the night of
// 2026-09-01, lines like
//
//	barkpark: transient internal_error from GET .../v1/capabilities — retrying (attempt 1 of 3)
//
// and then died on the very next request. The retry lived in
// internal/apiclient (retry.go), which the typed client uses — and the
// capabilities fetch is the only thing on the CLI's hot path that goes through
// it. Every manifest-dispatched verb — `task get`, `task ls --all`, all of
// them — rode doRequestCT in run.go, a bare http.Client with no retry at all.
// So the CLI announced that it knew how to survive a transient 500 and then
// hard-failed on the first one, and four agents spent a campaign wrapping every
// bp call in a shell retry loop by hand.
//
// This file supplies the one thing run.go needs: a client carrying the SAME
// retry policy, imported, never re-implemented. The policy's own gate decides
// what it covers — GET and HEAD, nothing else.
//
// THE WRITE HALF IS NOT HERE, and that is the point. A task ledger write
// (claim/next/close/stamp/pulse/release) gets its repeat from
// tasks_write_retry.go, attached to the request as manifestRequest.ledger and
// sent by sendLedgerWrite, which RE-READS the store before every retry so a
// write that already landed is never re-sent. That is strictly stronger than
// deciding from a static per-verb allowlist whether a repeat is survivable, and
// it is why no allowlist lives here: one request, one retry policy, and the
// write policy is the one that can actually see whether the write landed. A
// ledger write does not pass through this client at all (doRequestFull sends it
// single-shot), so the two can never stack.

// dispatchClientTimeout is the wall-clock budget for one manifest dispatch,
// retries and backoff included. Unchanged from the value doRequestCT has always
// used — the retry transport's own budget check (hasBudgetFor) is what keeps a
// retry from eating it, so widening the timeout to "make room" would be
// treating the symptom.
const dispatchClientTimeout = 30 * time.Second

var (
	dispatchClientOnce sync.Once
	dispatchClient     *http.Client
)

// retryingDispatchClient is the http.Client every manifest dispatch uses. One
// instance, built once: the retry transport counts retries on itself, and a
// fresh client per request would also throw away every keep-alive connection —
// which matters most on exactly the sick, slow box the retry exists for.
func retryingDispatchClient() *http.Client {
	dispatchClientOnce.Do(func() {
		dispatchClient = &http.Client{
			Timeout:   dispatchClientTimeout,
			Transport: apiclient.NewRetryTransport(nil),
			// checkRedirect is unchanged and stays the CLI's own: Go's default
			// policy rewrites a redirected POST into a bodyless GET.
			CheckRedirect: checkRedirect,
		}
	})
	return dispatchClient
}
