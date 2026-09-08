// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

package apiclient

import "net/http"

// streamClient is the ONE owner of the long-lived-read HTTP client.
//
// THE DEFECT IT CLOSES. Five read paths — the data listen SSE, the chat SSE,
// the fleet events SSE, Listen, and the full-dataset export — each built their
// own `&http.Client{Timeout: 0}` inline. Every one of them wanted the same
// thing and said so in the same words: "No client timeout — the stream is
// long-lived; ctx cancellation ends it." None of them wanted to opt out of
// retries, and none of them said they did.
//
// But a freshly-constructed http.Client has a nil Transport, so it uses
// http.DefaultTransport — and `retryTransport` was never in its chain. THE
// TRANSPORT WAS DROPPED AS A SIDE EFFECT OF SETTING A TIMEOUT. Nobody decided
// to skip backpressure or the transient-500 retry; they needed `Timeout: 0`,
// and building a bare client is how you get it.
//
// That is why grepping for the policy's absence never found these: there is
// nothing to find, only something missing. A policy installed at a chokepoint
// is only as good as the invariant that everything goes through the chokepoint,
// and `&http.Client{…}` is a way to not.
//
// So this exists for the same reason Client's own transport is installed in
// New() rather than at its ~20 call sites: ONE owner, so no read path can be
// forgotten. A sixth stream added later gets the policy by calling this.
//
// WHY THE RETRY IS SAFE ON A STREAM, which is the question that decided it:
//
//   - A 429 means the stream NEVER CONNECTED. Every 429 this API emits comes
//     from a Plug that halts before the controller (see retry_backpressure.go),
//     so there is no stream to be mid-way through — the stream does not exist
//     until a 200. Retrying it is exactly retrying a request.
//   - A 2xx is handed back UNTOUCHED. retryTransport.RoundTrip inspects status
//     only; it never reads the body, and it returns immediately on a transport
//     error without retrying. An established stream behaves exactly as before.
//   - `Timeout` and `Transport` are different http.Client fields, so the
//     long-lived semantics these paths need are unaffected.
//
// A stream that genuinely wants to own its own 429 says so with
// WithCallerOwnedBackpressure(ctx) — the sanctioned opt-OUT — rather than by
// dropping the transport, which also silently forfeits the transient-500 retry.
func streamClient() *http.Client {
	return &http.Client{Timeout: 0, Transport: NewRetryTransport(nil)}
}
