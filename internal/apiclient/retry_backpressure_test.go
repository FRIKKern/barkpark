// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

package apiclient

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// The envelope guerrilla actually serves on a throttle, built from
// Barkpark.Content.Errors.to_envelope({:error, :rate_limited, %{retry_after: s}}):
// code "rate_limited", message "too many requests", the wait under `details`.
// Tests parse THIS, not a synthesized shape, so a change to the server's 429
// envelope breaks the trigger here rather than silently in production.
const liveRateLimitedBody = `{"error":{"code":"rate_limited","message":"too many requests","hint":"Back off and retry after the Retry-After header's value; reduce request rate.","request_id":"GM9zQtxKp01ZaBcDEfGh","details":{"retry_after":1}}}`

// A 429 from something that is NOT our rate-limit plug: no envelope this client
// recognises. The status still means backpressure; what it does NOT carry is
// the proof that a halting plug refused the request before any handler ran.
const strangerRateLimitedBody = `<html><body>429 Too Many Requests</body></html>`

// backpressureTestTransport builds a retryTransport with instant sleeps and
// recorded backpressure notices, so a test spends microseconds rather than the
// several real seconds a 1s retry_after would cost.
func backpressureTestTransport(base http.RoundTripper) (*retryTransport, *[]BackpressureNotice, *[]BackpressureExhaustedNotice) {
	var notices []BackpressureNotice
	var gaveUp []BackpressureExhaustedNotice
	rt := &retryTransport{
		base:                    base,
		sleep:                   func(time.Duration) {},
		attempts:                retryAttempts,
		onBackpressure:          func(n BackpressureNotice) { notices = append(notices, n) },
		onBackpressureExhausted: func(n BackpressureExhaustedNotice) { gaveUp = append(gaveUp, n) },
	}
	return rt, &notices, &gaveUp
}

// headerScriptedServer is scriptedServer plus response headers, which the 429
// path needs: `Retry-After` is where the standard puts the wait.
type headerScriptedServer struct {
	scriptedServer
	headers []map[string]string
}

func (s *headerScriptedServer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	i := int(s.hits.Add(1)) - 1
	if i >= len(s.script) {
		i = len(s.script) - 1
	}
	if i < len(s.headers) {
		for k, v := range s.headers[i] {
			w.Header().Set(k, v)
		}
	}
	resp := s.script[i]
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(resp.status)
	_, _ = io.WriteString(w, resp.body)
}

// ── THE CORE ARM ────────────────────────────────────────────────────────────
//
// The measured defect, reproduced: `bp task ready` was answered 429 with
// retry_after=1 at 17:02Z on 2026-09-01 under the fleet's own load, and the
// client turned a one-second wait into a machine failure. One 429 then a 200
// must now read as a successful query.
func TestRetriesBackpressureThenSucceeds(t *testing.T) {
	srv := &scriptedServer{script: []scriptedResponse{
		{http.StatusTooManyRequests, liveRateLimitedBody},
		{http.StatusOK, `{"result":{"documents":[]}}`},
	}}
	ts := httptest.NewServer(srv)
	defer ts.Close()

	rt, notices, gaveUp := backpressureTestTransport(nil)
	resp, body := doGet(t, rt, ts.URL)

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200 — a 429 with a retry_after is BACKPRESSURE and must be waited out, not reported as a fault", resp.StatusCode)
	}
	if got := srv.hits.Load(); got != 2 {
		t.Fatalf("server hits = %d, want 2 (the throttled attempt and the one that succeeded)", got)
	}
	if body != `{"result":{"documents":[]}}` {
		t.Errorf("body = %q, want the successful payload", body)
	}
	if rt.throttled.Load() != 1 {
		t.Errorf("throttled counter = %d, want 1 — a backoff nobody can count is a throttle that hides a saturated ledger", rt.throttled.Load())
	}
	if rt.count.Load() != 0 {
		t.Errorf("the FAULT counter moved to %d on a throttle; a 429 is not a server fault and must not be counted as one", rt.count.Load())
	}
	if len(*notices) != 1 {
		t.Fatalf("backpressure notices = %d, want exactly 1 — a slow command with no line on stderr is a mystery", len(*notices))
	}
	n := (*notices)[0]
	if n.Delay != time.Second {
		t.Errorf("waited %s, want 1s — the server's own retry_after", n.Delay)
	}
	if !n.ServerAsked {
		t.Error("ServerAsked = false, but this envelope named retry_after:1")
	}
	if !strings.Contains(n.String(), "BACKPRESSURE, not a fault") {
		t.Errorf("the stderr line must say a throttle is not a fault, got %q", n.String())
	}
	if len(*gaveUp) != 0 {
		t.Errorf("a sequence that SUCCEEDED must not announce a give-up, got %d", len(*gaveUp))
	}
}

// The wait comes from the server, not from us. Both spellings carry it and the
// body's computed number wins — they agree today, and if they ever disagree the
// value the server calculated is the true one.
func TestHonorsTheServerNamedWait(t *testing.T) {
	for _, tc := range []struct {
		name    string
		body    string
		headers map[string]string
		want    time.Duration
		asked   bool
	}{
		{
			name:  "details.retry_after in the envelope",
			body:  `{"error":{"code":"rate_limited","details":{"retry_after":2}}}`,
			want:  2 * time.Second,
			asked: true,
		},
		{
			name:    "Retry-After header alone",
			body:    `{"error":{"code":"rate_limited"}}`,
			headers: map[string]string{"Retry-After": "3"},
			want:    3 * time.Second,
			asked:   true,
		},
		{
			name:    "the body's computed number beats the header",
			body:    `{"error":{"code":"rate_limited","details":{"retry_after":2}}}`,
			headers: map[string]string{"Retry-After": "4"},
			want:    2 * time.Second,
			asked:   true,
		},
		{
			name:  "no wait named anywhere falls back to our default",
			body:  `{"error":{"code":"rate_limited"}}`,
			want:  defaultBackpressureDelay,
			asked: false,
		},
		{
			name:  "a string retry_after is still a number the server meant",
			body:  `{"error":{"code":"rate_limited","details":{"retry_after":"2"}}}`,
			want:  2 * time.Second,
			asked: true,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			srv := &headerScriptedServer{
				scriptedServer: scriptedServer{script: []scriptedResponse{
					{http.StatusTooManyRequests, tc.body},
					{http.StatusOK, `{"ok":true}`},
				}},
				headers: []map[string]string{tc.headers},
			}
			ts := httptest.NewServer(srv)
			defer ts.Close()

			rt, notices, _ := backpressureTestTransport(nil)
			resp, _ := doGet(t, rt, ts.URL)

			if resp.StatusCode != http.StatusOK {
				t.Fatalf("status = %d, want 200 after the backoff", resp.StatusCode)
			}
			if len(*notices) != 1 {
				t.Fatalf("notices = %d, want 1", len(*notices))
			}
			if got := (*notices)[0].Delay; got != tc.want {
				t.Errorf("waited %s, want %s — the client must honor the wait the SERVER named, not one of its own choosing", got, tc.want)
			}
			if got := (*notices)[0].ServerAsked; got != tc.asked {
				t.Errorf("ServerAsked = %v, want %v — the stderr line must not claim the server asked for a wait we invented", got, tc.asked)
			}
		})
	}
}

// ── THE WRITE DECISION, BOTH DIRECTIONS ─────────────────────────────────────
//
// A 429 from OUR rate limiter proves a halting Plug refused the request before
// the controller ran, so the write did not happen and a replay cannot duplicate
// it. `bp task pulse` is a POST and the pulse loops are most of the load that
// produced the throttle — a pulse lost to a 429 lets a claim lease lapse.
func TestReplaysAWriteWhenOurOwnRateLimiterRefusedIt(t *testing.T) {
	for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodPatch, http.MethodDelete} {
		t.Run(method, func(t *testing.T) {
			var seen []string
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				b, _ := io.ReadAll(r.Body)
				seen = append(seen, string(b))
				w.Header().Set("Content-Type", "application/json")
				if len(seen) == 1 {
					w.WriteHeader(http.StatusTooManyRequests)
					_, _ = io.WriteString(w, liveRateLimitedBody)
					return
				}
				w.WriteHeader(http.StatusOK)
				_, _ = io.WriteString(w, `{"ok":true}`)
			}))
			defer srv.Close()

			rt, notices, _ := backpressureTestTransport(nil)
			// http.NewRequest with a *strings.Reader sets GetBody, which is
			// what makes the replay a whole request rather than a truncated one.
			req, err := http.NewRequest(method, srv.URL, strings.NewReader(`{"worker":"w2"}`))
			if err != nil {
				t.Fatalf("new request: %v", err)
			}
			resp, err := rt.RoundTrip(req)
			if err != nil {
				t.Fatalf("round trip: %v", err)
			}
			_ = resp.Body.Close()

			if resp.StatusCode != http.StatusOK {
				t.Fatalf("status = %d, want 200 — a 429 from a plug that HALTED did not perform the write, so replaying it cannot duplicate anything", resp.StatusCode)
			}
			if len(seen) != 2 {
				t.Fatalf("server saw %d requests, want 2", len(seen))
			}
			if seen[0] != `{"worker":"w2"}` || seen[1] != `{"worker":"w2"}` {
				t.Errorf("the replayed body must be byte-identical, got %q then %q — a half-rewound body is a truncated write the server might well accept", seen[0], seen[1])
			}
			if len(*notices) != 1 {
				t.Errorf("notices = %d, want 1", len(*notices))
			}
		})
	}
}

// The other direction, and it is the load-bearing one. A 429 with no envelope
// this client recognises could have come from anything between us and Phoenix.
// We know what OUR plug did before it answered; we do not know what a stranger
// did, so a write is NOT replayed on a stranger's word.
func TestDoesNotReplayAWriteOnAnUnrecognisedThrottle(t *testing.T) {
	for _, tc := range []struct {
		name string
		body string
	}{
		{"no envelope at all", strangerRateLimitedBody},
		{"a JSON envelope with a different code", `{"error":{"code":"quota_exceeded"}}`},
		{"a bare-string error", `{"error":"slow down"}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			srv := &scriptedServer{script: []scriptedResponse{
				{http.StatusTooManyRequests, tc.body},
				{http.StatusOK, `{"ok":true}`},
			}}
			ts := httptest.NewServer(srv)
			defer ts.Close()

			rt, notices, gaveUp := backpressureTestTransport(nil)
			req, err := http.NewRequest(http.MethodPost, ts.URL, strings.NewReader(`{}`))
			if err != nil {
				t.Fatalf("new request: %v", err)
			}
			resp, err := rt.RoundTrip(req)
			if err != nil {
				t.Fatalf("round trip: %v", err)
			}
			_ = resp.Body.Close()

			if got := srv.hits.Load(); got != 1 {
				t.Fatalf("server hits = %d, want exactly 1 — a write is never replayed on an unidentified 429", got)
			}
			if resp.StatusCode != http.StatusTooManyRequests {
				t.Errorf("status = %d, want the 429 handed back", resp.StatusCode)
			}
			if len(*notices) != 0 {
				t.Errorf("nothing was waited, so nothing may be announced as a backoff (got %d)", len(*notices))
			}
			// It still has to SAY something. A 429 returned in silence is the
			// original defect: the caller sees a non-2xx and files an outage.
			if len(*gaveUp) != 1 {
				t.Fatalf("give-up notices = %d, want 1 — a 429 handed back without a word is what makes a throttle look like a broken machine", len(*gaveUp))
			}
			if !strings.Contains((*gaveUp)[0].String(), "throttling this client, not failing") {
				t.Errorf("the give-up line must name the condition as throttling, got %q", (*gaveUp)[0].String())
			}
		})
	}
}

// A GET is replayable by definition, so an unrecognised 429 still gets its
// retry — only the WRITE decision needed the envelope.
func TestARawThrottleStillRetriesAGet(t *testing.T) {
	srv := &scriptedServer{script: []scriptedResponse{
		{http.StatusTooManyRequests, strangerRateLimitedBody},
		{http.StatusOK, `{"ok":true}`},
	}}
	ts := httptest.NewServer(srv)
	defer ts.Close()

	rt, notices, _ := backpressureTestTransport(nil)
	resp, _ := doGet(t, rt, ts.URL)

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200 — a GET's replay needs no envelope to authorise it", resp.StatusCode)
	}
	if len(*notices) != 1 {
		t.Errorf("notices = %d, want 1", len(*notices))
	}
}

// ── THE BOUNDS ──────────────────────────────────────────────────────────────
//
// The pulse plugin answers `Retry-After: 3600` when a channel spends its daily
// cap. Honoring that literally would hang for an hour and be indistinguishable
// from a wedged process. A big number is a real "go away", not a blip.
func TestRefusesToSleepOutALongRetryAfter(t *testing.T) {
	srv := &headerScriptedServer{
		scriptedServer: scriptedServer{script: []scriptedResponse{
			{http.StatusTooManyRequests, `{"error":{"code":"rate_limited","details":{"retry_after":3600}}}`},
			{http.StatusOK, `{"ok":true}`},
		}},
	}
	ts := httptest.NewServer(srv)
	defer ts.Close()

	rt, notices, gaveUp := backpressureTestTransport(nil)
	resp, _ := doGet(t, rt, ts.URL)

	if got := srv.hits.Load(); got != 1 {
		t.Fatalf("server hits = %d, want exactly 1 — an hour-long retry_after is a quota, and waiting it out would look like a hang", got)
	}
	if resp.StatusCode != http.StatusTooManyRequests {
		t.Errorf("status = %d, want the 429 returned unslept", resp.StatusCode)
	}
	if len(*notices) != 0 {
		t.Errorf("no wait was taken, so no backoff may be announced (got %d)", len(*notices))
	}
	if len(*gaveUp) != 1 {
		t.Fatalf("give-up notices = %d, want 1 — the operator must be told the server asked for an hour", len(*gaveUp))
	}
	if !strings.Contains((*gaveUp)[0].Reason, "1h0m0s") {
		t.Errorf("the give-up reason must quote the number the server asked for, got %q", (*gaveUp)[0].Reason)
	}
}

// However many small waits the server asks for, one RoundTrip is bounded. A
// command that quietly takes a minute is not a fixed command.
func TestTotalWaitIsBounded(t *testing.T) {
	// Every answer is a 429 asking for the maximum single wait, so the
	// total-wait budget bites before the attempt cap does.
	srv := &scriptedServer{script: []scriptedResponse{
		{http.StatusTooManyRequests, `{"error":{"code":"rate_limited","details":{"retry_after":5}}}`},
	}}
	ts := httptest.NewServer(srv)
	defer ts.Close()

	rt, notices, gaveUp := backpressureTestTransport(nil)
	resp, _ := doGet(t, rt, ts.URL)

	if resp.StatusCode != http.StatusTooManyRequests {
		t.Errorf("status = %d, want the honest 429 once the budget is spent", resp.StatusCode)
	}
	var total time.Duration
	for _, n := range *notices {
		total += n.Delay
	}
	if total > maxTotalBackpressureWait {
		t.Fatalf("waited %s in one RoundTrip, over the %s budget", total, maxTotalBackpressureWait)
	}
	if len(*gaveUp) != 1 {
		t.Fatalf("give-up notices = %d, want 1", len(*gaveUp))
	}
	if !strings.Contains((*gaveUp)[0].Reason, "total-wait budget") {
		t.Errorf("the give-up must name the budget that ended it, got %q", (*gaveUp)[0].Reason)
	}
}

// The attempt cap, on a server that is throttling permanently.
func TestGivesUpAfterTheBackpressureCap(t *testing.T) {
	srv := &scriptedServer{script: []scriptedResponse{
		{http.StatusTooManyRequests, liveRateLimitedBody},
	}}
	ts := httptest.NewServer(srv)
	defer ts.Close()

	rt, notices, gaveUp := backpressureTestTransport(nil)
	resp, body := doGet(t, rt, ts.URL)

	if got := srv.hits.Load(); got != int32(retry429Attempts) {
		t.Fatalf("server hits = %d, want %d", got, retry429Attempts)
	}
	if resp.StatusCode != http.StatusTooManyRequests {
		t.Errorf("status = %d, want the honest 429", resp.StatusCode)
	}
	if body != liveRateLimitedBody {
		t.Errorf("the caller must still receive the full envelope, got %q", body)
	}
	if len(*notices) != retry429Attempts-1 {
		t.Errorf("notices = %d, want %d", len(*notices), retry429Attempts-1)
	}
	if len(*gaveUp) != 1 {
		t.Fatalf("give-up notices = %d, want 1", len(*gaveUp))
	}
	g := (*gaveUp)[0]
	if g.RequestID != "GM9zQtxKp01ZaBcDEfGh" {
		t.Errorf("the give-up must name the LAST attempt's request id, got %q", g.RequestID)
	}
	if !strings.Contains(g.Reason, "attempt cap") {
		t.Errorf("the give-up must name the bound that ended it, got %q", g.Reason)
	}
}

// A cancelled caller must not be left sleeping out a backoff nobody awaits.
func TestBackpressureBackoffHonorsCancellation(t *testing.T) {
	srv := &scriptedServer{script: []scriptedResponse{
		{http.StatusTooManyRequests, liveRateLimitedBody},
	}}
	ts := httptest.NewServer(srv)
	defer ts.Close()

	rt, _, _ := backpressureTestTransport(nil)
	rt.sleep = nil // use the real timer so the cancellation race is the real one

	ctx, cancel := context.WithCancel(context.Background())
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, ts.URL, nil)
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	go func() {
		time.Sleep(20 * time.Millisecond)
		cancel()
	}()
	start := time.Now()
	if _, err := rt.RoundTrip(req); err == nil {
		t.Fatal("want an error once the caller cancelled mid-backoff")
	}
	if elapsed := time.Since(start); elapsed > defaultBackpressureDelay {
		t.Errorf("returned after %s — a cancelled caller must not wait out the full %s backoff", elapsed, defaultBackpressureDelay)
	}
}

// ── THE REGRESSION GUARD ────────────────────────────────────────────────────
//
// Adding the 429 arm meant moving the idempotence gate off the top of
// RoundTrip and into the per-response decision. That move could have opened the
// 500 path to writes, which would reinstate the duplicate-publish defect
// retry.go was written against. It did not, and this proves it stays that way.
func TestMovingTheGateDidNotOpenThe500PathToWrites(t *testing.T) {
	for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodPatch, http.MethodDelete} {
		t.Run(method, func(t *testing.T) {
			srv := &scriptedServer{script: []scriptedResponse{
				{http.StatusInternalServerError, liveInternalErrorBody},
				{http.StatusOK, `{"ok":true}`},
			}}
			ts := httptest.NewServer(srv)
			defer ts.Close()

			rt, notices, _ := backpressureTestTransport(nil)
			rt.onRetry = func(RetryNotice) {}
			req, err := http.NewRequest(method, ts.URL, strings.NewReader(`{}`))
			if err != nil {
				t.Fatalf("new request: %v", err)
			}
			resp, err := rt.RoundTrip(req)
			if err != nil {
				t.Fatalf("round trip: %v", err)
			}
			_ = resp.Body.Close()

			if got := srv.hits.Load(); got != 1 {
				t.Fatalf("server hits = %d, want exactly 1 — a 500 says NOTHING about whether the %s landed, so it must never be repeated", got, method)
			}
			if rt.count.Load() != 0 || len(*notices) != 0 {
				t.Errorf("a write must not be retried on a 500 (count=%d)", rt.count.Load())
			}
		})
	}
}

// ── THE OPT-OUT ─────────────────────────────────────────────────────────────
//
// internal/manifest.Fetch handled a 429 before this transport did, and better:
// it re-asks once after the named interval, then serves a VALIDATED CACHED
// MANIFEST. Stacking four transport waits underneath that would make a
// throttled `bp` sit for ~12s before reaching a cache that could have answered
// instantly — the same disease as the bug, one layer down.
func TestACallerThatOwnsBackpressureGetsThe429Immediately(t *testing.T) {
	srv := &scriptedServer{script: []scriptedResponse{
		{http.StatusTooManyRequests, liveRateLimitedBody},
		{http.StatusOK, `{"ok":true}`},
	}}
	ts := httptest.NewServer(srv)
	defer ts.Close()

	rt, notices, gaveUp := backpressureTestTransport(nil)
	req, err := http.NewRequestWithContext(
		WithCallerOwnedBackpressure(context.Background()), http.MethodGet, ts.URL, nil)
	if err != nil {
		t.Fatalf("new request: %v", err)
	}
	resp, err := rt.RoundTrip(req)
	if err != nil {
		t.Fatalf("round trip: %v", err)
	}
	_ = resp.Body.Close()

	if got := srv.hits.Load(); got != 1 {
		t.Fatalf("server hits = %d, want exactly 1 — the caller owns this 429 and the transport must not spend waits underneath it", got)
	}
	if resp.StatusCode != http.StatusTooManyRequests {
		t.Errorf("status = %d, want the 429 handed straight to the caller", resp.StatusCode)
	}
	if rt.throttled.Load() != 0 {
		t.Errorf("throttled counter = %d, want 0 — nothing was waited", rt.throttled.Load())
	}
	// SILENTLY is part of the contract: the owning layer will say its own piece,
	// and two announcements for one throttle is how a log stops being read.
	if len(*notices) != 0 || len(*gaveUp) != 0 {
		t.Errorf("the transport must step aside without a word (notices=%d giveUps=%d)", len(*notices), len(*gaveUp))
	}
}

// The opt-out is opt-OUT, not opt-in: a request that does not ask for it still
// gets the backoff. Forgetting to opt in is the failure mode that filed the row.
func TestTheDefaultIsStillToRetry(t *testing.T) {
	srv := &scriptedServer{script: []scriptedResponse{
		{http.StatusTooManyRequests, liveRateLimitedBody},
		{http.StatusOK, `{"ok":true}`},
	}}
	ts := httptest.NewServer(srv)
	defer ts.Close()

	rt, notices, _ := backpressureTestTransport(nil)
	// A plain context — no marker.
	req, _ := http.NewRequestWithContext(context.Background(), http.MethodGet, ts.URL, nil)
	resp, err := rt.RoundTrip(req)
	if err != nil {
		t.Fatalf("round trip: %v", err)
	}
	_ = resp.Body.Close()

	if resp.StatusCode != http.StatusOK || len(*notices) != 1 {
		t.Errorf("an unmarked request must still be retried (status=%d notices=%d)", resp.StatusCode, len(*notices))
	}
}
