package apiclient

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

// task-e4cbf4cd9f672c33: the close door carries X-Barkpark-Session (secret
// claim-session key) and, when bound, X-Barkpark-Session-Doc; no other task
// write gains either header.

func recordTaskPosts(t *testing.T) (*httptest.Server, *[]*http.Request) {
	t.Helper()
	var got []*http.Request
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = append(got, r.Clone(r.Context()))
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ok":true,"doc":{"claim":{"epoch":1}}}`))
	}))
	t.Cleanup(srv.Close)
	return srv, &got
}

func TestTaskCloseSendsBothSessionHeadersWhenBound(t *testing.T) {
	srv, got := recordTaskPosts(t)
	c := New(Config{BaseURL: srv.URL, Token: "t", SessionKey: "secret-key", SessionDoc: "session-2026-09-24-x"})
	if _, _, err := c.TaskCloseN("task-a", "w", 1); err != nil {
		t.Fatal(err)
	}
	if _, _, err := c.TaskCloseRevN("task-a", "w", 1, "rev"); err != nil {
		t.Fatal(err)
	}
	for i, r := range *got {
		if v := r.Header.Get("X-Barkpark-Session"); v != "secret-key" {
			t.Errorf("close[%d]: X-Barkpark-Session = %q, want the key verbatim", i, v)
		}
		if v := r.Header.Get("X-Barkpark-Session-Doc"); v != "session-2026-09-24-x" {
			t.Errorf("close[%d]: X-Barkpark-Session-Doc = %q", i, v)
		}
		if v := r.Header.Get("Authorization"); v != "Bearer t" {
			t.Errorf("close[%d]: Authorization = %q — session headers must not displace auth", i, v)
		}
	}
	if len(*got) != 2 {
		t.Fatalf("recorded %d requests, want 2", len(*got))
	}
}

func TestTaskCloseOmitsSessionDocWhenUnbound(t *testing.T) {
	srv, got := recordTaskPosts(t)
	c := New(Config{BaseURL: srv.URL, SessionKey: "secret-key"})
	if _, _, err := c.TaskCloseN("task-a", "w", 1); err != nil {
		t.Fatal(err)
	}
	r := (*got)[0]
	if v := r.Header.Get("X-Barkpark-Session"); v != "secret-key" {
		t.Errorf("X-Barkpark-Session = %q, want the key", v)
	}
	if v, ok := r.Header["X-Barkpark-Session-Doc"]; ok {
		t.Errorf("X-Barkpark-Session-Doc = %q with no session bound; want it absent", v)
	}
}

func TestTaskCloseSessionlessSendsNeither(t *testing.T) {
	srv, got := recordTaskPosts(t)
	c := New(Config{BaseURL: srv.URL, SessionKey: "  ", SessionDoc: ""})
	if _, _, err := c.TaskCloseN("task-a", "w", 1); err != nil {
		t.Fatal(err)
	}
	for _, h := range []string{"X-Barkpark-Session", "X-Barkpark-Session-Doc"} {
		if v, ok := (*got)[0].Header[h]; ok {
			t.Errorf("%s = %q on a sessionless client; want it absent", h, v)
		}
	}
}

// Scope control: only the close door carries the pair. A claim and a pulse on
// the same bound client stay byte-identical to before.
func TestSessionHeadersRideOnlyTheCloseDoor(t *testing.T) {
	srv, got := recordTaskPosts(t)
	c := New(Config{BaseURL: srv.URL, SessionKey: "secret-key", SessionDoc: "session-x"})
	_, _, _, _ = c.TaskClaimN("task-a", "w")
	_, _, _ = c.TaskPulse("task-a", "w", "now")
	if len(*got) == 0 {
		t.Fatal("no requests recorded — the control measured nothing")
	}
	for _, r := range *got {
		for _, h := range []string{"X-Barkpark-Session", "X-Barkpark-Session-Doc"} {
			if v, ok := r.Header[h]; ok {
				t.Errorf("%s %s: %s = %q; only /close carries it", r.Method, r.URL.Path, h, v)
			}
		}
	}
}
