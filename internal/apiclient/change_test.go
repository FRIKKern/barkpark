package apiclient

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// The internal change-detection listener must fire OnChange for a mutation
// frame even when the server omits the optional space after "event:". A proxy
// or future server emitting "event:mutation" is spec-valid, and missing it would
// silently drop the TUI's live refresh down to the slower NDJSON poll.
func TestListenSSENotifiesOnSpacelessMutation(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("event:mutation\ndata: {\"id\":\"p1\"}\n\n")) // no space after colon
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Dataset: "production"})

	var changes int
	c.OnChange = func() { changes++ }

	if err := c.listenSSE(context.Background(), ""); err != nil {
		t.Fatalf("listenSSE returned error: %v", err)
	}
	if changes != 1 {
		t.Fatalf("OnChange fired %d times, want 1", changes)
	}
}

// The conventional "event: mutation" (with the space) still fires OnChange —
// the tolerant parse must not regress the common form.
func TestListenSSENotifiesOnSpacedMutation(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("event: mutation\ndata: {\"id\":\"p1\"}\n\n"))
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Dataset: "production"})

	var changes int
	c.OnChange = func() { changes++ }

	if err := c.listenSSE(context.Background(), ""); err != nil {
		t.Fatalf("listenSSE returned error: %v", err)
	}
	if changes != 1 {
		t.Fatalf("OnChange fired %d times, want 1", changes)
	}
}

// A non-mutation event (e.g. a keep-alive "event: ping") must NOT fire OnChange,
// so the tolerant parse doesn't over-match on any "event:"-prefixed line.
func TestListenSSEIgnoresNonMutation(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("event:ping\ndata: {}\n\n"))
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Dataset: "production"})

	var changes int
	c.OnChange = func() { changes++ }

	if err := c.listenSSE(context.Background(), ""); err != nil {
		t.Fatalf("listenSSE returned error: %v", err)
	}
	if changes != 0 {
		t.Fatalf("OnChange fired %d times, want 0", changes)
	}
}

// pollOnce is the fallback the SSE loop runs whenever the stream drops — often
// because the server is mid-redeploy and answers 5xx. A non-200 body is NOT the
// document set; hashing it yields the empty-set hash. pollOnce must leave
// lastHash untouched on a non-200 (like the sibling reads Query/Get/History),
// so recovery does not fire a spurious refresh and a real change is not masked.
func TestPollOnceIgnoresNon200(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusServiceUnavailable)
		_, _ = w.Write([]byte(`{"error":{"code":"unavailable","message":"redeploying"}}`))
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Dataset: "production"})

	// Seed a known baseline; a 503 poll must not clobber it.
	c.lastHash = "sentinel-hash"

	var changes int
	c.OnChange = func() { changes++ }

	c.pollOnce()

	if c.lastHash != "sentinel-hash" {
		t.Fatalf("pollOnce clobbered lastHash on a 503 (now %q); a non-200 must be ignored", c.lastHash)
	}
	if changes != 0 {
		t.Fatalf("pollOnce fired OnChange %d times on a 503, want 0", changes)
	}
}

// A poll-fallback change (pollOnce over the NDJSON export) must fire
// OnChangeFallback, NOT OnChange, when a caller wires the fallback seam — that
// is what lets the task board tell a ◐ polling refresh from a ● live SSE frame,
// so a client stuck on the poll can never spoof the live-connection dot.
func TestPollOnceFiresFallbackWhenSet(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"_id":"p1","_rev":"r1"}` + "\n"))
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Dataset: "production"})

	var live, fallback int
	c.OnChange = func() { live++ }
	c.OnChangeFallback = func() { fallback++ }

	c.pollOnce()

	if fallback != 1 {
		t.Fatalf("OnChangeFallback fired %d times, want 1", fallback)
	}
	if live != 0 {
		t.Fatalf("OnChange fired %d times on a poll-fallback change, want 0 (must route to the fallback seam)", live)
	}
}

// Desk-TUI compatibility: a client that wires ONLY OnChange (no fallback seam)
// must still receive poll-detected changes on OnChange — the new seam is purely
// additive and must never regress the existing single-callback caller.
func TestPollOnceFallsThroughToOnChangeWhenFallbackUnset(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"_id":"p1","_rev":"r1"}` + "\n"))
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Dataset: "production"})

	var live int
	c.OnChange = func() { live++ }
	// OnChangeFallback deliberately left nil (the desk TUI's wiring).

	c.pollOnce()

	if live != 1 {
		t.Fatalf("with no fallback seam a poll change fired OnChange %d times, want 1 (desk compat)", live)
	}
}

// A live SSE mutation frame fires OnChange ONLY — never the fallback seam — so
// the two paths stay cleanly separated: SSE = ● live, poll = ◐ polling.
func TestListenSSEFiresOnChangeNotFallback(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("event: mutation\ndata: {\"id\":\"p1\"}\n\n"))
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Dataset: "production"})

	var live, fallback int
	c.OnChange = func() { live++ }
	c.OnChangeFallback = func() { fallback++ }

	if err := c.listenSSE(context.Background(), ""); err != nil {
		t.Fatalf("listenSSE returned error: %v", err)
	}
	if live != 1 {
		t.Fatalf("OnChange fired %d times on a live frame, want 1", live)
	}
	if fallback != 0 {
		t.Fatalf("OnChangeFallback fired %d times on a live SSE frame, want 0", fallback)
	}
}

// Every genuine stream frame — the welcome event on subscribe, the server's
// `: keepalive` comment (sent after 30s of quiet), and a mutation — must fire
// OnLivePulse, while ONLY the mutation fires OnChange. The pulse is what lets
// the task board hold an honest ● live over a QUIET dataset: without it a
// healthy idle stream would be indistinguishable from a dead one.
func TestListenSSEPulsesOnEveryStreamFrame(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("event: welcome\ndata: {\"type\":\"welcome\"}\n\n" +
			": keepalive\n\n" +
			"event: mutation\ndata: {\"id\":\"p1\"}\n\n"))
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Dataset: "production"})

	var pulses, live, fallback int
	c.OnLivePulse = func() { pulses++ }
	c.OnChange = func() { live++ }
	c.OnChangeFallback = func() { fallback++ }

	if err := c.listenSSE(context.Background(), ""); err != nil {
		t.Fatalf("listenSSE returned error: %v", err)
	}
	if pulses != 3 {
		t.Fatalf("OnLivePulse fired %d times, want 3 (welcome + keepalive + mutation)", pulses)
	}
	if live != 1 {
		t.Fatalf("OnChange fired %d times, want 1 (only the mutation frame)", live)
	}
	if fallback != 0 {
		t.Fatalf("OnChangeFallback fired %d times on stream frames, want 0", fallback)
	}
}

// The poll fallback must NEVER fire OnLivePulse — pollOnce succeeding proves
// the HTTP export endpoint works, not that the SSE stream is connected. If it
// pulsed, a client stuck on the poll could spoof ● live, defeating the whole
// seam split.
func TestPollOnceNeverPulses(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"_id":"p1","_rev":"r1"}` + "\n"))
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Dataset: "production"})

	var pulses, fallback int
	c.OnLivePulse = func() { pulses++ }
	c.OnChangeFallback = func() { fallback++ }

	c.pollOnce()

	if fallback != 1 {
		t.Fatalf("OnChangeFallback fired %d times, want 1 (the poll did detect a change)", fallback)
	}
	if pulses != 0 {
		t.Fatalf("OnLivePulse fired %d times from the poll fallback, want 0", pulses)
	}
}

// A stalled SSE connection (the server accepts and answers 200 but never
// writes another byte) used to block listenSSE's read forever: it dispatched
// via a plain http.NewRequest and &http.Client{Timeout: 0}, with no context to
// cancel the read. That leaked the goroutine spawned by StartSSE for the
// process lifetime (cmd/barkpark/main.go and internal/taskboard/live.go both
// fire it via `go ...StartSSE(...)` and never observed it again). This test
// fails (times out/hangs) on that pre-fix code; it passes once listenSSE
// dispatches via http.NewRequestWithContext and a cancelled ctx unblocks the
// stalled read, mirroring Listen in listen.go.
func TestListenSSERespectsContextCancellation(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		// Accept the connection, answer 200, then never write another byte and
		// never return — the stalled-stream shape the fix targets. Block until
		// the client disconnects (ctx cancellation) so the handler itself
		// doesn't leak past the test.
		<-r.Context().Done()
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Dataset: "production"})

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		done <- c.listenSSE(ctx, "")
	}()

	// Give the server a moment to accept the connection and answer 200 before
	// cancelling, so this exercises a cancel mid-stream, not a cancel-before-dial.
	time.Sleep(50 * time.Millisecond)
	cancel()

	select {
	case <-done:
		// listenSSE returned — ctx cancellation unblocked the stalled read.
	case <-time.After(2 * time.Second):
		t.Fatal("listenSSE did not return within 2s of context cancellation on a stalled stream")
	}
}
