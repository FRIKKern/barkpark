// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

package cloudclient

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"
)

// recordingTransport wraps a base and counts the requests that reached it.
type recordingTransport struct {
	mu      sync.Mutex
	calls   int
	bodies  []string
	wrapped http.RoundTripper
}

func (t *recordingTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	t.mu.Lock()
	t.calls++
	if req.Body != nil && req.Body != http.NoBody && req.GetBody != nil {
		if r, err := req.GetBody(); err == nil {
			b, _ := io.ReadAll(r)
			t.bodies = append(t.bodies, string(b))
		}
	}
	t.mu.Unlock()
	base := t.wrapped
	if base == nil {
		base = http.DefaultTransport
	}
	return base.RoundTrip(req)
}

func (t *recordingTransport) count() int {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.calls
}

// testTransport is newRetryTransport with a recorded, instant sleep so the test
// spends no wall-clock time but still PROVES the honoured wait is the server's
// number rather than a hardcoded one.
func testTransport(base http.RoundTripper, slept *[]time.Duration, mu *sync.Mutex) *retryTransport {
	return &retryTransport{
		base: base,
		sleep: func(ctx context.Context, d time.Duration) error {
			mu.Lock()
			*slept = append(*slept, d)
			mu.Unlock()
			return ctx.Err()
		},
	}
}

// THE TASK'S TWO ARMS, IN ONE RUN. A 429 that names retry_after is retried and
// succeeds; a 500 and a 403 are handed straight back on the first attempt.
//
// The arms live in one test function on purpose. A retry that repeats
// everything and a retry that repeats nothing each pass HALF of this — only a
// run that measures both says the policy is 429-shaped.
func TestBackpressureRetriedAndServerFaultsAreNot(t *testing.T) {
	type arm struct {
		name string
		// serve writes the nth (1-based) response.
		serve func(w http.ResponseWriter, n int)
		// wantCalls is how many requests must reach the server.
		wantCalls int
		// wantStatus is what the caller must finally see.
		wantStatus int
		// wantSlept is the exact wait ladder the transport must have honoured.
		wantSlept []time.Duration
	}
	arms := []arm{
		{
			// The control plane's FLAT envelope — the shape
			// cloud/lib/barkpark_cloud/web/router.ex:834 emits, with NO
			// Retry-After header, which is why apiclient's transport cannot
			// read it.
			name: "429 naming retry_after is retried and succeeds",
			serve: func(w http.ResponseWriter, n int) {
				if n == 1 {
					w.WriteHeader(http.StatusTooManyRequests)
					_ = json.NewEncoder(w).Encode(map[string]any{"error": "rate_limited", "retry_after": 2})
					return
				}
				w.WriteHeader(http.StatusOK)
				_, _ = io.WriteString(w, `{"ok":true}`)
			},
			wantCalls:  2,
			wantStatus: http.StatusOK,
			// 2s, FROM THE RESPONSE — not defaultBackpressureDelay (1s).
			wantSlept: []time.Duration{2 * time.Second},
		},
		{
			name: "500 is NOT retried",
			serve: func(w http.ResponseWriter, n int) {
				w.WriteHeader(http.StatusInternalServerError)
				_, _ = io.WriteString(w, `{"error":"internal_error"}`)
			},
			wantCalls:  1,
			wantStatus: http.StatusInternalServerError,
			wantSlept:  nil,
		},
		{
			name: "403 is NOT retried",
			serve: func(w http.ResponseWriter, n int) {
				w.WriteHeader(http.StatusForbidden)
				_, _ = io.WriteString(w, `{"error":"forbidden"}`)
			},
			wantCalls:  1,
			wantStatus: http.StatusForbidden,
			wantSlept:  nil,
		},
	}

	for _, a := range arms {
		t.Run(a.name, func(t *testing.T) {
			var n int
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				n++
				a.serve(w, n)
			}))
			defer srv.Close()

			rec := &recordingTransport{}
			var mu sync.Mutex
			var slept []time.Duration
			c := &http.Client{Transport: testTransport(rec, &slept, &mu)}

			resp, err := c.Get(srv.URL + "/v1/barkparks")
			if err != nil {
				t.Fatalf("request: %v", err)
			}
			defer resp.Body.Close()
			body, _ := io.ReadAll(resp.Body)

			if got := rec.count(); got != a.wantCalls {
				t.Errorf("server saw %d request(s), want %d", got, a.wantCalls)
			}
			if resp.StatusCode != a.wantStatus {
				t.Errorf("final status %d, want %d (body %q)", resp.StatusCode, a.wantStatus, body)
			}
			if len(slept) != len(a.wantSlept) {
				t.Fatalf("honoured %d wait(s) %v, want %d %v", len(slept), slept, len(a.wantSlept), a.wantSlept)
			}
			for i := range slept {
				if slept[i] != a.wantSlept[i] {
					t.Errorf("wait %d was %s, want %s — the wait must come FROM THE RESPONSE, not from a constant", i, slept[i], a.wantSlept[i])
				}
			}
			// The 429 arm's body must survive the peek intact.
			if a.wantStatus == http.StatusOK && string(body) != `{"ok":true}` {
				t.Errorf("body after the retry was %q — the classifier consumed it", body)
			}
			if a.wantStatus == http.StatusForbidden && !strings.Contains(string(body), "forbidden") {
				t.Errorf("403 body did not reach the caller: %q", body)
			}
		})
	}
}

// A 429 with NO retry_after (the register / start / approve branches answer
// `{"error":"rate_limited"}` bare) falls back to our default — and the default
// is used ONLY then.
func TestBareRateLimitedUsesTheDefaultWait(t *testing.T) {
	var n int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n++
		if n == 1 {
			w.WriteHeader(http.StatusTooManyRequests)
			_, _ = io.WriteString(w, `{"error":"rate_limited"}`)
			return
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	var mu sync.Mutex
	var slept []time.Duration
	c := &http.Client{Transport: testTransport(nil, &slept, &mu)}
	resp, err := c.Get(srv.URL)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status %d, want 200", resp.StatusCode)
	}
	if len(slept) != 1 || slept[0] != defaultBackpressureDelay {
		t.Fatalf("waits %v, want exactly one %s", slept, defaultBackpressureDelay)
	}
}

// A retry_after ABOVE maxRetryAfter is a refusal to serve, not a request to
// pause: it is handed back UNSLEPT.
func TestOversizedRetryAfterIsNotSlept(t *testing.T) {
	var n int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n++
		w.WriteHeader(http.StatusTooManyRequests)
		_, _ = fmt.Fprintf(w, `{"error":"rate_limited","retry_after":3600}`)
	}))
	defer srv.Close()

	var mu sync.Mutex
	var slept []time.Duration
	c := &http.Client{Transport: testTransport(nil, &slept, &mu)}
	resp, err := c.Get(srv.URL)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("status %d, want 429", resp.StatusCode)
	}
	if n != 1 {
		t.Errorf("server saw %d requests, want 1 — an hour-long retry_after must not be slept", n)
	}
	if len(slept) != 0 {
		t.Errorf("slept %v, want nothing", slept)
	}
}

// The attempt cap and the total-wait ceiling BOTH bound the sequence: a server
// that keeps throttling never produces an unbounded wait.
func TestAttemptCapAndTotalWaitCeilingBound(t *testing.T) {
	t.Run("attempt cap", func(t *testing.T) {
		var n int
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			n++
			w.WriteHeader(http.StatusTooManyRequests)
			_, _ = io.WriteString(w, `{"error":"rate_limited","retry_after":1}`)
		}))
		defer srv.Close()

		var mu sync.Mutex
		var slept []time.Duration
		c := &http.Client{Transport: testTransport(nil, &slept, &mu)}
		resp, err := c.Get(srv.URL)
		if err != nil {
			t.Fatalf("request: %v", err)
		}
		defer resp.Body.Close()
		if n != retry429Attempts {
			t.Errorf("server saw %d requests, want the cap of %d", n, retry429Attempts)
		}
		var total time.Duration
		for _, d := range slept {
			total += d
		}
		if total > maxTotalBackpressureWait {
			t.Errorf("total wait %s exceeds the %s ceiling", total, maxTotalBackpressureWait)
		}
	})

	t.Run("total-wait ceiling bites before the cap", func(t *testing.T) {
		var n int
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			n++
			w.WriteHeader(http.StatusTooManyRequests)
			// 5s each: the second wait would reach the 10s ceiling, the third
			// would pass it.
			_, _ = io.WriteString(w, `{"error":"rate_limited","retry_after":5}`)
		}))
		defer srv.Close()

		var mu sync.Mutex
		var slept []time.Duration
		c := &http.Client{Transport: testTransport(nil, &slept, &mu)}
		resp, err := c.Get(srv.URL)
		if err != nil {
			t.Fatalf("request: %v", err)
		}
		defer resp.Body.Close()
		if n >= retry429Attempts {
			t.Errorf("server saw %d requests — the ceiling should have stopped it before the cap of %d", n, retry429Attempts)
		}
		var total time.Duration
		for _, d := range slept {
			total += d
		}
		if total > maxTotalBackpressureWait {
			t.Errorf("total wait %s exceeds the %s ceiling", total, maxTotalBackpressureWait)
		}
	})
}

// A POST is replayed only on OUR envelope, and never on a stranger's bare 429.
func TestWriteReplayNeedsOurEnvelope(t *testing.T) {
	cases := []struct {
		name      string
		body      string
		wantCalls int
	}{
		{"our rate_limited envelope replays the POST", `{"error":"rate_limited","retry_after":1}`, 2},
		{"a bare 429 from an intermediary does not", `<html>429 Too Many Requests</html>`, 1},
		{"a 429 with someone else's code does not", `{"error":"upstream_throttled"}`, 1},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var n int
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				n++
				if n == 1 {
					w.WriteHeader(http.StatusTooManyRequests)
					_, _ = io.WriteString(w, tc.body)
					return
				}
				w.WriteHeader(http.StatusOK)
			}))
			defer srv.Close()

			rec := &recordingTransport{}
			var mu sync.Mutex
			var slept []time.Duration
			c := &http.Client{Transport: testTransport(rec, &slept, &mu)}
			resp, err := c.Post(srv.URL+"/v1/auth/login", "application/json", strings.NewReader(`{"email":"a@b.c"}`))
			if err != nil {
				t.Fatalf("request: %v", err)
			}
			defer resp.Body.Close()
			if n != tc.wantCalls {
				t.Fatalf("server saw %d POST(s), want %d", n, tc.wantCalls)
			}
			if tc.wantCalls == 2 {
				rec.mu.Lock()
				bodies := append([]string(nil), rec.bodies...)
				rec.mu.Unlock()
				if len(bodies) != 2 || bodies[0] != bodies[1] {
					t.Errorf("the replayed body differed from the original: %q", bodies)
				}
			}
		})
	}
}

// THE WIRING PROOF. Every lazily-built client in this package must carry the
// policy — this is what a future `&http.Client{Timeout: …}` breaks.
func TestEveryLazyClientCarriesTheRetryPolicy(t *testing.T) {
	for _, tc := range []struct {
		name    string
		client  *http.Client
		timeout time.Duration
	}{
		{"Client.httpClient fallback", (&Client{}).httpClient(), DefaultTimeout},
		{"DomainStatus widening", newHTTPClient(DomainStatusTimeout), DomainStatusTimeout},
		{"VerifyInstance / Rollback / TriggerSelfUpdate widening", newHTTPClient(VerifyTimeout), VerifyTimeout},
		{"FleetDeployCensus widening", newHTTPClient(FleetDeployCensusTimeout), FleetDeployCensusTimeout},
		{"UploadDeploymentArtifact (ctx-bounded, no client timeout)", newHTTPClient(0), 0},
		{"SiteDoctor widening", newHTTPClient(SiteDoctorTimeout), SiteDoctorTimeout},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if tc.client.Timeout != tc.timeout {
				t.Errorf("timeout %s, want %s — the widening must survive the wiring", tc.client.Timeout, tc.timeout)
			}
			if _, ok := tc.client.Transport.(*retryTransport); !ok {
				t.Fatalf("transport is %T, not *retryTransport — this client opted out of backpressure handling", tc.client.Transport)
			}
		})
	}
}

// An injected client (every test in this package, and any caller that supplies
// its own) is still honoured untouched: the policy rides the FALLBACK only.
func TestInjectedClientIsNotRewritten(t *testing.T) {
	injected := &http.Client{Timeout: 7 * time.Second}
	c := &Client{HTTP: injected}
	if c.httpClient() != injected {
		t.Fatal("httpClient() did not return the injected client")
	}
}

// THE PREDICATE. The table above is a snapshot of the clients somebody
// remembered to list; SiteDoctor shipped a bare `&http.Client{Timeout: …}`
// (#17490) the day after the table was written and nothing reddened, because a
// list cannot see a sibling it was not told about. So: scan every non-test
// source file in this package and refuse any `&http.Client{` outside retry.go,
// which is the one place allowed to construct one. Positive control: retry.go
// itself must contain the construction, or the scan cannot see what it guards.
func TestNoSourceFileBuildsABareHTTPClientOutsideRetryGo(t *testing.T) {
	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatal(err)
	}
	const needle = "&http.Client{"
	scanned, offenders, control := 0, []string{}, false
	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		raw, err := os.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		scanned++
		for i, line := range strings.Split(string(raw), "\n") {
			code := line
			if k := strings.Index(code, "//"); k >= 0 {
				code = code[:k]
			}
			if !strings.Contains(code, needle) {
				continue
			}
			if name == "retry.go" {
				control = true
				continue
			}
			offenders = append(offenders, fmt.Sprintf("%s:%d: %s", name, i+1, strings.TrimSpace(line)))
		}
	}
	if scanned == 0 {
		t.Fatal("scanned zero source files — the scan cannot see the package it guards")
	}
	if !control {
		t.Fatal("retry.go carries no &http.Client{ construction — the positive control is gone, so an empty offender list proves nothing")
	}
	if len(offenders) > 0 {
		t.Fatalf("%d bare &http.Client{ construction(s) outside retry.go — each one opts out of the 429/retry_after policy; use newHTTPClient(timeout):\n  %s", len(offenders), strings.Join(offenders, "\n  "))
	}
}
