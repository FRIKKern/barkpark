package apiclient

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// A body larger than maxManifestBytes must fail loud (not hang/OOM), and must
// not surface a partial body to the caller.
func TestGetConditional_RejectsOversizedBody(t *testing.T) {
	huge := strings.Repeat("a", maxManifestBytes+1024)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(huge))
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Token: "t"})
	res, err := c.GetConditional(srv.URL, "")
	if err == nil {
		t.Fatalf("expected an error for an oversized manifest body, got nil (res=%v)", res)
	}
	if !strings.Contains(err.Error(), "exceeds") {
		t.Fatalf("expected an over-limit error, got: %v", err)
	}
	if res != nil {
		t.Fatalf("expected nil result on over-limit body, got %v", res)
	}
}

// A normal small 200 body round-trips unchanged.
func TestGetConditional_SmallBodyRoundTrips(t *testing.T) {
	const payload = `{"ok":true}`
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("ETag", `"v1"`)
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(payload))
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Token: "t"})
	res, err := c.GetConditional(srv.URL, "")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", res.StatusCode)
	}
	if string(res.Body) != payload {
		t.Fatalf("body mismatch: got %q want %q", res.Body, payload)
	}
	if res.ETag != `"v1"` {
		t.Fatalf("etag mismatch: got %q", res.ETag)
	}
}

// A body exactly at the limit is accepted (boundary: len == maxManifestBytes).
func TestGetConditional_ExactLimitAccepted(t *testing.T) {
	exact := strings.Repeat("a", maxManifestBytes)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(exact))
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Token: "t"})
	res, err := c.GetConditional(srv.URL, "")
	if err != nil {
		t.Fatalf("unexpected error at exact limit: %v", err)
	}
	if len(res.Body) != maxManifestBytes {
		t.Fatalf("body length mismatch: got %d want %d", len(res.Body), maxManifestBytes)
	}
}

// GetConditionalBounded honors the caller's cap, not maxManifestBytes: a body
// past the manifest cap round-trips when the caller's bound is larger — while
// GetConditional keeps refusing it, so the manifest's 8 MiB contract is
// unchanged. This is the taskboard incident regression — /v1/tasks crossed
// 8 MiB and the board went dark because its fetch borrowed the manifest cap.
func TestGetConditionalBounded_CallerCapBeatsManifestCap(t *testing.T) {
	big := strings.Repeat("a", maxManifestBytes+1024)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(big))
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Token: "t"})
	if _, err := c.GetConditional(srv.URL, ""); err == nil {
		t.Fatal("manifest reader accepted a body above its established 8 MiB limit")
	}
	res, err := c.GetConditionalBounded(srv.URL, "", int64(maxManifestBytes)+2048)
	if err != nil {
		t.Fatalf("body over the manifest cap but under the caller cap must pass, got: %v", err)
	}
	if len(res.Body) != len(big) {
		t.Fatalf("body length mismatch: got %d want %d", len(res.Body), len(big))
	}
}

// GetConditionalBounded refuses a body over the caller's cap, and the error
// names the bound generically — never "capabilities manifest" for a caller
// that isn't fetching one. A non-positive cap is a caller bug and is refused
// outright.
func TestGetConditionalBounded_RefusesOverCallerCap(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(strings.Repeat("a", 4096)))
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Token: "t"})
	res, err := c.GetConditionalBounded(srv.URL, "", 2048)
	if err == nil {
		t.Fatalf("expected an error for a body over the caller cap, got nil (res=%v)", res)
	}
	if !strings.Contains(err.Error(), "exceeds 2048 bytes") {
		t.Fatalf("expected the caller's bound in the error, got: %v", err)
	}
	if strings.Contains(err.Error(), "manifest") {
		t.Fatalf("bounded error must not claim to be a manifest fetch, got: %v", err)
	}
	if _, err := c.GetConditionalBounded(srv.URL, "", 0); err == nil || !strings.Contains(err.Error(), "must be positive") {
		t.Fatalf("zero limit error = %v, want positive-limit rejection", err)
	}
}

// The 304 path never reads a body and is unaffected by the cap.
func TestGetConditional_NotModifiedNoBody(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("If-None-Match") != `"etag"` {
			t.Errorf("expected If-None-Match header, got %q", r.Header.Get("If-None-Match"))
		}
		w.WriteHeader(http.StatusNotModified)
	}))
	defer srv.Close()

	c := New(Config{BaseURL: srv.URL, Token: "t"})
	res, err := c.GetConditional(srv.URL, `"etag"`)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if res.StatusCode != http.StatusNotModified {
		t.Fatalf("expected 304, got %d", res.StatusCode)
	}
	if res.Body != nil {
		t.Fatalf("expected nil body on 304, got %q", res.Body)
	}
}
