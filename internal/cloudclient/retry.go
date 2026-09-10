// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

package cloudclient

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"time"
)

// BACKPRESSURE IS NOT A FAULT — the control-plane half.
//
// THE DEFECT THIS CLOSES. Every lazily-built client in this package was a bare
// `&http.Client{Timeout: …}`: seven of them (six in client.go, one in
// selfupdate.go). A bare client has a nil Transport, so it rides
// http.DefaultTransport and nothing anywhere in the package looked at a 429.
// The control plane answers `429 {"error":"rate_limited","retry_after":<s>}` on
// login, 2FA challenge, register, instance start, approve, revoke and the
// notifications test route (cloud/lib/barkpark_cloud/web/router.ex:834, :921,
// :995, :1028, :1050, :1095, :1336, :3506, :3602, :3676, :6145, :6284) — the
// server names the exact number of seconds to wait, and `bp` rendered it as a
// hard failure. A one-second throttle was reported to the operator as a broken
// control plane.
//
// WHY THIS IS NOT internal/apiclient.NewRetryTransport. That transport is the
// same policy for the CONTENT API and reusing it was the first choice, but the
// two services do not speak the same error envelope and the difference is
// exactly the field that matters:
//
//   - The content API emits the NESTED envelope
//     `{"error":{"code":"rate_limited","details":{"retry_after":n}}}` and sets
//     the `Retry-After` header alongside it. apiclient reads both.
//   - The control plane emits the FLAT envelope
//     `{"error":"rate_limited","retry_after":n}` and sets NO `Retry-After`
//     header — `grep -rn 'Retry-After' cloud/lib/` is empty. And
//     apierr.Parse DECLINES a bare-string `error` by design (see its
//     TestParseAdmission "bare string error" case).
//
// So apiclient's transport, pointed at this service, would find no code, no
// details and no header: it would fall back to its own one-second default and
// treat every throttled write as unreplayable. It would not honour the number
// the server computed — which is the whole invariant. A shared transport that
// silently ignores the server's wait is worse than two transports that each
// read their own service.
//
// WHAT IT WILL NOT DO, and each refusal is load-bearing:
//
//   - It retries NOTHING but a 429. A 500, a 502, a 403, a 404 is handed back
//     untouched on the first attempt. A refusal is an answer, and a control-
//     plane 500 says nothing about whether the write landed.
//   - It NEVER sleeps out a long retry_after. Above maxRetryAfter the 429 is
//     returned UNSLEPT: a big number is a real "go away", not a blip, and a
//     client that honoured it literally would look like a hung process.
//   - It NEVER exceeds maxTotalBackpressureWait across one RoundTrip, however
//     many small waits the server asks for, and never overruns the caller's
//     context deadline.
//   - It NEVER replays a non-idempotent request on a stranger's word. A POST is
//     repeated only when the body proves OUR limiter refused it
//     (`"error":"rate_limited"`, emitted by a branch that answers before any
//     work is done) AND the request body can be rewound. Login and 2FA are
//     POSTs and they are the most-throttled routes in the service, so this
//     matters; a 429 from an unidentified intermediary earns no such guarantee.
//
// AND IT ANNOUNCES ITSELF on stderr, naming the wait. A command that silently
// takes four seconds longer under load is a mystery, and a mystery gets "fixed"
// by someone deleting the retry.

// retry429Attempts is the total number of tries, first attempt included.
// Backpressure is a queue, and a queue drains.
const retry429Attempts = 4

// defaultBackpressureDelay is the wait used when a 429 names no retry_after in
// its body (the register / start / approve / revoke branches answer
// `{"error":"rate_limited"}` with no number). The limiters are per-minute fixed
// windows, so one second is the floor of what the server can ask for.
const defaultBackpressureDelay = time.Second

// maxRetryAfter is the longest SINGLE wait this transport absorbs on the
// caller's behalf. Above it the 429 is handed back unslept.
const maxRetryAfter = 5 * time.Second

// maxTotalBackpressureWait bounds the SUM of the waits in one RoundTrip, so an
// interactive `bp` command can never become indistinguishable from a hang.
const maxTotalBackpressureWait = 10 * time.Second

// backpressureErrorCode is the slug the control plane's rate-limit branches
// emit. It is what lets a POST be replayed: those branches answer before any
// state is touched, so the request was REFUSED, not attempted.
const backpressureErrorCode = "rate_limited"

// maxRetryProbeBytes bounds how much of a 429 body is buffered to read its
// retry_after. These envelopes are a few dozen bytes.
const maxRetryProbeBytes = 64 << 10

// BackpressureNotice describes one 429 backoff, for a caller that wants to
// surface it instead of the default stderr line.
type BackpressureNotice struct {
	// Attempt is the attempt that was throttled (1-based).
	Attempt int
	// Of is the total attempts allowed.
	Of int
	// Method and URL identify the request being retried.
	Method string
	URL    string
	// Delay is how long the transport waited before the next attempt.
	Delay time.Duration
	// ServerAsked is true when the wait came from the server's own retry_after,
	// false when it is our default.
	ServerAsked bool
}

func (n BackpressureNotice) String() string {
	src := "no retry_after given, using our default"
	if n.ServerAsked {
		src = "the server asked for it"
	}
	return fmt.Sprintf("barkpark: rate limited (429) by %s %s — this is BACKPRESSURE, not a fault; waiting %s (%s) and retrying (attempt %d of %d)",
		n.Method, n.URL, n.Delay, src, n.Attempt, n.Of)
}

// BackpressureExhaustedNotice describes a 429 sequence that stopped with the
// throttle still standing. It names WHICH bound ended it, because "we tried
// four times" and "the server asked for an hour and we refused to wait" are
// different operator problems.
type BackpressureExhaustedNotice struct {
	Attempts int
	Method   string
	URL      string
	// Reason names which bound ended the sequence.
	Reason string
}

func (n BackpressureExhaustedNotice) String() string {
	return fmt.Sprintf("barkpark: still rate limited (429) by %s %s after %d attempt(s) — %s. The control plane is throttling this client, not failing: reduce the request rate rather than treating this as an outage.",
		n.Method, n.URL, n.Attempts, n.Reason)
}

// backpressure is everything the retry loop needs to decide what to do about a
// 429 it recognised.
type backpressure struct {
	// delay is the wait to honour before the next attempt, already clamped.
	delay time.Duration
	// serverAsked records whether delay came from the server or from our default.
	serverAsked bool
	// tooLong is true when the server named a wait above maxRetryAfter. Such a
	// 429 is NOT retried — it is a refusal to serve, not a request to pause.
	tooLong bool
	// ours is true when the body carried the control plane's own rate_limited
	// slug, which is what permits replaying a write.
	ours bool
}

// classifyBackpressure reports whether resp is a 429 and, if so, what to do.
//
// It reads a bounded prefix of the body and puts every byte back, so peeking is
// invisible to whoever reads the body next. A 429 whose body is unreadable is
// still a 429 — the STATUS is the backpressure signal; the body only adds the
// wait and the write-replay permission.
func classifyBackpressure(resp *http.Response) (backpressure, bool) {
	if resp == nil || resp.StatusCode != http.StatusTooManyRequests {
		return backpressure{}, false
	}

	bp := backpressure{delay: defaultBackpressureDelay}

	// The header is read FIRST so that a proxy or a future control-plane
	// revision that does emit the HTTP-standard spelling is honoured — but the
	// body wins below, because on this service the body is the only place the
	// number has ever appeared and it is the value the server COMPUTED.
	seconds, ok := parseRetryAfterSeconds(resp.Header.Get("Retry-After"))

	if resp.Body != nil {
		prefix, err := io.ReadAll(io.LimitReader(resp.Body, maxRetryProbeBytes))
		resp.Body = restoredBody(prefix, resp.Body)
		if err == nil {
			code, after, hasAfter := parseCloudRateLimit(prefix)
			bp.ours = code == backpressureErrorCode
			if hasAfter {
				seconds, ok = after, true
			}
		}
	}

	if ok {
		bp.serverAsked = true
		bp.delay = time.Duration(seconds * float64(time.Second))
		if bp.delay > maxRetryAfter {
			bp.tooLong = true
		}
		// "retry after 0" means "immediately". Honour it as a real zero rather
		// than substituting our default; the attempt cap bounds the busy loop.
		if bp.delay < 0 {
			bp.delay = 0
		}
	}

	return bp, true
}

// parseCloudRateLimit reads the control plane's FLAT refusal envelope,
// `{"error":"rate_limited","retry_after":<seconds>}`. The nested
// `{"error":{"code":…,"details":{"retry_after":…}}}` spelling is tolerated too,
// so a route that ever migrates to the content API's envelope keeps working
// rather than silently losing its number.
func parseCloudRateLimit(body []byte) (code string, retryAfter float64, ok bool) {
	if len(body) == 0 {
		return "", 0, false
	}
	var flat struct {
		Error      json.RawMessage `json:"error"`
		RetryAfter json.RawMessage `json:"retry_after"`
	}
	if json.Unmarshal(body, &flat) != nil {
		return "", 0, false
	}

	after := flat.RetryAfter
	if len(flat.Error) > 0 {
		if json.Unmarshal(flat.Error, &code) != nil {
			// Not a bare string — try the nested envelope.
			var nested struct {
				Code    string `json:"code"`
				Details struct {
					RetryAfter json.RawMessage `json:"retry_after"`
				} `json:"details"`
			}
			if json.Unmarshal(flat.Error, &nested) == nil {
				code = nested.Code
				if len(after) == 0 {
					after = nested.Details.RetryAfter
				}
			}
		}
	}

	if n, got := numberOrNumericString(after); got {
		return code, n, true
	}
	return code, 0, false
}

// numberOrNumericString accepts `3` and `"3"` alike: a value the server plainly
// meant is not dropped over its JSON type.
func numberOrNumericString(raw json.RawMessage) (float64, bool) {
	if len(raw) == 0 {
		return 0, false
	}
	var n float64
	if json.Unmarshal(raw, &n) == nil {
		return n, true
	}
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return parseRetryAfterSeconds(s)
	}
	return 0, false
}

// parseRetryAfterSeconds reads the delta-seconds form. The HTTP-date form is
// NOT parsed: this service never emits it, and guessing at a date form would be
// honouring a clock skew rather than a wait.
func parseRetryAfterSeconds(v string) (float64, bool) {
	if v == "" {
		return 0, false
	}
	n, err := strconv.ParseFloat(v, 64)
	if err != nil {
		return 0, false
	}
	return n, true
}

// restoredBody hands back a body that reads the peeked prefix and then whatever
// remains of the original stream, so a peek is invisible downstream.
func restoredBody(prefix []byte, rest io.ReadCloser) io.ReadCloser {
	return struct {
		io.Reader
		io.Closer
	}{io.MultiReader(bytes.NewReader(prefix), rest), rest}
}

// idempotentMethod reports whether a method may be repeated on its own.
func idempotentMethod(req *http.Request) bool {
	return req.Method == http.MethodGet || req.Method == http.MethodHead
}

// mayReplayUnderBackpressure reports whether req may be sent again after a 429.
//
// GET and HEAD always may. Everything else needs BOTH halves of the guarantee:
// the body must prove OUR rate-limit branch refused it (so nothing was done),
// and the body must be rewindable (so the replay is the same request rather
// than a truncated one).
func mayReplayUnderBackpressure(req *http.Request, bp backpressure) (bool, string) {
	if idempotentMethod(req) {
		return true, ""
	}
	if !bp.ours {
		return false, fmt.Sprintf("the 429 carries no %q envelope, so it did not demonstrably come from the control plane's own rate limiter — a %s is not replayed on a stranger's word", backpressureErrorCode, req.Method)
	}
	if req.Body != nil && req.Body != http.NoBody && req.GetBody == nil {
		return false, fmt.Sprintf("this %s carries a body that cannot be rewound (no GetBody), and half a request is worse than none", req.Method)
	}
	return true, ""
}

// rewindBody restores req's body for another attempt.
func rewindBody(req *http.Request) error {
	if req.Body == nil || req.Body == http.NoBody || req.GetBody == nil {
		return nil
	}
	body, err := req.GetBody()
	if err != nil {
		return err
	}
	req.Body = body
	return nil
}

// retryTransport wraps a RoundTripper with the 429-only policy above. A nil
// base means http.DefaultTransport.
type retryTransport struct {
	base     http.RoundTripper
	attempts int
	// maxWait is the total-wait ceiling for one RoundTrip.
	maxWait time.Duration
	// sleep is injectable so tests do not spend real seconds. It must honour
	// ctx cancellation.
	sleep func(ctx context.Context, d time.Duration) error
	// onBackpressure, when non-nil, fires once per honoured 429 wait.
	onBackpressure func(BackpressureNotice)
	// onExhausted fires AT MOST ONCE, and only when at least one wait was spent
	// and the throttle still stood.
	onExhausted func(BackpressureExhaustedNotice)
}

// newRetryTransport builds the package's shared 429 policy over base.
//
// @canonical capability: cloudclient-backpressure-retry
func newRetryTransport(base http.RoundTripper) http.RoundTripper {
	return &retryTransport{
		base:           base,
		onBackpressure: stderrBackpressureNotifier,
		onExhausted:    stderrBackpressureExhaustedNotifier,
	}
}

func stderrBackpressureNotifier(n BackpressureNotice) {
	fmt.Fprintln(os.Stderr, n.String())
}

func stderrBackpressureExhaustedNotifier(n BackpressureExhaustedNotice) {
	fmt.Fprintln(os.Stderr, n.String())
}

func (t *retryTransport) roundTripper() http.RoundTripper {
	if t.base != nil {
		return t.base
	}
	return http.DefaultTransport
}

func (t *retryTransport) attemptCap() int {
	if t.attempts > 0 {
		return t.attempts
	}
	return retry429Attempts
}

func (t *retryTransport) waitCeiling() time.Duration {
	if t.maxWait > 0 {
		return t.maxWait
	}
	return maxTotalBackpressureWait
}

// sleepFor waits d, honouring the request context.
func (t *retryTransport) sleepFor(ctx context.Context, d time.Duration) error {
	if t.sleep != nil {
		return t.sleep(ctx, d)
	}
	if d <= 0 {
		return ctx.Err()
	}
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

// RoundTrip repeats a 429 — and ONLY a 429 — up to the attempt cap, honouring
// the server's own retry_after and bounded by the total-wait ceiling.
func (t *retryTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	ctx := req.Context()
	cap := t.attemptCap()
	ceiling := t.waitCeiling()

	var spent time.Duration
	var waits int

	for attempt := 1; ; attempt++ {
		resp, err := t.roundTripper().RoundTrip(req)
		// A transport error is never retried here: it is not a 429, and the
		// caller's own error handling owns it.
		if err != nil {
			return resp, err
		}

		bp, is429 := classifyBackpressure(resp)
		if !is429 {
			// EVERY other status — 200, 403, 500, 502 — is handed back on the
			// first attempt, untouched.
			return resp, nil
		}

		reason := ""
		switch {
		case attempt >= cap:
			reason = fmt.Sprintf("the attempt cap of %d is spent", cap)
		case bp.tooLong:
			reason = fmt.Sprintf("the server asked for %s, above the %s we will absorb — that is a refusal to serve, not a request to pause", bp.delay, maxRetryAfter)
		case spent+bp.delay > ceiling:
			reason = fmt.Sprintf("another %s would pass the %s total-wait ceiling", bp.delay, ceiling)
		}
		if reason == "" {
			if replay, why := mayReplayUnderBackpressure(req, bp); !replay {
				reason = why
			}
		}
		if reason != "" {
			if waits > 0 && t.onExhausted != nil {
				t.onExhausted(BackpressureExhaustedNotice{
					Attempts: attempt,
					Method:   req.Method,
					URL:      req.URL.String(),
					Reason:   reason,
				})
			}
			return resp, nil
		}

		// Committed to another attempt: drain and close the refusal so the
		// connection is reusable, then rewind the body.
		drainAndClose(resp)
		if err := rewindBody(req); err != nil {
			return nil, err
		}

		if t.onBackpressure != nil {
			t.onBackpressure(BackpressureNotice{
				Attempt:     attempt,
				Of:          cap,
				Method:      req.Method,
				URL:         req.URL.String(),
				Delay:       bp.delay,
				ServerAsked: bp.serverAsked,
			})
		}
		if err := t.sleepFor(ctx, bp.delay); err != nil {
			return nil, err
		}
		spent += bp.delay
		waits++
	}
}

func drainAndClose(resp *http.Response) {
	if resp == nil || resp.Body == nil {
		return
	}
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, maxRetryProbeBytes))
	_ = resp.Body.Close()
}

// newHTTPClient builds the ONE shape of lazily-constructed client this package
// uses: the caller's timeout, with the 429 policy installed.
//
// It exists for the same reason apiclient.streamClient does — seven call sites
// each wrote `&http.Client{Timeout: …}` by hand, and a bare client has a nil
// Transport, so every one of them opted out of a policy nobody decided to skip.
// An eighth timeout-widening path added later gets the policy by calling this.
func newHTTPClient(timeout time.Duration) *http.Client {
	return &http.Client{Timeout: timeout, Transport: newRetryTransport(nil)}
}
