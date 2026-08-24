package apiclient

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// Same fixture shape as internal/cli's redirect_policy_test.go, aimed at the
// TYPED write path: a host that 302s every request to a text/html 200 login
// page. Under Go's default policy Mutate's POST is rewritten into a bodyless
// GET, the login page answers 200, and the client reports the write as done.
func redirectingHost(t *testing.T) (string, *[]string) {
	t.Helper()
	seen := &[]string{}
	dest := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		*seen = append(*seen, r.Method)
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("<!doctype html><title>Sign in</title>"))
	}))
	t.Cleanup(dest.Close)
	src := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, dest.URL+"/login", http.StatusFound)
	}))
	t.Cleanup(src.Close)
	return src.URL, seen
}

func TestClientRefusesRedirectOnTypedWrite(t *testing.T) {
	base, seen := redirectingHost(t)
	c := New(Config{BaseURL: base, Token: "t", Dataset: "production"})

	err := c.Mutate([]map[string]interface{}{
		{"create": map[string]interface{}{"_type": "post", "title": "x"}},
	})
	if err == nil {
		t.Fatalf("Mutate through a 302 reported success — the write silently became a read")
	}
	if !strings.Contains(err.Error(), "refusing to follow") {
		t.Fatalf("error does not name the refusal: %v", err)
	}
	if len(*seen) != 0 {
		t.Fatalf("redirect destination was contacted %v — a refused write must not reach it", *seen)
	}
}

// A typed READ still follows, so this narrows writes only.
func TestClientStillFollowsRedirectOnTypedRead(t *testing.T) {
	base, seen := redirectingHost(t)
	c := New(Config{BaseURL: base, Token: "t", Dataset: "production"})

	// The body is HTML, so the call fails to DECODE — but it must fail after
	// following the hop, not by refusing it. The destination seeing a GET is the
	// assertion; the decode error is expected.
	_ = c.Query("post", "")
	if len(*seen) != 1 || (*seen)[0] != "GET" {
		t.Fatalf("destination saw %v, want exactly one GET — a read must still follow", *seen)
	}
}
