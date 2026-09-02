package cli

// mcp_ratelimit_test.go — proofs for the per-client-IP token bucket that fronts
// `bp mcp serve --http` (mcp_ratelimit.go). No live box, no sleeping: the
// limiter's clock is injected, so "the window elapsed" is an assignment, not a
// wait.
//
// The obligations, one test each:
//
//  1. burst+1 from ONE IP inside the window → the last is 429 with Retry-After,
//     while a SECOND IP is still 200 (the limit is per key, not global).
//  2. the bucket refills once the window passes.
//  3. the key is the PROXY-APPENDED hop, never a header the client can set
//     end-to-end — and from an untrusted peer the header is ignored outright.
//  4. the bucket map stays bounded under a flood of distinct source IPs.
//  5. newMCPHTTPServer actually ARMS the thing (the wiring, which is what the
//     mutation proof deletes).
//  6. an SSE response already streaming is not cut off by a later refusal.

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// mcpRateTestClock is a hand-wound clock for the limiter.
type mcpRateTestClock struct{ t time.Time }

func (c *mcpRateTestClock) now() time.Time      { return c.t }
func (c *mcpRateTestClock) add(d time.Duration) { c.t = c.t.Add(d) }

// newMCPRateTestLimiter builds a limiter on a frozen clock, collecting log lines.
func newMCPRateTestLimiter(t *testing.T, rate, burst float64) (*mcpRateLimiter, *mcpRateTestClock, *[]string) {
	t.Helper()
	var logs []string
	l := newMCPRateLimiter(rate, burst, func(format string, a ...any) {
		logs = append(logs, fmt.Sprintf(format, a...))
	})
	if l == nil {
		t.Fatalf("newMCPRateLimiter(%g, %g) = nil; wanted a live limiter", rate, burst)
	}
	clock := &mcpRateTestClock{t: time.Date(2026, 9, 2, 12, 0, 0, 0, time.UTC)}
	l.now = clock.now
	return l, clock, &logs
}

// mcpRateOKHandler answers 200 and counts how many requests actually reached it.
func mcpRateOKHandler(reached *int) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		*reached++
		w.WriteHeader(http.StatusOK)
	})
}

// mcpRateDo drives one request through h from remoteAddr, with optional
// X-Forwarded-For values, and returns the recorder.
func mcpRateDo(h http.Handler, remoteAddr string, xff ...string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPost, "/mcp", strings.NewReader("{}"))
	req.RemoteAddr = remoteAddr
	for _, v := range xff {
		req.Header.Add("X-Forwarded-For", v)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

// TestMCPRateLimiterRefusesOverBurstPerIP is obligation (a): the N+1st request
// from one IP inside the window is 429 with an actionable Retry-After, and a
// different IP is untouched.
func TestMCPRateLimiterRefusesOverBurstPerIP(t *testing.T) {
	const burst = 4
	l, _, logs := newMCPRateTestLimiter(t, 2, burst)

	reached := 0
	h := l.middleware(mcpRateOKHandler(&reached))

	for i := 0; i < burst; i++ {
		if rec := mcpRateDo(h, "203.0.113.7:5000"); rec.Code != http.StatusOK {
			t.Fatalf("request %d/%d from 203.0.113.7 = %d; the bucket must admit the full burst", i+1, burst, rec.Code)
		}
	}

	rec := mcpRateDo(h, "203.0.113.7:5000")
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("request %d from 203.0.113.7 = %d; want 429 — the per-IP token bucket is NOT limiting the /mcp handler", burst+1, rec.Code)
	}
	ra := rec.Header().Get("Retry-After")
	if ra == "" {
		t.Fatal("429 carried no Retry-After header; a refusal must tell the client when to come back")
	}
	if n, err := strconv.Atoi(ra); err != nil || n < 1 {
		t.Fatalf("Retry-After = %q; want a positive whole number of seconds", ra)
	}
	if body := rec.Body.String(); !strings.Contains(body, "429") {
		t.Fatalf("429 body = %q; want it to name the limit", body)
	}

	// A SECOND IP still gets through: the clamp is per key, not global.
	if rec := mcpRateDo(h, "198.51.100.9:5000"); rec.Code != http.StatusOK {
		t.Fatalf("a DIFFERENT IP got %d while 203.0.113.7 was over limit; the bucket is keyed globally, not per client IP", rec.Code)
	}
	if reached != burst+1 {
		t.Fatalf("handler saw %d requests; want %d (the burst plus the second IP) — a refused request must never reach the MCP server", reached, burst+1)
	}

	// One loud line per offending IP per window, never one per request.
	over := 5
	for i := 0; i < over; i++ {
		mcpRateDo(h, "203.0.113.7:5000")
	}
	if len(*logs) != 1 {
		t.Fatalf("limiter logged %d lines for %d refusals from one IP in one window; want exactly 1: %v", len(*logs), over+1, *logs)
	}
	if !strings.Contains((*logs)[0], "203.0.113.7") {
		t.Fatalf("log line %q does not name the offending IP", (*logs)[0])
	}
}

// TestMCPRateLimiterRefillsAfterWindow is obligation (b).
func TestMCPRateLimiterRefillsAfterWindow(t *testing.T) {
	l, clock, _ := newMCPRateTestLimiter(t, 2 /* per second */, 2)
	reached := 0
	h := l.middleware(mcpRateOKHandler(&reached))

	mcpRateDo(h, "203.0.113.7:5000")
	mcpRateDo(h, "203.0.113.7:5000")
	if rec := mcpRateDo(h, "203.0.113.7:5000"); rec.Code != http.StatusTooManyRequests {
		t.Fatalf("third request = %d; want 429 (burst 2 spent)", rec.Code)
	}

	clock.add(time.Second) // 2 tokens/s → the bucket is full again
	if rec := mcpRateDo(h, "203.0.113.7:5000"); rec.Code != http.StatusOK {
		t.Fatalf("after a full window the request = %d; want 200 — the bucket never refills", rec.Code)
	}

	// And refill is CAPPED at the burst: an hour of quiet buys 2, not 7200.
	clock.add(time.Hour)
	mcpRateDo(h, "203.0.113.7:5000")
	mcpRateDo(h, "203.0.113.7:5000")
	if rec := mcpRateDo(h, "203.0.113.7:5000"); rec.Code != http.StatusTooManyRequests {
		t.Fatalf("after an hour idle the 3rd back-to-back request = %d; want 429 — refill is not clamped to the burst", rec.Code)
	}
}

// TestMCPRateLimiterKeysOnProxyAppendedHop is obligation (c): the key comes from
// the hop the TRUSTED proxy appended, and a header from an untrusted peer buys
// the sender nothing.
func TestMCPRateLimiterKeysOnProxyAppendedHop(t *testing.T) {
	t.Run("trusted proxy: the LAST hop is the key, the client-written first hop is not", func(t *testing.T) {
		l, _, _ := newMCPRateTestLimiter(t, 1, 2)
		reached := 0
		h := l.middleware(mcpRateOKHandler(&reached))

		// Caddy on loopback appends the peer it saw (9.9.9.9) after whatever the
		// client sent (1.2.3.4). Two requests spend the burst.
		mcpRateDo(h, "127.0.0.1:4010", "1.2.3.4, 9.9.9.9")
		mcpRateDo(h, "127.0.0.1:4010", "1.2.3.4, 9.9.9.9")

		// Same real client, a DIFFERENT self-written first hop. If the limiter
		// read the client-supplied value it would see a new key and admit this.
		if rec := mcpRateDo(h, "127.0.0.1:4010", "5.6.7.8, 9.9.9.9"); rec.Code != http.StatusTooManyRequests {
			t.Fatalf("rotating the CLIENT-WRITTEN X-Forwarded-For hop got %d; want 429 — the limiter is keying on a header the client controls, which defeats it entirely", rec.Code)
		}

		// A genuinely different real client (different appended hop) is admitted.
		if rec := mcpRateDo(h, "127.0.0.1:4010", "1.2.3.4, 8.8.8.8"); rec.Code != http.StatusOK {
			t.Fatalf("a different PROXY-APPENDED hop got %d; want 200 — distinct clients must not share a bucket", rec.Code)
		}
	})

	t.Run("untrusted peer: X-Forwarded-For is ignored, the socket peer is the key", func(t *testing.T) {
		l, _, _ := newMCPRateTestLimiter(t, 1, 2)
		reached := 0
		h := l.middleware(mcpRateOKHandler(&reached))

		// A direct (non-loopback) peer sends a fresh XFF every time. Believing it
		// would hand every request its own full bucket.
		mcpRateDo(h, "203.0.113.7:5000", "10.0.0.1")
		mcpRateDo(h, "203.0.113.7:5000", "10.0.0.2")
		if rec := mcpRateDo(h, "203.0.113.7:5000", "10.0.0.3"); rec.Code != http.StatusTooManyRequests {
			t.Fatalf("an untrusted peer rotating X-Forwarded-For got %d; want 429 — the header must be ignored from a peer that is not a configured trusted proxy", rec.Code)
		}
	})

	t.Run("trusted proxy with no header falls back to the socket peer", func(t *testing.T) {
		l, _, _ := newMCPRateTestLimiter(t, 1, 1)
		reached := 0
		h := l.middleware(mcpRateOKHandler(&reached))
		mcpRateDo(h, "127.0.0.1:4010")
		if rec := mcpRateDo(h, "127.0.0.1:4010"); rec.Code != http.StatusTooManyRequests {
			t.Fatalf("second header-less loopback request = %d; want 429 — the peer fallback key is not being applied", rec.Code)
		}
	})

	t.Run("a hop written with a port still parses", func(t *testing.T) {
		l, _, _ := newMCPRateTestLimiter(t, 1, 1)
		reached := 0
		h := l.middleware(mcpRateOKHandler(&reached))
		mcpRateDo(h, "127.0.0.1:4010", "1.2.3.4, 9.9.9.9:31000")
		if rec := mcpRateDo(h, "127.0.0.1:4010", "1.2.3.4, 9.9.9.9"); rec.Code != http.StatusTooManyRequests {
			t.Fatalf("9.9.9.9:31000 and 9.9.9.9 landed in different buckets (got %d); a hop's port must not fork the key", rec.Code)
		}
	})
}

// TestMCPRateLimiterBoundsMemoryUnderDistinctIPFlood is the memory clamp: a
// flood of distinct sources must not grow the map without limit.
func TestMCPRateLimiterBoundsMemoryUnderDistinctIPFlood(t *testing.T) {
	l, _, _ := newMCPRateTestLimiter(t, 1, 1)
	reached := 0
	h := l.middleware(mcpRateOKHandler(&reached))

	for i := 0; i < mcpRateMaxBuckets+2000; i++ {
		mcpRateDo(h, fmt.Sprintf("10.%d.%d.%d:5000", i>>16&0xff, i>>8&0xff, i&0xff))
	}
	if got := l.size(); got > mcpRateMaxBuckets {
		t.Fatalf("after %d distinct source IPs the limiter tracks %d buckets; the cap is %d — a distinct-IP flood grows memory without limit", mcpRateMaxBuckets+2000, got, mcpRateMaxBuckets)
	}
	if l.size() == 0 {
		t.Fatal("eviction emptied the map entirely; the limiter would stop limiting")
	}
}

// TestMCPRateLimiterEvictsIdleBucketsFirst proves the sweep prefers idle keys, so
// an active client is not evicted while dead ones sit in the map.
func TestMCPRateLimiterEvictsIdleBucketsFirst(t *testing.T) {
	l, clock, _ := newMCPRateTestLimiter(t, 1, 1)
	reached := 0
	h := l.middleware(mcpRateOKHandler(&reached))

	for i := 0; i < mcpRateMaxBuckets; i++ {
		mcpRateDo(h, fmt.Sprintf("10.%d.%d.%d:5000", i>>16&0xff, i>>8&0xff, i&0xff))
	}
	clock.add(mcpRateIdleTTL + time.Minute) // every one of them is now idle
	mcpRateDo(h, "203.0.113.7:5000")        // triggers the sweep on insert
	if got := l.size(); got != 1 {
		t.Fatalf("after the idle TTL elapsed the map holds %d buckets; want 1 (only the live key) — idle buckets are not being swept", got)
	}
}

// TestMCPHTTPServerArmsRateLimiter is the WIRING proof: the production
// constructor must put the bucket in front of the handler. This is the test the
// mutation ("delete the middleware") reds.
func TestMCPHTTPServerArmsRateLimiter(t *testing.T) {
	l, _, _ := newMCPRateTestLimiter(t, 1, 1)
	reached := 0
	srv := newMCPHTTPServer(mcpRateOKHandler(&reached), l)

	if rec := mcpRateDo(srv.Handler, "203.0.113.7:5000"); rec.Code != http.StatusOK {
		t.Fatalf("first request through the production server = %d; want 200", rec.Code)
	}
	rec := mcpRateDo(srv.Handler, "203.0.113.7:5000")
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("second request through newMCPHTTPServer = %d; want 429 — the /mcp http.Server does NOT wrap its handler in the per-IP token bucket (missing rate limit middleware)", rec.Code)
	}
	if rec.Header().Get("Retry-After") == "" {
		t.Fatal("the server's 429 carried no Retry-After (missing rate limit middleware)")
	}
	if reached != 1 {
		t.Fatalf("the MCP handler was reached %d times; want 1 — the refused request was not stopped (missing rate limit middleware)", reached)
	}

	// A nil limiter is a pass-through, which is what BARKPARK_MCP_RATE=0 gives.
	plain := newMCPHTTPServer(mcpRateOKHandler(&reached), nil)
	for i := 0; i < 5; i++ {
		if rec := mcpRateDo(plain.Handler, "203.0.113.7:5000"); rec.Code != http.StatusOK {
			t.Fatalf("with the limiter disabled request %d = %d; want 200", i+1, rec.Code)
		}
	}
}

// TestMCPRateLimiterDoesNotKillAnEstablishedStream pins the SSE invariant: the
// decision is taken once, before the handler runs. A stream already in flight
// keeps streaming even though the same IP's bucket empties meanwhile — the same
// reason WriteTimeout is left at zero on this server.
func TestMCPRateLimiterDoesNotKillAnEstablishedStream(t *testing.T) {
	l, _, _ := newMCPRateTestLimiter(t, 1, 1)

	streaming := make(chan struct{})
	release := make(chan struct{})
	// Only the FIRST request streams-and-holds. Later ones return at once — so
	// that if the middleware were ever removed this test FAILS on the assertion
	// below instead of deadlocking on the hold.
	var served atomic.Int32
	sse := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		if served.Add(1) != 1 {
			w.WriteHeader(http.StatusOK)
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, "data: first\n\n")
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
		close(streaming)
		// Hold the stream open while the bucket is hammered empty — but never
		// past a bounded wait: a test that fails its assertion must fail loudly,
		// not wedge httptest's Close on a hung handler.
		select {
		case <-release:
		case <-time.After(15 * time.Second):
		}
		fmt.Fprint(w, "data: last\n\n")
	})
	srv := newMCPHTTPServer(sse, l)
	ts := httptest.NewServer(srv.Handler)
	defer ts.Close()

	type result struct {
		body string
		err  error
	}
	done := make(chan result, 1)
	go func() {
		resp, err := http.Get(ts.URL + "/mcp")
		if err != nil {
			done <- result{err: err}
			return
		}
		defer resp.Body.Close()
		b := make([]byte, 0, 64)
		buf := make([]byte, 32)
		for {
			n, err := resp.Body.Read(buf)
			b = append(b, buf[:n]...)
			if err != nil {
				break
			}
		}
		done <- result{body: string(b)}
	}()

	<-streaming
	// Hammer the same key while the stream is mid-flight: these are refused...
	for i := 0; i < 3; i++ {
		if rec := mcpRateDo(srv.Handler, "127.0.0.1:4010"); rec.Code != http.StatusTooManyRequests {
			t.Fatalf("hammer request %d = %d; want 429 (the bucket should be empty)", i+1, rec.Code)
		}
	}
	// ...and the established stream still completes.
	close(release)

	select {
	case r := <-done:
		if r.err != nil {
			t.Fatalf("the in-flight SSE stream failed while the limiter refused siblings: %v", r.err)
		}
		if !strings.Contains(r.body, "data: first") || !strings.Contains(r.body, "data: last") {
			t.Fatalf("the in-flight SSE stream was truncated by the limiter: got %q, want both events", r.body)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("the in-flight SSE stream never completed")
	}
}

// TestMCPRateLimiterFromEnv pins the documented defaults and the escape hatch.
func TestMCPRateLimiterFromEnv(t *testing.T) {
	t.Run("defaults", func(t *testing.T) {
		l := newMCPRateLimiterFromEnv(nil)
		if l == nil {
			t.Fatal("the limiter is OFF by default; --http must ship clamped")
		}
		if l.rate != mcpRateDefaultRate || l.burst != mcpRateDefaultBurst {
			t.Fatalf("defaults = %g/s burst %g; want %g/s burst %g", l.rate, l.burst, mcpRateDefaultRate, mcpRateDefaultBurst)
		}
		if !l.trustedPeer([]byte{127, 0, 0, 1}) {
			t.Fatal("loopback is not trusted by default; the deploy shape (Caddy → 127.0.0.1:4010) would key every client on the proxy")
		}
	})

	t.Run("overrides", func(t *testing.T) {
		t.Setenv(mcpRateEnvRate, "3")
		t.Setenv(mcpRateEnvBurst, "9")
		t.Setenv(mcpRateEnvTrustedProxies, "10.0.0.0/8")
		l := newMCPRateLimiterFromEnv(nil)
		if l == nil || l.rate != 3 || l.burst != 9 {
			t.Fatalf("env override not applied: %+v", l)
		}
		if l.trustedPeer([]byte{127, 0, 0, 1}) {
			t.Fatal("an explicit trusted-proxy list must REPLACE the loopback default, not extend it")
		}
	})

	t.Run("rate 0 disables", func(t *testing.T) {
		t.Setenv(mcpRateEnvRate, "0")
		if l := newMCPRateLimiterFromEnv(nil); l != nil {
			t.Fatal("BARKPARK_MCP_RATE=0 must disable the limiter (the documented escape hatch)")
		}
	})

	t.Run("a malformed value keeps the default instead of taking the endpoint down", func(t *testing.T) {
		var logs []string
		t.Setenv(mcpRateEnvRate, "not-a-number")
		l := newMCPRateLimiterFromEnv(func(f string, a ...any) { logs = append(logs, fmt.Sprintf(f, a...)) })
		if l == nil || l.rate != mcpRateDefaultRate {
			t.Fatalf("a malformed BARKPARK_MCP_RATE did not fall back to the default: %+v", l)
		}
		if len(logs) == 0 {
			t.Fatal("a malformed value was swallowed silently; the typo must be findable in the log")
		}
	})
}
