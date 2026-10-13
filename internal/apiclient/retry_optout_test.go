// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Barkpark contributors

package apiclient

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

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
