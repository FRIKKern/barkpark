package apiclient

import (
	"net/http"
	"net/http/httptest"
	"testing"
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

	if err := c.listenSSE(""); err != nil {
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

	if err := c.listenSSE(""); err != nil {
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

	if err := c.listenSSE(""); err != nil {
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
