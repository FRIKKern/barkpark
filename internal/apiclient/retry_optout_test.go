// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

package apiclient

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestParseRetryAfterBothForms(t *testing.T) {
	now := time.Date(2026, 10, 13, 12, 0, 0, 0, time.UTC)
	cases := []struct {
		in     string
		want   float64
		wantOK bool
	}{
		{"3", 3, true},
		{" 1.5 ", 1.5, true},
		{now.Add(4 * time.Second).Format(http.TimeFormat), 4, true},
		{now.Add(-time.Minute).Format(http.TimeFormat), 0, true},
		{"", 0, false},
		{"soon", 0, false},
	}
	for _, c := range cases {
		got, ok := parseRetryAfterAt(c.in, now)
		if ok != c.wantOK || got != c.want {
			t.Errorf("parseRetryAfterAt(%q) = %v, %v; want %v, %v", c.in, got, ok, c.want, c.wantOK)
		}
	}
}

// A 429 whose Retry-After is an HTTP-date (the form a proxy in front of an
// instance may send) is waited out for the time the date names, not for our
// one-second default.
func TestBackpressureHonoursRetryAfterHTTPDate(t *testing.T) {
	when := time.Now().Add(3 * time.Second).UTC().Format(http.TimeFormat)
	srv := &headerScriptedServer{
		scriptedServer: scriptedServer{script: []scriptedResponse{
			{http.StatusTooManyRequests, strangerRateLimitedBody},
			{http.StatusOK, `{"result":{}}`},
		}},
		headers: []map[string]string{{"Retry-After": when}},
	}
	ts := httptest.NewServer(srv)
	defer ts.Close()

	rt, notices, _ := backpressureTestTransport(nil)
	resp, _ := doGet(t, rt, ts.URL)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200 after one wait", resp.StatusCode)
	}
	if len(*notices) != 1 {
		t.Fatalf("notices = %d, want 1", len(*notices))
	}
	n := (*notices)[0]
	if !n.ServerAsked {
		t.Fatal("ServerAsked = false: the HTTP-date Retry-After was read as no header")
	}
	// The date has one-second resolution and a little time passes before the
	// response is classified, so the wait lands between 1s and 3s.
	if n.Delay < time.Second || n.Delay > 3*time.Second {
		t.Fatalf("waited %s, want the 1s..3s the date names", n.Delay)
	}
}

// A Retry-After above maxRetryAfter is not slept out, in either form: the 429
// goes back to the caller after one attempt.
func TestBackpressureCapsAnHTTPDateRetryAfter(t *testing.T) {
	when := time.Now().Add(time.Hour).UTC().Format(http.TimeFormat)
	srv := &headerScriptedServer{
		scriptedServer: scriptedServer{script: []scriptedResponse{
			{http.StatusTooManyRequests, strangerRateLimitedBody},
			{http.StatusOK, `{"result":{}}`},
		}},
		headers: []map[string]string{{"Retry-After": when}},
	}
	ts := httptest.NewServer(srv)
	defer ts.Close()

	rt, notices, _ := backpressureTestTransport(nil)
	resp, _ := doGet(t, rt, ts.URL)
	if resp.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("status = %d, want the 429 handed back unslept", resp.StatusCode)
	}
	if got := srv.hits.Load(); got != 1 {
		t.Fatalf("server hits = %d, want 1", got)
	}
	if len(*notices) != 0 {
		t.Fatalf("notices = %d, want 0: nothing was waited", len(*notices))
	}
}

// --no-retry / BARKPARK_NO_RETRY: a 429 and a transient 500 each come back on
// the first attempt.
func TestRetryDisabledSendsOnce(t *testing.T) {
	for _, tc := range []struct {
		name string
		set  func(t *testing.T)
	}{
		{"flag", func(t *testing.T) { SetNoRetry(true); t.Cleanup(func() { SetNoRetry(false) }) }},
		{"env", func(t *testing.T) { t.Setenv(noRetryEnv, "1") }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tc.set(t)
			if !RetryDisabled() {
				t.Fatal("RetryDisabled() = false after opting out")
			}
			for _, first := range []scriptedResponse{
				{http.StatusTooManyRequests, liveRateLimitedBody},
				{http.StatusInternalServerError, liveInternalErrorBody},
			} {
				srv := &scriptedServer{script: []scriptedResponse{first, {http.StatusOK, `{"result":{}}`}}}
				ts := httptest.NewServer(srv)
				rt, notices, _ := backpressureTestTransport(nil)
				resp, _ := doGet(t, rt, ts.URL)
				ts.Close()
				if resp.StatusCode != first.status {
					t.Fatalf("status = %d, want %d handed back unretried", resp.StatusCode, first.status)
				}
				if got := srv.hits.Load(); got != 1 {
					t.Fatalf("server hits = %d, want 1", got)
				}
				if len(*notices) != 0 || rt.count.Load() != 0 {
					t.Fatalf("a retry was announced or counted with retries off")
				}
			}
		})
	}
}

func TestRetryDisabledEnvValues(t *testing.T) {
	for v, want := range map[string]bool{"": false, "0": false, "false": false, "no": false, "1": true, "true": true, "yes": true} {
		t.Setenv(noRetryEnv, v)
		if got := RetryDisabled(); got != want {
			t.Errorf("BARKPARK_NO_RETRY=%q: RetryDisabled() = %v, want %v", v, got, want)
		}
	}
}
