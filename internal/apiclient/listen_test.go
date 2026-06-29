package apiclient

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

// A finite SSE stream of two events plus a keep-alive comment; the handler
// returns (closing the connection), so Listen sees EOF and returns nil.
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
	if err != nil {
		t.Fatalf("Listen returned error: %v", err)
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

// A non-200 status surfaces as an error rather than a silent empty stream.
func TestListenErrorsOnNon200(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusForbidden)
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Dataset: "production"})
	err := c.Listen(context.Background(), "", func(string, string) error { return nil })
	if err == nil {
		t.Fatal("expected an error on HTTP 403, got nil")
	}
}
