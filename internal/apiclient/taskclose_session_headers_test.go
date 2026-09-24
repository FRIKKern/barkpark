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

// task-9af836a40731b63a: the claim and pulse doors carry the session KEY (the
// server stamps claim.session / session_origin and the event's session from
// it) but never the session DOC — the server auto-logs only close and publish.
// Every claim method is covered: TaskClaimN, and TaskClaimResources, which
// posts to the same /claim door (bp task next --frontier, bp cmux dispatch).
func TestClaimAndPulseSendSessionKeyNotDoc(t *testing.T) {
	srv, got := recordTaskPosts(t)
	c := New(Config{BaseURL: srv.URL, Token: "t", SessionKey: "secret-key", SessionDoc: "session-x"})
	if _, _, _, err := c.TaskClaimN("task-a", "w"); err != nil {
		t.Fatal(err)
	}
	if _, err := c.TaskClaimResources("task-a", "w", []string{"a.go"}); err != nil {
		t.Fatal(err)
	}
	if _, _, err := c.TaskPulse("task-a", "w", "now"); err != nil {
		t.Fatal(err)
	}
	if len(*got) != 3 {
		t.Fatalf("recorded %d requests, want 3 (claim, claim+resources, pulse)", len(*got))
	}
	for _, r := range *got {
		if v := r.Header.Get("X-Barkpark-Session"); v != "secret-key" {
			t.Errorf("%s %s: X-Barkpark-Session = %q, want the key verbatim", r.Method, r.URL.Path, v)
		}
		if v, ok := r.Header["X-Barkpark-Session-Doc"]; ok {
			t.Errorf("%s %s: X-Barkpark-Session-Doc = %q; only /close carries it", r.Method, r.URL.Path, v)
		}
		if v := r.Header.Get("Authorization"); v != "Bearer t" {
			t.Errorf("%s %s: Authorization = %q — the key must not displace auth", r.Method, r.URL.Path, v)
		}
	}
}

// A sessionless client's claim and pulse stay byte-identical to before: no
// session header of either kind.
func TestClaimAndPulseSessionlessSendNeither(t *testing.T) {
	srv, got := recordTaskPosts(t)
	c := New(Config{BaseURL: srv.URL, SessionKey: "  ", SessionDoc: "session-x"})
	_, _, _, _ = c.TaskClaimN("task-a", "w")
	_, _, _ = c.TaskPulse("task-a", "w", "now")
	if len(*got) != 2 {
		t.Fatalf("recorded %d requests, want 2", len(*got))
	}
	for _, r := range *got {
		for _, h := range []string{"X-Barkpark-Session", "X-Barkpark-Session-Doc"} {
			if v, ok := r.Header[h]; ok {
				t.Errorf("%s %s: %s = %q on a keyless client; want it absent", r.Method, r.URL.Path, h, v)
			}
		}
	}
}

// Scope control: a relabel is not a claim-lease write (the server's relabel
// action reads no session), so it stays header-free on a bound client.
func TestRelabelCarriesNoSessionHeader(t *testing.T) {
	srv, got := recordTaskPosts(t)
	c := New(Config{BaseURL: srv.URL, SessionKey: "secret-key", SessionDoc: "session-x"})
	if err := c.TaskRelabel("task-a", []string{"x"}, nil); err != nil {
		t.Fatal(err)
	}
	for _, h := range []string{"X-Barkpark-Session", "X-Barkpark-Session-Doc"} {
		if v, ok := (*got)[0].Header[h]; ok {
			t.Errorf("relabel: %s = %q; want it absent", h, v)
		}
	}
}
