// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

package apiclient

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/FRIKKern/barkpark/internal/apierr"
)

// BACKPRESSURE IS NOT A FAULT.
//
// MEASURED 2026-09-01 17:02Z: `bp task ready` came back HTTP 429 with
// `retry_after=1` under this fleet's own load — 18 agent lanes, each running a
// pulse loop and its own queries against one ledger. Nothing in this client
// acted on that number. The 429 fell through retry.go's 500-shaped gate
// untouched, every call site rendered it as a hard failure, and a ONE SECOND
// wait was reported to the operator as a broken machine.
//
// That is the whole defect: the server said "ask me again in a second" and the
// client heard "the ledger is down". A throttle that renders as an outage
// teaches a fleet to treat its own healthy backpressure as an incident.
//
// ── WHY A 429 IS SAFE TO REPLAY WHERE A 500 IS NOT ──────────────────────────
//
// retry.go refuses to repeat any non-GET/HEAD, and that refusal is correct FOR
// A 500: a 500 tells you NOTHING about whether the write landed — in the
// 2026-08-23 incident a `bp doc publish` returned 500 and the publish HAD
// landed, so a blind repeat would have filed a duplicate.
//
// A 429 carries the OPPOSITE guarantee, and it is a structural one rather than
// a hopeful reading. Every 429 this API emits comes from a Plug that HALTS the
// pipeline — api/lib/barkpark_web/plugs/rate_limit.ex, auth_write_rate_limit.ex
// and ticket_rate_limit.ex all `put_status(429) |> halt()` — so the controller
// never ran and no write was performed. The request was REFUSED, not attempted.
// Replaying a refused write cannot duplicate anything, because there is nothing
// to duplicate.
//
// So the idempotence gate is re-drawn, NOT removed, and the new line is drawn
// on evidence rather than on the method alone:
//
//   - GET/HEAD: retried on a 429 unconditionally. Safe by definition, exactly
//     as they already are for the transient 500.
//   - Any other method: retried ONLY when the envelope proves the refusal came
//     from OUR rate limiter (`error.code == "rate_limited"`) AND the request
//     body can actually be replayed (`req.GetBody != nil`). A bare 429 from an
//     unidentified intermediary — a CDN, a reverse proxy, something between us
//     and Phoenix — earns no such guarantee and is handed straight back. We
//     know what OUR plug did before it answered; we do not know what a stranger
//     did before it answered.
//
// This is not academic: `bp task pulse` is a POST, the pulse loops are most of
// the load that produced the 429, and a pulse lost to a throttle lets a claim
// lease lapse — the fleet's most expensive silent failure.
//
// ── WHAT IT WILL NOT DO ─────────────────────────────────────────────────────
//
//   - It NEVER sleeps out a long `retry_after`. The pulse plugin answers 429
//     with `Retry-After: 3600` when a channel spends its daily cap; a client
//     that honored that literally would hang for an hour and look like a hung
//     process. Anything over maxRetryAfter is handed back UNSLEPT — a big
//     number is a real "go away", not a blip, and the caller must see it.
//   - It NEVER exceeds maxTotalBackpressureWait across one RoundTrip, however
//     many small waits the server asks for.
//   - It NEVER replays a write whose body it cannot rewind. A half-consumed
//     body would send a truncated request that the server might well accept.
//
// AND IT ANNOUNCES ITSELF, on stderr, naming the wait. The task that filed this
// asked for exactly that, and the reason is that the alternative is worse than
// the bug: a command that silently takes four seconds longer under load is a
// mystery, and a mystery gets "fixed" by someone removing the retry.

// retry429Attempts is the total number of tries, first attempt included. One
// more than the 500 path's three: backpressure is a queue, and a queue drains.
const retry429Attempts = 4

// defaultBackpressureDelay is the wait used when a 429 names no `retry_after`
// and carries no `Retry-After` header. The measured value on 2026-09-01 was 1s
// and the rate-limit plugs compute ceil(60/per_minute), so one second is both
// the observed figure and the floor of what the server can ask for.
const defaultBackpressureDelay = time.Second

// maxRetryAfter is the longest single wait this transport will absorb on the
// caller's behalf. Above it the 429 is returned unslept: see the pulse plugin's
// `Retry-After: 3600` daily-cap answer, which is a refusal to serve today, not
// a request to pause.
const maxRetryAfter = 5 * time.Second

// maxTotalBackpressureWait bounds the SUM of the waits in one RoundTrip. Three
// waits of one second is the measured shape; ten seconds leaves room for a
// server asking for more without ever letting an interactive `bp` command
// become indistinguishable from a hang.
const maxTotalBackpressureWait = 10 * time.Second

// backpressureErrorCode is the envelope code our rate-limit plugs emit
// (Barkpark.Content.Errors: `{:error, :rate_limited}` → code "rate_limited").
// It is what lets a write be replayed: it proves the refusal came from a plug
// that halted before the controller.
const backpressureErrorCode = "rate_limited"

// BackpressureNotice describes one 429 backoff, for a caller that wants to
// surface it. It is deliberately a DIFFERENT type from RetryNotice: a throttle
// and a server fault are different events, and a reader who cannot tell them
// apart will read healthy backpressure as a sick server — which is the exact
// confusion this file exists to remove.
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
	// ServerAsked is true when the wait came from the server's own
	// `retry_after` / `Retry-After`, false when it is our default.
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

// BackpressureExhaustedNotice describes a 429 sequence that ran out of attempts
// or out of wait budget with the throttle still standing. It says WHY the
// transport stopped, because "we gave up after four tries" and "the server
// asked for an hour and we refused to wait" are different operator problems.
type BackpressureExhaustedNotice struct {
	Attempts  int
	Method    string
	URL       string
	RequestID string
	// Reason names which bound ended the sequence.
	Reason string
}

func (n BackpressureExhaustedNotice) String() string {
	id := n.RequestID
	if id == "" {
		id = "(none reported)"
	}
	return fmt.Sprintf("barkpark: still rate limited (429) by %s %s after %d attempt(s) — %s (last request_id: %s). The server is throttling this client, not failing: reduce the request rate rather than treating this as an outage.",
		n.Method, n.URL, n.Attempts, n.Reason, id)
}

// backpressure describes a 429 the transport recognised.
type backpressure struct {
	// delay is the wait to honor before the next attempt, already clamped.
	delay time.Duration
	// serverAsked records whether delay came from the server or from our default.
	serverAsked bool
	// tooLong is true when the server named a wait above maxRetryAfter. Such a
	// 429 is NOT retried — it is a refusal to serve, not a request to pause.
	tooLong bool
	// ours is true when the envelope carried our own `rate_limited` code, which
	// is what proves a halting plug refused the request before any handler ran.
	ours bool
	// requestID is the envelope's request id, for the give-up announcement.
	requestID string
}

// classifyBackpressure reports whether resp is a 429 and, if so, everything the
// retry loop needs to decide what to do about it.
//
// Like isRetryableServerFault it reads a bounded prefix of the body and puts
// every byte back, so peeking is invisible to whoever reads the body next. A
// 429 whose body is unreadable or unparseable is still a 429 — the STATUS is
// the backpressure signal, and the envelope only adds the wait and the
// write-replay permission. That asymmetry with the 500 path is deliberate: a
// 500's retryability lives entirely in its code, a 429's lives in its status.
func classifyBackpressure(resp *http.Response) (backpressure, bool) {
	if resp == nil || resp.StatusCode != http.StatusTooManyRequests {
		return backpressure{}, false
	}

	bp := backpressure{delay: defaultBackpressureDelay}

	// The header first: it is the HTTP-standard spelling, every one of our
	// rate-limit plugs sets it alongside the envelope, and it is readable even
	// when the body is not.
	seconds, headerOK := parseRetryAfterSeconds(resp.Header.Get("Retry-After"))

	if resp.Body != nil {
		prefix, err := io.ReadAll(io.LimitReader(resp.Body, maxRetryProbeBytes))
		resp.Body = restoredBody(prefix, resp.Body)
		if err == nil {
			if env, ok := apierr.Parse(prefix); ok {
				bp.ours = env.Code == backpressureErrorCode
				bp.requestID = env.RequestID
				// The body's `details.retry_after` wins over the header when
				// both are present: it is the value the server COMPUTED, and
				// the header is its stringification. They agree today; if they
				// ever disagree the computed number is the true one.
				if s, ok := retryAfterFromDetails(env.Details); ok {
					seconds, headerOK = s, true
				}
			}
		}
	}

	if headerOK {
		bp.serverAsked = true
		bp.delay = time.Duration(seconds * float64(time.Second))
		if bp.delay > maxRetryAfter {
			bp.tooLong = true
		}
		// A server that says "retry after 0" means "immediately". Honor it as a
		// real zero rather than substituting our default, but never as a busy
		// loop — the attempt cap is what bounds that.
		if bp.delay < 0 {
			bp.delay = 0
		}
	}

	return bp, true
}

// retryAfterFromDetails digs `details.retry_after` out of the envelope's opaque
// details blob. Errors.to_envelope({:error, :rate_limited, %{retry_after: s}})
// puts it there as a number; a string is accepted too rather than dropping a
// value the server plainly meant.
func retryAfterFromDetails(details json.RawMessage) (float64, bool) {
	if len(details) == 0 {
		return 0, false
	}
	var d struct {
		RetryAfter json.RawMessage `json:"retry_after"`
	}
	if json.Unmarshal(details, &d) != nil || len(d.RetryAfter) == 0 {
		return 0, false
	}
	var n float64
	if json.Unmarshal(d.RetryAfter, &n) == nil {
		return n, true
	}
	var s string
	if json.Unmarshal(d.RetryAfter, &s) == nil {
		return parseRetryAfterSeconds(s)
	}
	return 0, false
}

// parseRetryAfterSeconds reads the delta-seconds form of Retry-After. The
// HTTP-date form is NOT parsed: this API never emits it, and a client that
// guessed at a date form would be honoring a clock skew rather than a wait.
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

// mayReplayUnderBackpressure reports whether req may be sent again after a 429.
//
// GET and HEAD always may. Everything else needs BOTH halves of the guarantee:
// the envelope must prove our own halting rate-limit plug refused it (so no
// handler ran), and the body must be rewindable (so the replay is the same
// request rather than a truncated one).
func mayReplayUnderBackpressure(req *http.Request, bp backpressure) (bool, string) {
	if idempotentMethod(req) {
		return true, ""
	}
	if !bp.ours {
		return false, fmt.Sprintf("the 429 carries no `%s` envelope, so it did not demonstrably come from a rate limiter that halted before the handler — a %s is not replayed on a stranger's word", backpressureErrorCode, req.Method)
	}
	if req.Body != nil && req.Body != http.NoBody && req.GetBody == nil {
		return false, fmt.Sprintf("this %s carries a body that cannot be rewound (no GetBody), and half a request is worse than none", req.Method)
	}
	return true, ""
}

// rewindBody restores req's body for another attempt. A bodyless request needs
// nothing; a rewindable one gets a fresh reader from GetBody.
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

// stderrBackpressureNotifier is the default announcement: one line per backoff
// on stderr, so a slow command is never mysterious. stdout carries `-o json`
// and is untouched. BARKPARK_QUIET_RETRIES=1 silences it, exactly as it
// silences the 500 path's lines — the counter still counts.
func stderrBackpressureNotifier(n BackpressureNotice) {
	if os.Getenv("BARKPARK_QUIET_RETRIES") != "" {
		return
	}
	fmt.Fprintln(os.Stderr, n.String())
}

func stderrBackpressureExhaustedNotifier(n BackpressureExhaustedNotice) {
	if os.Getenv("BARKPARK_QUIET_RETRIES") != "" {
		return
	}
	fmt.Fprintln(os.Stderr, n.String())
}

// RateLimited returns how many times this Client has been throttled (429) and
// backed off since it was constructed.
//
// It is counted SEPARATELY from Retries() on purpose. A non-zero Retries means
// the server is FAILING requests; a non-zero RateLimited means the server is
// HEALTHY and this client is asking too fast. Summing them into one number
// would rebuild, one layer up, exactly the fault/backpressure conflation this
// file removes.
func (c *Client) RateLimited() int64 {
	if c.retry == nil {
		return 0
	}
	return c.retry.throttled.Load()
}

// ── WHEN A CALLER HAS A BETTER ANSWER THAN A RETRY ──────────────────────────
//
// internal/manifest.Fetch already handled a 429 before this file existed, and it
// handles it BETTER than a transport can: it re-asks exactly once after the
// interval the refusal named, and failing that it serves a VALIDATED CACHED
// MANIFEST — an instant, correct answer that no amount of waiting improves on.
// Its comment says why in as many words: "this is a rate limiter, and the
// correct response to 'too many requests' is emphatically not more of them."
//
// Left alone, this transport would have stacked four waits underneath that one,
// so a throttled `bp` would sit for ~12s before reaching a cache that could have
// answered immediately — sluggish exactly when the fleet is loaded, which is the
// same disease as the bug, one layer down.
//
// So a caller that owns the condition says so, and the transport steps aside
// SILENTLY: no wait, no stderr line, no give-up notice. The 429 belongs to the
// layer that can do something better with it. This is an opt-OUT rather than an
// opt-in on purpose — a new read path that forgets to opt in still gets the
// backoff, and forgetting is the failure mode that filed this row.
type callerOwnsBackpressureKey struct{}

// WithCallerOwnedBackpressure marks ctx so the transport hands any 429 on that
// request straight back, unretried and unannounced. Use it ONLY where the
// caller genuinely has a better remedy — a cache, a queue, its own paced
// retry — and not merely to make a command finish sooner.
func WithCallerOwnedBackpressure(ctx context.Context) context.Context {
	if ctx == nil {
		ctx = context.Background()
	}
	return context.WithValue(ctx, callerOwnsBackpressureKey{}, true)
}

func callerOwnsBackpressure(req *http.Request) bool {
	if req == nil || req.Context() == nil {
		return false
	}
	v, _ := req.Context().Value(callerOwnsBackpressureKey{}).(bool)
	return v
}
