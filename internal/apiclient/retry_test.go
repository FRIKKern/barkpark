// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

package apiclient

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// The body guerrilla actually served on 2026-08-23, verbatim from an
// unauthenticated curl (task-d89e42ea727bffb7). Tests parse THIS, not a
// synthesized envelope, so a change to the server's error shape breaks the
// retry's trigger here rather than silently in production.
const liveInternalErrorBody = `{"error":{"code":"internal_error","message":"unknown error (DBConnection.ConnectionError)","hint":"Retry shortly; if it persists, report the request_id to the API operator.","request_id":"GM5eMgixS765GScABWKi"}}`

// The SECOND shape the same incident served ~20 minutes later — same code, no
// fault family. Both must trigger the retry, because the CODE is the contract
// and the message is not.
const liveServerErrorBody = `{"error":{"code":"internal_error","hint":"Retry shortly; if it persists, report the request_id to the API operator.","message":"server error (GM5fHfxmaSAihpQADOsy)","request_id":"GM5fHfxmaSAihpQADOsy"}}`

// testTransport builds a retryTransport with instant sleeps and a recorded
// notice list, so a test spends microseconds instead of 1.25 real seconds.
func testTransport(base http.RoundTripper) (*retryTransport, *[]RetryNotice) {
	var notices []RetryNotice
	rt := &retryTransport{
		base:     base,
		sleep:    func(time.Duration) {},
		onRetry:  func(n RetryNotice) { notices = append(notices, n) },
		attempts: retryAttempts,
	}
	return rt, &notices
}

// scriptedServer answers each successive request with the next entry of script.
// It counts hits so a test can assert "exactly one request was made" — the only
// way to prove a NON-retry.
type scriptedServer struct {
	hits   atomic.Int32
	script []scriptedResponse
}

type scriptedResponse struct {
	status int
	body   string
}

func (s *scriptedServer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	i := int(s.hits.Add(1)) - 1
	if i >= len(s.script) {
		i = len(s.script) - 1
	}
	resp := s.script[i]
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(resp.status)
	_, _ = io.WriteString(w, resp.body)
}

func doGet(t *testing.T, rt http.RoundTripper, url string) (*http.Response, string) {
	t.Helper()
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	resp, err := rt.RoundTrip(req)
	if err != nil {
		t.Fatalf("round trip: %v", err)
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	_ = resp.Body.Close()
	return resp, string(body)
}

// THE CORE ARM: the incident's own body, served once, then a 200. The retry must
// turn that into a successful read.
func TestRetriesTransientInternalErrorThenSucceeds(t *testing.T) {
	for _, tc := range []struct {
		name string
		body string
	}{
		{"the DBConnection fault-family shape", liveInternalErrorBody},
		{"the bare server-error shape, same code", liveServerErrorBody},
	} {
		t.Run(tc.name, func(t *testing.T) {
			srv := &scriptedServer{script: []scriptedResponse{
				{http.StatusInternalServerError, tc.body},
				{http.StatusOK, `{"ok":true}`},
			}}
			ts := httptest.NewServer(srv)
			defer ts.Close()

			rt, notices := testTransport(nil)
			resp, body := doGet(t, rt, ts.URL)

			if resp.StatusCode != http.StatusOK {
				t.Errorf("status = %d, want 200 (the retry should have reached the healthy response)", resp.StatusCode)
			}
			if body != `{"ok":true}` {
				t.Errorf("body = %q, want the second response's body", body)
			}
			if got := srv.hits.Load(); got != 2 {
				t.Errorf("server hits = %d, want 2 (one failure, one retry)", got)
			}
			if rt.count.Load() != 1 {
				t.Errorf("retry count = %d, want 1 — a retry nobody counts is a retry that hides a sick server", rt.count.Load())
			}
			if len(*notices) != 1 {
				t.Fatalf("notices = %d, want 1: the retry MUST announce itself", len(*notices))
			}
			n := (*notices)[0]
			if n.Attempt != 1 || n.Of != retryAttempts || n.Method != http.MethodGet {
				t.Errorf("notice = %+v, want attempt 1 of %d on GET", n, retryAttempts)
			}
			if !strings.Contains(n.String(), "retrying") {
				t.Errorf("notice text = %q, want it to say it is retrying", n.String())
			}
		})
	}
}

// A POST IS NEVER RETRIED. This is the arm that protects against the exact thing
// that happened while filing task-d89e42ea727bffb7: a publish returned 500 and
// had ALREADY LANDED. Retrying it would have filed a duplicate.
func TestNeverRetriesAWrite(t *testing.T) {
	for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodPatch, http.MethodDelete} {
		t.Run(method, func(t *testing.T) {
			srv := &scriptedServer{script: []scriptedResponse{
				{http.StatusInternalServerError, liveInternalErrorBody},
				{http.StatusOK, `{"ok":true}`},
			}}
			ts := httptest.NewServer(srv)
			defer ts.Close()

			rt, notices := testTransport(nil)
			req, err := http.NewRequest(method, ts.URL, strings.NewReader(`{}`))
			if err != nil {
				t.Fatalf("new request: %v", err)
			}
			resp, err := rt.RoundTrip(req)
			if err != nil {
				t.Fatalf("round trip: %v", err)
			}
			body, _ := io.ReadAll(resp.Body)
			_ = resp.Body.Close()

			if resp.StatusCode != http.StatusInternalServerError {
				t.Errorf("status = %d, want the 500 handed straight back", resp.StatusCode)
			}
			if got := srv.hits.Load(); got != 1 {
				t.Fatalf("server hits = %d, want exactly 1 — a %s must NEVER be repeated: a 500 says nothing about whether the write landed", got, method)
			}
			if rt.count.Load() != 0 || len(*notices) != 0 {
				t.Errorf("a write must not count as a retry (count=%d notices=%d)", rt.count.Load(), len(*notices))
			}
			if string(body) != liveInternalErrorBody {
				t.Errorf("the caller must still receive the full error body, got %q", string(body))
			}
		})
	}
}

// Everything that is NOT a 500-with-internal_error is handed back on the first
// try, body intact. Each row is a separate way the retry could over-reach.
func TestNeverRetriesAnythingElse(t *testing.T) {
	for _, tc := range []struct {
		name   string
		status int
		body   string
		why    string
	}{
		{"400 validation", http.StatusBadRequest, `{"error":{"code":"validation_failed"}}`, "a refusal is an answer; repeating it is noise"},
		{"401 unauthorized", http.StatusUnauthorized, `{"error":{"code":"auth"}}`, "a bad token is not transient"},
		{"404 not found", http.StatusNotFound, `{"error":{"code":"not_found"}}`, "absence is not a blip"},
		// 429 USED TO BE A ROW HERE, and its stated reason — "hammering a rate
		// limiter is the opposite of helping" — was right about hammering and
		// wrong about the remedy. Not retrying at all made every throttle
		// render as a machine failure: MEASURED 2026-09-01 17:02Z, `bp task
		// ready` was answered 429 with retry_after=1 under this fleet's own
		// load and the one-second wait was reported to the operator as a broken
		// ledger. The row moved to retry_backpressure_test.go, where the retry
		// is PACED BY THE SERVER'S OWN NUMBER rather than hammering: it honors
		// retry_after, caps the single wait, caps the total wait, and hands the
		// 429 back unslept when the server asks for longer than we will ever
		// wait. This list stays the home of "handed back on the first try".
		{"502 bad gateway", http.StatusBadGateway, `bad gateway`, "a proxy fault is a different defect and must stay visible"},
		{"503 unavailable", http.StatusServiceUnavailable, `{"error":{"code":"unavailable"}}`, "not the code this transport claims to handle"},
		{"500 with a DIFFERENT code", http.StatusInternalServerError, `{"error":{"code":"db_migration_failed"}}`, "only internal_error is claimed as transient"},
		{"500 with no envelope at all", http.StatusInternalServerError, `<html>gateway exploded</html>`, "an unparseable body is not evidence of a transient fault"},
		{"500 with an empty body", http.StatusInternalServerError, ``, "nothing to prove it is transient"},
		{"200 that happens to look like an error", http.StatusOK, `{"error":{"code":"internal_error"}}`, "a 200 is a success; retrying it would paper over a real bug"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			srv := &scriptedServer{script: []scriptedResponse{
				{tc.status, tc.body},
				{http.StatusOK, `{"unreachable":true}`},
			}}
			ts := httptest.NewServer(srv)
			defer ts.Close()

			rt, notices := testTransport(nil)
			resp, body := doGet(t, rt, ts.URL)

			if got := srv.hits.Load(); got != 1 {
				t.Fatalf("server hits = %d, want exactly 1 — %s", got, tc.why)
			}
			if resp.StatusCode != tc.status {
				t.Errorf("status = %d, want %d passed through untouched", resp.StatusCode, tc.status)
			}
			if body != tc.body {
				t.Errorf("body = %q, want %q — the peek must be invisible to the caller", body, tc.body)
			}
			if rt.count.Load() != 0 || len(*notices) != 0 {
				t.Errorf("nothing should have been counted or announced (count=%d notices=%d)", rt.count.Load(), len(*notices))
			}
		})
	}
}

// The retry is CAPPED. A permanently sick server must produce a real failure,
// not an infinite loop, and the caller must still receive the honest 500.
func TestGivesUpAfterTheCapAndReturnsTheHonest500(t *testing.T) {
	srv := &scriptedServer{script: []scriptedResponse{
		{http.StatusInternalServerError, liveInternalErrorBody},
	}}
	ts := httptest.NewServer(srv)
	defer ts.Close()

	rt, notices := testTransport(nil)
	resp, body := doGet(t, rt, ts.URL)

	// THE CAP IS PINNED TO A LITERAL 3, deliberately not to retryAttempts.
	// Asserting against the same constant the code reads makes the test
	// self-referential: raising the constant would move the expectation with it
	// and the test could never fail. Found by mutation — setting retryAttempts
	// to 50 left this test green until this line stopped quoting the constant.
	// Three tries against a 27-50% failure rate is a deliberate budget; changing
	// it should require changing this number by hand and justifying it.
	const pinnedCap = 3
	if got := srv.hits.Load(); int(got) != pinnedCap {
		t.Errorf("server hits = %d, want exactly %d (the cap) — an uncapped retry is a denial-of-service against your own server", got, pinnedCap)
	}
	if retryAttempts != pinnedCap {
		t.Errorf("retryAttempts = %d but this suite pins the budget at %d — change it deliberately, with a reason", retryAttempts, pinnedCap)
	}
	if resp.StatusCode != http.StatusInternalServerError {
		t.Errorf("status = %d, want the honest 500 after the cap", resp.StatusCode)
	}
	if body != liveInternalErrorBody {
		t.Errorf("the caller must receive the FULL final error body so it can report the request_id, got %q", body)
	}
	if want := int64(retryAttempts - 1); rt.count.Load() != want {
		t.Errorf("retry count = %d, want %d", rt.count.Load(), want)
	}
	if len(*notices) != retryAttempts-1 {
		t.Errorf("notices = %d, want %d — every retry announces itself, including the ones that failed", len(*notices), retryAttempts-1)
	}
}

// A 500 body LARGER than the bounded peek must still reach the caller whole. The
// peek reads a prefix; the prefix has to be spliced back in front of the rest.
func TestOversizeBodyIsPreservedExactly(t *testing.T) {
	huge := `{"error":{"code":"internal_error","pad":"` + strings.Repeat("x", maxRetryProbeBytes*2) + `"}}`
	srv := &scriptedServer{script: []scriptedResponse{{http.StatusInternalServerError, huge}}}
	ts := httptest.NewServer(srv)
	defer ts.Close()

	rt, _ := testTransport(nil)
	_, body := doGet(t, rt, ts.URL)

	if body != huge {
		t.Errorf("oversize body corrupted: got %d bytes, want %d — a peek must never eat the body", len(body), len(huge))
	}
}

// The delays are the ones the incident was measured against, in order.
func TestBackoffSchedule(t *testing.T) {
	var slept []time.Duration
	rt := &retryTransport{
		sleep:    func(d time.Duration) { slept = append(slept, d) },
		onRetry:  func(RetryNotice) {},
		attempts: retryAttempts,
	}
	srv := &scriptedServer{script: []scriptedResponse{{http.StatusInternalServerError, liveInternalErrorBody}}}
	ts := httptest.NewServer(srv)
	defer ts.Close()

	doGet(t, rt, ts.URL)

	want := []time.Duration{250 * time.Millisecond, time.Second}
	if len(slept) != len(want) {
		t.Fatalf("slept %v, want %v", slept, want)
	}
	for i := range want {
		if slept[i] != want[i] {
			t.Errorf("delay[%d] = %s, want %s", i, slept[i], want[i])
		}
	}
}

// A transport-level failure (connection refused, dropped SYN) is NOT this
// helper's business. The same host dropped SYNs on 2026-08-21 — a distinct
// defect that must stay visible rather than be smoothed into a retry.
func TestTransportErrorIsNotRetried(t *testing.T) {
	var calls atomic.Int32
	rt, notices := testTransport(roundTripFunc(func(*http.Request) (*http.Response, error) {
		calls.Add(1)
		return nil, fmt.Errorf("dial tcp: connection refused")
	}))

	req, _ := http.NewRequest(http.MethodGet, "http://example.invalid/", nil)
	if _, err := rt.RoundTrip(req); err == nil {
		t.Fatal("want the transport error surfaced, got nil")
	}
	if calls.Load() != 1 {
		t.Errorf("calls = %d, want 1 — a dropped connection is a different defect and must not be retried here", calls.Load())
	}
	if len(*notices) != 0 {
		t.Errorf("nothing to announce for a transport error, got %d notices", len(*notices))
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

// Client.Retries is the programmatic signal. A command that "succeeded" after
// three retries is evidence the server is sick, and the caller must be able to
// say so.
func TestClientRetriesCounterIsReadable(t *testing.T) {
	srv := &scriptedServer{script: []scriptedResponse{
		{http.StatusInternalServerError, liveInternalErrorBody},
		{http.StatusOK, `{"ok":true}`},
	}}
	ts := httptest.NewServer(srv)
	defer ts.Close()

	c := New(Config{BaseURL: ts.URL})
	if c.Retries() != 0 {
		t.Fatalf("a fresh client has retried nothing, got %d", c.Retries())
	}
	// Drive a real GET through the client's own transport.
	c.retry.sleep = func(time.Duration) {}
	c.retry.onRetry = func(RetryNotice) {}
	resp, err := c.authGet(ts.URL)
	if err != nil {
		t.Fatalf("authGet: %v", err)
	}
	_, _ = io.ReadAll(resp.Body)
	_ = resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Errorf("status = %d, want 200 through the client's installed retry", resp.StatusCode)
	}
	if c.Retries() != 1 {
		t.Errorf("Client.Retries() = %d, want 1 — the count is the signal that the server is sick", c.Retries())
	}
}

// THE RETRY MUST NEVER TURN A SUCCESS INTO A TIMEOUT. http.Client.Timeout is a
// deadline over the whole Do call, retries included. Against a server that is
// both sick and SLOW, spending the remaining budget on sleeps means the caller
// gets a context deadline instead of the answer the next attempt would have
// given. Found by an interleaved A/B against the live box, where the retrying
// binary scored WORSE than the non-retrying one (19/40 vs 24/40) until the
// budget check existed.
func TestDoesNotRetryWhenTheDeadlineCannotAffordIt(t *testing.T) {
	for _, tc := range []struct {
		name     string
		timeout  time.Duration
		wantHits int32
		wantWhy  string
	}{
		{"a deadline with no room: one attempt only", 300 * time.Millisecond, 1,
			"250ms of sleep plus a realistic attempt does not fit in 300ms"},
		{"a deadline with ample room: retries normally", 30 * time.Second, retryAttempts,
			"there is plenty of budget, so the retry should behave as usual"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			srv := &scriptedServer{script: []scriptedResponse{{http.StatusInternalServerError, liveInternalErrorBody}}}
			ts := httptest.NewServer(srv)
			defer ts.Close()

			rt, _ := testTransport(nil)
			// Real sleeps here: the point is the interaction with a real clock.
			rt.sleep = func(d time.Duration) { time.Sleep(d) }

			c := &http.Client{Timeout: tc.timeout, Transport: rt}
			resp, err := c.Get(ts.URL)
			if err != nil {
				t.Fatalf("get: %v — the request must return the honest 500, never a deadline error", err)
			}
			body, _ := io.ReadAll(resp.Body)
			_ = resp.Body.Close()

			if got := srv.hits.Load(); got != tc.wantHits {
				t.Errorf("server hits = %d, want %d — %s", got, tc.wantHits, tc.wantWhy)
			}
			if resp.StatusCode != http.StatusInternalServerError {
				t.Errorf("status = %d, want the honest 500", resp.StatusCode)
			}
			if string(body) != liveInternalErrorBody {
				t.Errorf("body must survive intact, got %q", string(body))
			}
		})
	}
}

// A context that is CANCELLABLE but carries no deadline — exactly the shape
// interrupt handling threads through — must interrupt the inter-attempt
// backoff sleep, not be silently ignored by it. Regression for
// wbt-go-retry-context-cancel: hasBudgetFor only ever consulted Deadline(),
// and sleepFor slept unconditionally, so a mid-backoff cancellation was
// invisible to both and RoundTrip slept out the entire delay before noticing.
func TestRetryBackoffCancelledContextReturnsPromptly(t *testing.T) {
	srv := &scriptedServer{script: []scriptedResponse{
		{http.StatusInternalServerError, liveInternalErrorBody},
		{http.StatusOK, `{"ok":true}`},
	}}
	ts := httptest.NewServer(srv)
	defer ts.Close()

	rt, _ := testTransport(nil)
	// A REAL sleep here, deliberately: the point of this test is the race
	// between the backoff and the cancellation, and a no-op injected sleep
	// would make that race meaningless. The first scheduled delay is
	// retryDelays[0] (250ms); cancelling at 20ms and asserting completion
	// well under that proves the cancellation won the race, not the clock —
	// and it proves the t.sleep seam is exercisable on this path too.
	rt.sleep = func(d time.Duration) { time.Sleep(d) }

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, ts.URL, nil)
	if err != nil {
		t.Fatalf("new request: %v", err)
	}

	go func() {
		time.Sleep(20 * time.Millisecond)
		cancel()
	}()

	start := time.Now()
	resp, err := rt.RoundTrip(req)
	elapsed := time.Since(start)
	if resp != nil {
		_, _ = io.Copy(io.Discard, resp.Body)
		_ = resp.Body.Close()
	}

	if err == nil {
		t.Fatal("want an error from the cancelled backoff, got nil")
	}
	if !errors.Is(err, context.Canceled) {
		t.Errorf("err = %v, want it to wrap context.Canceled", err)
	}
	if elapsed >= retryDelays[0] {
		t.Errorf("elapsed = %s, want well under the %s backoff delay — the cancellation should have cut the sleep short", elapsed, retryDelays[0])
	}
	if got := srv.hits.Load(); got != 1 {
		t.Errorf("server hits = %d, want exactly 1 — cancellation must stop before the retried request goes out", got)
	}
}

// A request with no deadline at all is not hurried: the budget check must not
// suppress a retry just because nobody set a clock.
func TestNoDeadlineMeansFullBudget(t *testing.T) {
	srv := &scriptedServer{script: []scriptedResponse{
		{http.StatusInternalServerError, liveInternalErrorBody},
		{http.StatusOK, `{"ok":true}`},
	}}
	ts := httptest.NewServer(srv)
	defer ts.Close()

	rt, _ := testTransport(nil)
	resp, body := doGet(t, rt, ts.URL) // doGet builds a request with no deadline
	if resp.StatusCode != http.StatusOK || body != `{"ok":true}` {
		t.Errorf("an undeadlined request must still retry; got %d %q", resp.StatusCode, body)
	}
	if srv.hits.Load() != 2 {
		t.Errorf("hits = %d, want 2", srv.hits.Load())
	}
}
