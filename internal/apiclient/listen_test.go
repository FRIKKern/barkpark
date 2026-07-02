package apiclient

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
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
