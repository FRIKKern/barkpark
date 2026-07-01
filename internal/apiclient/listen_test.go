package apiclient

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// A finite SSE stream of two events plus a keep-alive comment; the handler
// returns (closing the connection). Both frames dispatch, and because a
// server-side EOF is an unexpected drop, Listen returns a non-nil error.
func TestListenParsesSSEFrames(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		fl, _ := w.(http.Flusher)
		_, _ = w.Write([]byte("event: mutation\ndata: {\"id\":\"p1\"}\n\n"))
		_, _ = w.Write([]byte(": keep-alive\n\n")) // comment frame — must be ignored
		_, _ = w.Write([]byte("event: mutation\ndata: {\"id\":\"p2\"}\n\n"))
		if fl != nil {
			fl.Flush()
		}
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Dataset: "production"})

	var events []string
	err := c.Listen(context.Background(), "post", func(event, data string) error {
		events = append(events, event+"|"+data)
		return nil
	})
	if err == nil {
		t.Fatal("expected a non-nil error on server-side EOF, got nil")
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

// A server that writes one valid frame then closes the body is an unexpected
// drop: the onEvent callback fires once, then Listen returns a non-nil error so
// a piping script sees a non-zero exit rather than assuming a clean finish.
func TestListenErrorsOnServerEOF(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("event: mutation\ndata: {\"id\":\"p1\"}\n\n"))
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Dataset: "production"})

	var calls int
	err := c.Listen(context.Background(), "", func(string, string) error {
		calls++
		return nil
	})
	if calls != 1 {
		t.Fatalf("onEvent fired %d times, want 1", calls)
	}
	if err == nil {
		t.Fatal("expected a non-nil error when the server drops the stream, got nil")
	}
}

// Ctrl-C (a cancelled ctx) is an intentional stop, so Listen exits cleanly with
// nil even though the stream did not end on its own.
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
	})
	if err != nil {
		t.Fatalf("expected nil on context cancel, got: %v", err)
	}
}

// A non-200 status surfaces as an error rather than a silent empty stream.
func TestListenErrorsOnNon200(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusForbidden)
		_, _ = w.Write([]byte(`{"error":{"code":"forbidden","message":"no read access"}}`))
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Dataset: "production"})
	err := c.Listen(context.Background(), "", func(string, string) error { return nil })
	if err == nil {
		t.Fatal("expected an error on HTTP 403, got nil")
	}
	// The server's error envelope must survive into the message, not be replaced
	// by a diagnostic-free "SSE status 403".
	if !strings.Contains(err.Error(), "no read access") {
		t.Errorf("error = %q, want the server's message %q", err, "no read access")
	}
}
