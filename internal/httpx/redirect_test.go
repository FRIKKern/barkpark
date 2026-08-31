package httpx

import (
	"net/http"
	"net/url"
	"testing"
)

// newReq builds a GET request carrying the credential headers a redirect
// might leak, mirroring what bp actually sets on outgoing requests
// (Authorization is set directly on req.Header).
func newReq(t *testing.T, rawURL string) *http.Request {
	t.Helper()
	req, err := http.NewRequest(http.MethodGet, rawURL, nil)
	if err != nil {
		t.Fatalf("building request for %s: %v", rawURL, err)
	}
	req.Header.Set("Authorization", "Bearer secret-token")
	req.Header.Set("Cookie", "session=abc123")
	return req
}

func TestCheckRedirectStripsCredentialsOnSchemeOrPortChange(t *testing.T) {
	cases := []struct {
		name string
		from string
		to   string
	}{
		{"same host, different port", "https://api.bark.example:443/v1", "https://api.bark.example:8443/v1"},
		{"same host, https to http", "https://api.bark.example/v1", "http://api.bark.example/v1"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			via := newReq(t, tc.from)
			req := newReq(t, tc.to)

			if err := CheckRedirect(req, []*http.Request{via}); err != nil {
				t.Fatalf("CheckRedirect returned an error for a read redirect: %v", err)
			}
			if got := req.Header.Get("Authorization"); got != "" {
				t.Fatalf("Authorization survived a %s redirect: %q", tc.name, got)
			}
			if got := req.Header.Get("Cookie"); got != "" {
				t.Fatalf("Cookie survived a %s redirect: %q", tc.name, got)
			}
		})
	}
}

func TestCheckRedirectKeepsCredentialsOnSameSchemeAndPort(t *testing.T) {
	cases := []struct {
		name string
		from string
		to   string
	}{
		{"identical scheme and explicit port", "https://api.bark.example:443/v1", "https://api.bark.example:443/v2"},
		{"default https port vs explicit 443", "https://api.bark.example/v1", "https://api.bark.example:443/v2"},
		{"default http port vs explicit 80", "http://api.bark.example/v1", "http://api.bark.example:80/v2"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			via := newReq(t, tc.from)
			req := newReq(t, tc.to)

			if err := CheckRedirect(req, []*http.Request{via}); err != nil {
				t.Fatalf("CheckRedirect returned an error for a read redirect: %v", err)
			}
			if got := req.Header.Get("Authorization"); got != "Bearer secret-token" {
				t.Fatalf("Authorization was stripped on a same scheme+port redirect: got %q", got)
			}
			if got := req.Header.Get("Cookie"); got != "session=abc123" {
				t.Fatalf("Cookie was stripped on a same scheme+port redirect: got %q", got)
			}
		})
	}
}

// TestCheckRedirectRefusesWriteMessageUnchanged pins the existing write-refusal
// message and behavior — this task must not alter it.
func TestCheckRedirectRefusesWriteMessageUnchanged(t *testing.T) {
	via, err := http.NewRequest(http.MethodPost, "https://api.bark.example/v1/data/mutate/production", nil)
	if err != nil {
		t.Fatalf("building via request: %v", err)
	}
	req, err := http.NewRequest(http.MethodGet, "https://api.bark.example/login", nil)
	if err != nil {
		t.Fatalf("building request: %v", err)
	}

	err = CheckRedirect(req, []*http.Request{via})
	if err == nil {
		t.Fatalf("expected a refusal error for a write redirect, got nil")
	}
	want := "refusing to follow a redirect on a POST to https://api.bark.example/v1/data/mutate/production (→ https://api.bark.example/login): a redirect drops the request body and downgrades the write to a read — re-run against the final URL"
	if err.Error() != want {
		t.Fatalf("refusal message changed:\n got:  %s\n want: %s", err.Error(), want)
	}
}

// TestCheckRedirectHopCapUnchanged pins the existing MaxRedirects behavior.
func TestCheckRedirectHopCapUnchanged(t *testing.T) {
	via := make([]*http.Request, MaxRedirects)
	for i := range via {
		req, err := http.NewRequest(http.MethodGet, "https://api.bark.example/v1", nil)
		if err != nil {
			t.Fatalf("building via[%d]: %v", i, err)
		}
		via[i] = req
	}
	req, err := http.NewRequest(http.MethodGet, "https://api.bark.example/v1", nil)
	if err != nil {
		t.Fatalf("building request: %v", err)
	}

	err = CheckRedirect(req, via)
	if err == nil {
		t.Fatalf("expected a hop-cap error at %d redirects, got nil", MaxRedirects)
	}
	want := "stopped after 10 redirects"
	if err.Error() != want {
		t.Fatalf("hop-cap message changed:\n got:  %s\n want: %s", err.Error(), want)
	}
}

func TestEffectivePortNormalisesDefaults(t *testing.T) {
	cases := []struct {
		raw  string
		want string
	}{
		{"https://h", "443"},
		{"https://h:443", "443"},
		{"https://h:8443", "8443"},
		{"http://h", "80"},
		{"http://h:80", "80"},
		{"http://h:8080", "8080"},
	}
	for _, tc := range cases {
		u, err := url.Parse(tc.raw)
		if err != nil {
			t.Fatalf("parsing %s: %v", tc.raw, err)
		}
		if got := effectivePort(u); got != tc.want {
			t.Fatalf("effectivePort(%s) = %q, want %q", tc.raw, got, tc.want)
		}
	}
}
