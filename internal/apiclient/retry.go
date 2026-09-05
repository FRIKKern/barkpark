// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

package apiclient

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"sync/atomic"
	"time"

	"github.com/FRIKKern/barkpark/internal/apierr"
)

// A DELIBERATELY NARROW retry for ONE server behaviour: a transient
// `internal_error` 500. It exists because guerrilla served 17-50% of ALL public
// reads as 500 on 2026-08-23 (task-d89e42ea727bffb7) while the server itself
// said, in the body of every one of them, "Retry shortly". Nothing in this Go
// client acted on that hint — every call site turned the first 500 into a hard
// failure — so `bp` and every fleet agent failed outright against a box that
// would have answered on the next attempt.
//
// WHAT IT WILL NOT DO, and each refusal is load-bearing:
//
//   - It NEVER retries a write. A 500 tells you NOTHING about whether a write
//     landed — in this very incident a `bp doc publish` returned 500 and the
//     publish HAD landed, so a blind retry would have filed a duplicate. HTTP
//     already gives us the only distinction the transport can trust: GET and
//     HEAD are idempotent by definition, POST is not. Read-shaped POSTs (the
//     query endpoint) are therefore NOT covered — the transport cannot tell a
//     query POST from a mutate POST, and guessing wrong is a duplicated write.
//     That gap is real and it is closed ABOVE this layer, not here: the task
//     ledger writes get their repeat from internal/cli/tasks_write_retry.go,
//     which RE-READS the store before every attempt and so never re-sends a
//     write that already landed. A transport cannot do that, and must not
//     pretend it can.
//   - It NEVER retries a 4xx. A refusal is an answer; repeating it is noise.
//   - It NEVER retries a 5xx that is not exactly `internal_error`. A 502/503
//     from a proxy, or a 500 carrying a different code, is a different fault
//     and is handed straight back.
//   - It NEVER inspects a 200. A body that parses badly is a bug, not a blip,
//     and retrying it would paper over the defect that produced it.
//
// AND IT ANNOUNCES ITSELF. A client that silently absorbs a 30% error rate
// deletes the only signal anyone has that the server is sick — which is exactly
// how this incident went unnoticed until a human tripped over it. Every retry
// emits one line to stderr by default (stdout carries `-o json`, so this cannot
// corrupt a machine-readable result), and the count is readable programmatically
// via Client.Retries.

// retryAttempts is the total number of tries, first attempt included.
const retryAttempts = 3

// retryDelays are the waits BEFORE attempt 2 and attempt 3. Chosen against the
// measured incident rather than by taste: at the 27-50% per-request failure rate
// measured on 2026-08-23, three independent tries leave roughly 2-12% residual.
// They are deliberately short — this rides inside an interactive CLI call, and a
// user waiting on `bp task ready` will tolerate ~1.25s of recovery but not ~10s.
var retryDelays = []time.Duration{250 * time.Millisecond, time.Second}

// retryErrorCode is the ONLY error code this transport will retry. It is the
// generic server-fault code from Barkpark.Content.Errors; the fault FAMILY that
// distinguishes causes rides in the message (e.g. "unknown error
// (DBConnection.ConnectionError)") and is deliberately not matched on — the code
// is the stable contract, the message text is not.
const retryErrorCode = "internal_error"

// maxRetryProbeBytes bounds how much of a 500 body is buffered to read its
// error code. Error envelopes are a few hundred bytes; anything past this is not
// an error envelope and is handed back unread rather than held in memory.
const maxRetryProbeBytes = 64 << 10

// RetryNotice describes one retry, for a caller that wants to surface it.
type RetryNotice struct {
	// Attempt is the attempt that FAILED (1-based), not the one about to run.
	Attempt int
	// Of is the total attempts allowed.
	Of int
	// Method and URL identify the request being retried.
	Method string
	URL    string
	// Delay is how long the transport waited before the next attempt.
	Delay time.Duration
}

func (n RetryNotice) String() string {
	return fmt.Sprintf("barkpark: transient %s from %s %s — retrying (attempt %d of %d) after %s",
		retryErrorCode, n.Method, n.URL, n.Attempt, n.Of, n.Delay)
}

// ExhaustedNotice describes a retry sequence that ran out of attempts (or out
// of deadline budget) with the transient fault still standing.
//
// It exists because "gave up after three tries" and "failed once" render
// IDENTICALLY otherwise — the caller receives the last response and nothing
// else — and because the request id that matters is the LAST attempt's. The
// first attempt's id names a request the server has already forgotten; quoting
// it to support sends them hunting a log line that explains nothing.
type ExhaustedNotice struct {
	// Attempts is how many requests were actually made.
	Attempts int
	// Method and URL identify the request that kept failing.
	Method string
	URL    string
	// RequestID is the id carried by the LAST attempt's error envelope, or ""
	// when the server did not supply one.
	RequestID string
}

func (n ExhaustedNotice) String() string {
	id := n.RequestID
	if id == "" {
		id = "(none reported)"
	}
	return fmt.Sprintf("barkpark: transient %s from %s %s persisted through %d attempts — giving up (last request_id: %s)",
		retryErrorCode, n.Method, n.URL, n.Attempts, id)
}

// retryTransport wraps a RoundTripper with the narrow retry described above.
// The zero delay slice and a nil base are both valid: base nil means
// http.DefaultTransport.
type retryTransport struct {
	base     http.RoundTripper
	delays   []time.Duration
	attempts int
	// sleep is injectable so tests do not spend real seconds.
	sleep func(time.Duration)
	// onRetry, when non-nil, is called once per retry. Never called on success.
	onRetry func(RetryNotice)
	// onExhausted, when non-nil, is called AT MOST ONCE per RoundTrip: only
	// when at least one retry was spent and the sequence still ended on the
	// transient fault. Never called on success, and never for a 500 that was
	// handed straight back without a retry.
	onExhausted func(ExhaustedNotice)
	// count is the cumulative number of retries this transport has performed.
	count atomic.Int64

	// onBackpressure / onBackpressureExhausted are the 429 path's announcements.
	// They are SEPARATE callbacks from onRetry/onExhausted because a throttle is
	// not a fault, and a reader handed one channel for both cannot tell a
	// healthy server saying "slower" from a sick one saying "sorry".
	// See retry_backpressure.go.
	onBackpressure          func(BackpressureNotice)
	onBackpressureExhausted func(BackpressureExhaustedNotice)
	// throttled counts 429 backoffs, separately from count. Same reason.
	throttled atomic.Int64
	// backpressureAttempts overrides retry429Attempts in tests. Zero means the
	// constant.
	backpressureAttempts int
}

func (t *retryTransport) roundTripper() http.RoundTripper {
	if t.base != nil {
		return t.base
	}
	return http.DefaultTransport
}

// RoundTrip implements http.RoundTripper.
//
// The happy path costs nothing: a non-GET, or any response that is not a 500,
// is returned with its body untouched and unbuffered. Only a 500 pays for the
// bounded peek that reads its error code.
func (t *retryTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	// THE IDEMPOTENCE GATE IS PER-FAULT, NOT PER-METHOD.
	//
	// It used to sit here as a blanket `if !idempotentMethod(req) { pass }`,
	// which was right while a transient 500 was the only thing retried: a 500
	// says nothing about whether the write landed, so no write may be repeated.
	//
	// A 429 is a different animal and needs the decision made LATER, against
	// the response: every 429 this API emits comes from a Plug that halted
	// before the controller, so the write provably did not happen and the
	// replay provably cannot duplicate it. Deciding here, on the method alone,
	// would throw that evidence away — and with it every `bp task pulse`, which
	// is a POST and is most of the load that produced the throttle.
	//
	// So a non-idempotent request now enters the loop. It is still refused a
	// repeat on a 500 (isRetryableServerFault's arm below checks the method),
	// and it is granted one on a 429 only when the envelope and a rewindable
	// body both say it is safe (mayReplayUnderBackpressure).
	attempts := t.attempts
	if attempts <= 0 {
		attempts = retryAttempts
	}

	var resp *http.Response
	var err error

	// retried counts the retries this call actually spent. It gates the
	// give-up announcement: a request that never retried (the budget check
	// declined on attempt 1) must not claim it "persisted through" anything.
	retried := 0

	// The two faults keep SEPARATE attempt counters and separate caps. A
	// sequence that is throttled twice and then hits one transient 500 has not
	// spent its 500 budget on the throttles, and vice versa: they are unrelated
	// conditions and a shared counter would let a healthy backpressure burst
	// silently consume the allowance for a genuine fault.
	throttleAttempt := 0
	// waited is the SUM of the backpressure waits spent in this RoundTrip, the
	// bound that stops a server asking for one second forty times from turning
	// an interactive command into a hang.
	var waited time.Duration

	for attempt := 1; ; attempt++ {
		resp, err = t.roundTripper().RoundTrip(req)

		// A transport-level error is NOT retried. It is out of this helper's
		// stated scope (HTTP 500 + internal_error), and conflating a dropped
		// connection with a served fault would hide a different failure mode —
		// the same host dropped SYNs on 2026-08-21, which is a distinct defect
		// that deserves to surface, not be smoothed over.
		if err != nil {
			return nil, err
		}

		// BACKPRESSURE FIRST — it is the cheaper check (a status compare) and
		// it is the one whose answer differs by method.
		if bp, is429 := classifyBackpressure(resp); is429 && !callerOwnsBackpressure(req) {
			done, next := t.handleBackpressure(req, resp, bp, &throttleAttempt, &waited)
			if done {
				return resp, next
			}
			if next != nil {
				return nil, next
			}
			continue
		}

		retryable, requestID := isRetryableServerFault(resp)
		// A 500 is retried for GET/HEAD only, and that refusal is load-bearing:
		// a 500 gives no evidence about whether a write landed. Unlike the 429
		// arm above, there is nothing here to weigh — the answer is the method.
		if retryable && !idempotentMethod(req) {
			retryable = false
		}
		if !retryable {
			return resp, nil
		}
		if attempt >= attempts {
			// Out of attempts and still failing. Say so, naming the request id
			// of THIS attempt — the last one, the only one whose envelope the
			// caller is about to be handed. Without this line a three-attempt
			// give-up is indistinguishable from a single hard 500, and the
			// operator quoting a request id to support quotes the wrong one.
			t.announceExhausted(req, attempt, requestID, retried)
			return resp, nil
		}

		delay := t.delayFor(attempt)

		// BUDGET CHECK — the retry must never turn a would-be success into a
		// timeout. http.Client.Timeout (5s by default here) is a deadline over
		// the WHOLE Do call, retries included, and it surfaces on the request
		// context. On a box that is both sick AND slow — guerrilla served
		// healthy responses with TTFB from 0.35s to 4.50s on 2026-08-23 — three
		// attempts plus 1.25s of sleeping blow that budget, and the caller gets
		// a context deadline instead of the answer a second attempt would have
		// produced. Measured, not theorised: an interleaved A/B of 40 command
		// pairs against the live box had the retrying binary at 19/40 against
		// the non-retrying one at 24/40 until this check existed.
		//
		// So: only retry when there is room for the wait AND a realistic
		// attempt. Otherwise hand back the honest 500 immediately — no sleep,
		// no extra request, nothing spent that the caller did not authorise.
		if !t.hasBudgetFor(req, delay) {
			t.announceExhausted(req, attempt, requestID, retried)
			return resp, nil
		}

		// Retryable, attempts remain, budget allows: discard this body and wait.
		// Draining is what lets the underlying connection be reused, not leaked.
		_, _ = io.Copy(io.Discard, resp.Body)
		_ = resp.Body.Close()

		retried++
		t.count.Add(1)
		if t.onRetry != nil {
			t.onRetry(RetryNotice{
				Attempt: attempt,
				Of:      attempts,
				Method:  req.Method,
				URL:     req.URL.String(),
				Delay:   delay,
			})
		}
		if err := t.sleepFor(req.Context(), delay); err != nil {
			// The caller cancelled (or its context otherwise ended) while we
			// were waiting out the backoff. Surface that promptly rather
			// than sleeping out a delay nobody is waiting on anymore —
			// resp.Body is already drained and closed above.
			return nil, fmt.Errorf("barkpark: retry backoff interrupted: %w", err)
		}
	}
}

// handleBackpressure decides what a 429 means for this request and, when it
// means "wait and try again", performs the wait.
//
// It returns (done, err):
//
//	done=true            — stop; hand resp back to the caller (err is nil).
//	done=false, err=nil  — the wait was taken; the loop should try again.
//	done=false, err!=nil — abandon the RoundTrip with err (a cancelled context
//	                       or an unrewindable body).
//
// EVERY early return announces itself before giving up. A 429 handed back in
// silence is precisely the defect this closes: the operator sees a non-2xx, has
// no idea a throttle caused it, and files an outage.
func (t *retryTransport) handleBackpressure(
	req *http.Request,
	resp *http.Response,
	bp backpressure,
	throttleAttempt *int,
	waited *time.Duration,
) (bool, error) {
	attempts := t.backpressureAttempts
	if attempts <= 0 {
		attempts = retry429Attempts
	}
	*throttleAttempt++

	give := func(reason string) (bool, error) {
		t.announceBackpressureExhausted(req, *throttleAttempt, bp.requestID, reason)
		return true, nil
	}

	// A wait the server itself called long is a refusal to serve, not a request
	// to pause. Hand it back unslept and SAY the number, so the operator sees a
	// quota rather than a hang.
	if bp.tooLong {
		return give(fmt.Sprintf("the server asked for %s, which is longer than this client will ever wait on your behalf (%s); the 429 is returned unslept", bp.delay, maxRetryAfter))
	}

	if ok, why := mayReplayUnderBackpressure(req, bp); !ok {
		return give("it was not replayed because " + why)
	}

	if *throttleAttempt >= attempts {
		return give(fmt.Sprintf("the attempt cap of %d is spent", attempts))
	}

	if *waited+bp.delay > maxTotalBackpressureWait {
		return give(fmt.Sprintf("waiting a further %s would exceed the %s total-wait budget for one request (already waited %s)", bp.delay, maxTotalBackpressureWait, *waited))
	}

	// Same deadline arithmetic the 500 path uses: never turn a would-be answer
	// into a context-deadline error by sleeping through the caller's budget.
	if !t.hasBudgetFor(req, bp.delay) {
		return give(fmt.Sprintf("this request's own deadline leaves no room to wait %s and still make a real attempt", bp.delay))
	}

	// Committed to the retry. Drain so the connection is reused rather than
	// leaked, then rewind the body — a write replay that sent a consumed body
	// would be a truncated request the server might well accept.
	_, _ = io.Copy(io.Discard, resp.Body)
	_ = resp.Body.Close()

	if err := rewindBody(req); err != nil {
		return false, fmt.Errorf("barkpark: could not rewind the request body to retry after a 429: %w", err)
	}

	*waited += bp.delay
	t.throttled.Add(1)
	if t.onBackpressure != nil {
		t.onBackpressure(BackpressureNotice{
			Attempt:     *throttleAttempt,
			Of:          attempts,
			Method:      req.Method,
			URL:         req.URL.String(),
			Delay:       bp.delay,
			ServerAsked: bp.serverAsked,
		})
	}
	if err := t.sleepFor(req.Context(), bp.delay); err != nil {
		return false, fmt.Errorf("barkpark: 429 backoff interrupted: %w", err)
	}
	return false, nil
}

func (t *retryTransport) announceBackpressureExhausted(req *http.Request, attempts int, requestID, reason string) {
	if t.onBackpressureExhausted == nil {
		return
	}
	t.onBackpressureExhausted(BackpressureExhaustedNotice{
		Attempts:  attempts,
		Method:    req.Method,
		URL:       req.URL.String(),
		RequestID: requestID,
		Reason:    reason,
	})
}

// idempotentMethod reports whether req's method is one this transport may
// repeat on its own authority.
func idempotentMethod(req *http.Request) bool {
	return req != nil && (req.Method == http.MethodGet || req.Method == http.MethodHead)
}

// NewRetryTransport returns the SAME transient-internal_error retry every typed
// Client installs, wrapping base (nil means http.DefaultTransport), for a
// caller that builds its own *http.Client.
//
// It exists so the CLI's manifest dispatch — a bare http.Client that predates
// this package's retry and shared none of it — can ride the identical policy
// instead of growing a second, drifting copy: same attempt cap, same backoff,
// same stderr lines, same deadline-budget check, same refusal to touch a 4xx, a
// non-internal_error 5xx, or any method but GET/HEAD. There is ONE transport
// retry policy in this binary and this is how a second call site gets it.
func NewRetryTransport(base http.RoundTripper) http.RoundTripper {
	return &retryTransport{
		base:                    base,
		onRetry:                 stderrRetryNotifier,
		onExhausted:             stderrExhaustedNotifier,
		onBackpressure:          stderrBackpressureNotifier,
		onBackpressureExhausted: stderrBackpressureExhaustedNotifier,
	}
}

// announceExhausted fires the give-up notice, once, for a sequence that spent
// at least one retry and still ended on the transient fault. A call that never
// retried has nothing to announce — its 500 is a plain 500 and the ordinary
// error rendering already owns it.
func (t *retryTransport) announceExhausted(req *http.Request, attempts int, requestID string, retried int) {
	if retried == 0 || t.onExhausted == nil {
		return
	}
	t.onExhausted(ExhaustedNotice{
		Attempts:  attempts,
		Method:    req.Method,
		URL:       req.URL.String(),
		RequestID: requestID,
	})
}

// minAttemptBudget is the time a retry must be able to leave for the NEXT
// attempt after its wait. A healthy response off this API arrives in well under
// 100ms; one second is generous enough that a merely-slow server still gets its
// chance, and tight enough that the check actually bites near the deadline.
const minAttemptBudget = time.Second

// hasBudgetFor reports whether the request's deadline leaves room to wait `delay`
// and still make a realistic attempt. A request with NO deadline always has
// budget — an unbounded caller has not asked us to hurry.
func (t *retryTransport) hasBudgetFor(req *http.Request, delay time.Duration) bool {
	if req == nil || req.Context() == nil {
		return true
	}
	deadline, ok := req.Context().Deadline()
	if !ok {
		return true
	}
	return time.Until(deadline) > delay+minAttemptBudget
}

func (t *retryTransport) delayFor(attempt int) time.Duration {
	delays := t.delays
	if delays == nil {
		delays = retryDelays
	}
	if len(delays) == 0 {
		return 0
	}
	if attempt-1 < len(delays) {
		return delays[attempt-1]
	}
	return delays[len(delays)-1]
}

// sleepFor waits for d, honoring ctx's cancellation. It returns ctx.Err()
// promptly if ctx ends before the wait completes, nil once the full d has
// elapsed.
//
// A context that is cancellable but carries no deadline — exactly the shape
// interrupt handling threads through — is invisible to hasBudgetFor above
// (it only consults Deadline()), so this select is the only place that
// notices a mid-backoff cancellation. Without it, RoundTrip would sleep out
// the entire delay after the caller had already given up.
//
// The injected t.sleep seam (see testTransport) rides the same race: its
// completion is turned into a channel close so a test can still prove the
// cancellable path fires without spending the real delay on the happy path.
func (t *retryTransport) sleepFor(ctx context.Context, d time.Duration) error {
	if d <= 0 {
		return nil
	}
	if ctx == nil {
		ctx = context.Background()
	}

	if t.sleep != nil {
		done := make(chan struct{})
		go func() {
			t.sleep(d)
			close(done)
		}()
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-done:
			return nil
		}
	}

	timer := time.NewTimer(d)
	defer timer.Stop() // stopped on both the cancelled and the elapsed branch
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

// isRetryableServerFault reports whether resp is EXACTLY the transient fault
// this transport retries: HTTP 500 whose JSON envelope carries
// error.code == "internal_error". It also returns that envelope's request id,
// so the give-up announcement can name the LAST attempt without re-parsing a
// body the caller has not read yet.
//
// It reads a bounded prefix of the body to decide, then puts every byte it read
// back so a caller that receives this response still sees the complete body.
// Anything it cannot parse is NOT retryable — an unreadable body is not evidence
// of a transient fault.
func isRetryableServerFault(resp *http.Response) (bool, string) {
	if resp == nil || resp.StatusCode != http.StatusInternalServerError || resp.Body == nil {
		return false, ""
	}

	prefix, err := io.ReadAll(io.LimitReader(resp.Body, maxRetryProbeBytes))
	if err != nil {
		// Restore what we managed to read, then decline: a body we could not
		// finish reading is not proof of anything.
		resp.Body = restoredBody(prefix, resp.Body)
		return false, ""
	}
	resp.Body = restoredBody(prefix, resp.Body)

	// Read the code through the shared parser rather than a private struct: a
	// body whose OTHER fields are shaped unexpectedly must still yield its code,
	// or a retryable refusal silently stops being retried.
	env, ok := apierr.Parse(prefix)
	if !ok {
		return false, ""
	}
	return env.Code == retryErrorCode, env.RequestID
}

// restoredBody re-attaches an already-read prefix in front of the unread
// remainder, so peeking at a body is invisible to whoever reads it next. Closing
// the result closes the original.
func restoredBody(prefix []byte, rest io.ReadCloser) io.ReadCloser {
	return &joinedBody{
		Reader: io.MultiReader(bytes.NewReader(prefix), rest),
		closer: rest,
	}
}

type joinedBody struct {
	io.Reader
	closer io.Closer
}

func (b *joinedBody) Close() error { return b.closer.Close() }

// stderrRetryNotifier is the default announcement: one line per retry on stderr.
// stdout is reserved for `-o json`, so this can never corrupt a machine-readable
// result. Set BARKPARK_QUIET_RETRIES=1 to silence it — the Retries counter still
// counts, so silencing the line never silences the fact.
func stderrRetryNotifier(n RetryNotice) {
	if os.Getenv("BARKPARK_QUIET_RETRIES") != "" {
		return
	}
	fmt.Fprintln(os.Stderr, n.String())
}

// stderrExhaustedNotifier is the give-up announcement, on the same channel and
// under the same silencer as the per-retry line.
func stderrExhaustedNotifier(n ExhaustedNotice) {
	if os.Getenv("BARKPARK_QUIET_RETRIES") != "" {
		return
	}
	fmt.Fprintln(os.Stderr, n.String())
}

// Retries returns how many times this Client has retried a transient
// internal_error 500 since it was constructed. A non-zero count means the server
// is failing requests even if every command appeared to succeed — surface it
// rather than letting a healthy-looking exit code imply a healthy server.
func (c *Client) Retries() int64 {
	if c.retry == nil {
		return 0
	}
	return c.retry.count.Load()
}
