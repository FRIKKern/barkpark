package apiclient

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// A stream of two events plus a keep-alive comment. onEvent stops the stream by
// cancelling ctx after the second event (the handler holds the connection open
// until then, so no reconnect fires). Both data frames dispatch in order; the
// comment frame is ignored; ctx cancel exits nil.
func TestListenParsesSSEFrames(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		fl, _ := w.(http.Flusher)
		_, _ = w.Write([]byte("event: mutation\ndata: {\"id\":\"p1\"}\n\n"))
		_, _ = w.Write([]byte(": keep-alive\n\n")) // comment frame — must be ignored
		_, _ = w.Write([]byte("event: mutation\ndata: {\"id\":\"p2\"}\n\n"))
		if fl != nil {
			fl.Flush()
		}
		<-r.Context().Done() // hold open until the client (ctx cancel) hangs up
	}))
	defer srv.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	c := New(Config{BaseURL: srv.URL, Dataset: "production"})

	var events []string
	err := c.Listen(ctx, "post", func(event, data string) error {
		events = append(events, event+"|"+data)
		if len(events) == 2 {
			cancel()
		}
		return nil
	}, nil)
	if err != nil {
		t.Fatalf("expected nil on ctx cancel, got: %v", err)
	}

	want := []string{`mutation|{"id":"p1"}`, `mutation|{"id":"p2"}`}
	if len(events) != len(want) {
		t.Fatalf("got %d events, want %d: %v", len(events), len(want), events)
	}
	for i := range want {
		if events[i] != want[i] {
			t.Errorf("event[%d] = %q, want %q", i, events[i], want[i])
		}
	}
}

// PROTECTIVE: the first connection serves one framed event carrying `id: 7` then
// closes (an unexpected drop). Listen must (a) reconnect and carry the resume
// header `Last-Event-ID: 7` on the SECOND request, and (b) deliver the second
// connection's event exactly once. Before the reconnect loop existed, the drop
// returned an error and no second request was ever made.
func TestListenReconnectsWithLastEventID(t *testing.T) {
	var (
		mu           sync.Mutex
		reqs         int
		secondResume string
	)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		reqs++
		n := reqs
		if n == 2 {
			secondResume = r.Header.Get("Last-Event-ID")
		}
		mu.Unlock()

		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		fl, _ := w.(http.Flusher)
		if n == 1 {
			// First connection: one framed event with id 7, then drop.
			_, _ = w.Write([]byte("id: 7\nevent: mutation\ndata: {\"id\":\"p1\"}\n\n"))
			if fl != nil {
				fl.Flush()
			}
			return
		}
		// Second connection: serve one event, then hold open until ctx cancel.
		_, _ = w.Write([]byte("id: 8\nevent: mutation\ndata: {\"id\":\"p2\"}\n\n"))
		if fl != nil {
			fl.Flush()
		}
		<-r.Context().Done()
	}))
	defer srv.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	c := New(Config{BaseURL: srv.URL, Dataset: "production"})

	var events []string
	done := make(chan error, 1)
	go func() {
		done <- c.Listen(ctx, "", func(_, data string) error {
			events = append(events, data)
			if data == `{"id":"p2"}` {
				cancel() // stop once the post-reconnect event arrives
			}
			return nil
		}, nil)
	}()

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("expected nil after ctx cancel, got: %v", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("Listen did not return within 10s — reconnect loop stuck?")
	}

	mu.Lock()
	defer mu.Unlock()
	if secondResume != "7" {
		t.Errorf("second request Last-Event-ID = %q, want %q", secondResume, "7")
	}
	want := []string{`{"id":"p1"}`, `{"id":"p2"}`}
	if len(events) != len(want) {
		t.Fatalf("got events %v, want %v", events, want)
	}
	for i := range want {
		if events[i] != want[i] {
			t.Errorf("event[%d] = %q, want %q (delivered more than once?)", i, events[i], want[i])
		}
	}
}

// PROTECTIVE: once connected, a 5xx answered mid-reconnect is a transient blip
// (a control-plane deploy/restart), NOT a fatal error. The first connection
// serves an id-stamped event then drops; the next two reconnects answer 503;
// the fourth serves a second event. Listen must ride through the 503s, fire
// onReconnect, carry Last-Event-ID on the final reconnect, and deliver BOTH
// events. Before the 5xx-backoff path, the first 503 returned humanAPIError and
// the second event was lost.
func TestListenRidesThroughTransient5xx(t *testing.T) {
	var (
		mu         sync.Mutex
		reqs       int
		lastResume string
	)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		reqs++
		n := reqs
		lastResume = r.Header.Get("Last-Event-ID")
		mu.Unlock()

		switch n {
		case 1:
			// Healthy stream: one framed event with id 7, then drop.
			w.Header().Set("Content-Type", "text/event-stream")
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte("id: 7\nevent: mutation\ndata: {\"id\":\"p1\"}\n\n"))
			if fl, ok := w.(http.Flusher); ok {
				fl.Flush()
			}
		case 2, 3:
			// Control-plane blip: a 503 mid-reconnect must not be fatal.
			w.WriteHeader(http.StatusServiceUnavailable)
			_, _ = w.Write([]byte(`{"error":{"code":"unavailable","message":"restarting"}}`))
		default:
			// Recovered: serve the post-gap event, then hold open until ctx cancel.
			w.Header().Set("Content-Type", "text/event-stream")
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte("id: 8\nevent: mutation\ndata: {\"id\":\"p2\"}\n\n"))
			if fl, ok := w.(http.Flusher); ok {
				fl.Flush()
			}
			<-r.Context().Done()
		}
	}))
	defer srv.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	c := New(Config{BaseURL: srv.URL, Dataset: "production"})
	c.listenBackoffFloor = time.Millisecond // keep the capped retries sub-second

	var reconnects int32
	var events []string
	done := make(chan error, 1)
	go func() {
		done <- c.Listen(ctx, "", func(_, data string) error {
			events = append(events, data)
			if data == `{"id":"p2"}` {
				cancel()
			}
			return nil
		}, func() { atomic.AddInt32(&reconnects, 1) })
	}()

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("expected nil after riding through 503s, got: %v", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("Listen did not return within 10s — 5xx retry loop stuck?")
	}

	if atomic.LoadInt32(&reconnects) == 0 {
		t.Error("onReconnect never fired across the 503 gap")
	}
	mu.Lock()
	defer mu.Unlock()
	if lastResume != "7" {
		t.Errorf("final reconnect Last-Event-ID = %q, want %q", lastResume, "7")
	}
	want := []string{`{"id":"p1"}`, `{"id":"p2"}`}
	if len(events) != len(want) {
		t.Fatalf("got events %v, want %v", events, want)
	}
	for i := range want {
		if events[i] != want[i] {
			t.Errorf("event[%d] = %q, want %q", i, events[i], want[i])
		}
	}
}

// PROTECTIVE: a server that answers 503 forever after a healthy connect must not
// retry unboundedly — past the small cap Listen surfaces the real error and
// returns. The test must not hang: a tiny backoff floor keeps the capped retries
// sub-second, and a deadline guards against a runaway loop.
func TestListen5xxCapSurfacesError(t *testing.T) {
	var served int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		if atomic.AddInt32(&served, 1) == 1 {
			// One healthy stream, then drop, so `connected` is true.
			w.Header().Set("Content-Type", "text/event-stream")
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte("id: 1\nevent: mutation\ndata: {\"id\":\"p1\"}\n\n"))
			if fl, ok := w.(http.Flusher); ok {
				fl.Flush()
			}
			return
		}
		w.WriteHeader(http.StatusServiceUnavailable)
		_, _ = w.Write([]byte(`{"error":{"code":"unavailable","message":"still down"}}`))
	}))
	defer srv.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	c := New(Config{BaseURL: srv.URL, Dataset: "production"})
	c.listenBackoffFloor = time.Millisecond

	done := make(chan error, 1)
	go func() {
		done <- c.Listen(ctx, "", func(string, string) error { return nil }, nil)
	}()

	select {
	case err := <-done:
		if err == nil {
			t.Fatal("expected a non-nil error once the 5xx cap is exhausted, got nil")
		}
		if !strings.Contains(err.Error(), "still down") {
			t.Errorf("error = %q, want the server's persistent message", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("Listen never returned — 5xx retries are not bounded by the cap")
	}
}

// PROTECTIVE: a 5xx on the FIRST connect is NOT transient — it fails fast with
// exactly one request made (the retry path is gated on `connected`, so bad
// startup state does not spin).
func TestListen5xxOnInitialConnectFailsFast(t *testing.T) {
	var reqs int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		atomic.AddInt32(&reqs, 1)
		w.WriteHeader(http.StatusServiceUnavailable)
		_, _ = w.Write([]byte(`{"error":{"code":"unavailable","message":"cold start"}}`))
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Dataset: "production"})
	c.listenBackoffFloor = time.Millisecond
	err := c.Listen(context.Background(), "", func(string, string) error { return nil }, nil)
	if err == nil {
		t.Fatal("expected an error on an initial 503, got nil")
	}
	if n := atomic.LoadInt32(&reqs); n != 1 {
		t.Errorf("made %d requests on an initial 503, want exactly 1 (no retry)", n)
	}
}

// PROTECTIVE: a 4xx AFTER a healthy connect (e.g. a token revoked mid-life) is a
// real error, not a transient drop — it must be immediately fatal and NOT enter
// the 5xx retry path.
func TestListen4xxAfterConnectIsFatal(t *testing.T) {
	var served int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		if atomic.AddInt32(&served, 1) == 1 {
			w.Header().Set("Content-Type", "text/event-stream")
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte("id: 1\nevent: mutation\ndata: {\"id\":\"p1\"}\n\n"))
			if fl, ok := w.(http.Flusher); ok {
				fl.Flush()
			}
			return
		}
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"error":{"code":"unauthorized","message":"token revoked"}}`))
	}))
	defer srv.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	c := New(Config{BaseURL: srv.URL, Dataset: "production"})
	c.listenBackoffFloor = time.Millisecond

	done := make(chan error, 1)
	go func() {
		done <- c.Listen(ctx, "", func(string, string) error { return nil }, nil)
	}()

	select {
	case err := <-done:
		if err == nil {
			t.Fatal("expected a fatal error on a mid-life 401, got nil")
		}
		if !strings.Contains(err.Error(), "token revoked") {
			t.Errorf("error = %q, want the server's 401 message", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("Listen did not return — a mid-life 401 must be immediately fatal")
	}
	if n := atomic.LoadInt32(&served); n != 2 {
		t.Errorf("served %d requests, want 2 (one healthy + the fatal 401)", n)
	}
}

// Ctrl-C (a cancelled ctx) is an intentional stop, so Listen exits cleanly with
// nil even though the stream did not end on its own — and it does NOT reconnect.
func TestListenNilOnContextCancel(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("event: mutation\ndata: {\"id\":\"p1\"}\n\n"))
		if fl, ok := w.(http.Flusher); ok {
			fl.Flush()
		}
	}))
	defer srv.Close()

	ctx, cancel := context.WithCancel(context.Background())
	c := New(Config{BaseURL: srv.URL, Dataset: "production"})

	err := c.Listen(ctx, "", func(string, string) error {
		cancel() // simulate Ctrl-C once the first event lands
		return nil
	}, nil)
	if err != nil {
		t.Fatalf("expected nil on context cancel, got: %v", err)
	}
}

// A non-200 on the FIRST connect surfaces as an error rather than a silent empty
// stream or an infinite retry (bad creds must fail fast). The server's error
// envelope must survive into the message, and the message must NOT carry a
// "listen: " prefix — listen_cmd adds exactly one, so a double prefix here would
// stutter "listen: listen: …".
func TestListenErrorsOnNon200(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusForbidden)
		_, _ = w.Write([]byte(`{"error":{"code":"forbidden","message":"no read access"}}`))
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Dataset: "production"})
	err := c.Listen(context.Background(), "", func(string, string) error { return nil }, nil)
	if err == nil {
		t.Fatal("expected an error on HTTP 403, got nil")
	}
	if !strings.Contains(err.Error(), "no read access") {
		t.Errorf("error = %q, want the server's message %q", err, "no read access")
	}
	if strings.Contains(err.Error(), "listen:") {
		t.Errorf("error = %q, want no \"listen:\" wrap (listen_cmd prefixes)", err)
	}
}
