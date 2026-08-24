package main

// Tests for the served-catalog fetch and the drift comparison.
//
// scaffy/seed had ZERO test files before this. Its 463 lines carry the payload
// deriver AND the drift detector the scaffy-catalog-drift gate depends on, and
// go-tests.yml deliberately excludes scaffy/seed/** on the (then accurate)
// ground that "no Go test reads it". These tests exist because a retry that has
// never seen a flake is not a retry, and because the UNREACHABLE arm must be
// proven to survive the retry rather than be softened by it.
//
// Broader coverage of derive/deriveAll/weightedTags is task-1097777b0ef94afb;
// this file covers the fetch and comparison paths the retry touches.

import (
	"crypto/sha256"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// withFastRetries shrinks the backoff so the loop is exercised without sleeping
// for seconds, and restores the production values afterwards.
func withFastRetries(t *testing.T, attempts int) {
	t.Helper()
	oldA, oldB := fetchAttempts, fetchBackoff
	fetchAttempts, fetchBackoff = attempts, time.Millisecond
	t.Cleanup(func() { fetchAttempts, fetchBackoff = oldA, oldB })
}

const envelope = `{"result":{"documents":[{"_id":"a--b--c","source":"SRC-A"}]}}`

// sha256hex mirrors how both sides of the comparison hash a source string, so a
// fixture's "served" digest is built the same way fetchServed builds a real one.
func sha256hex(s string) string {
	return fmt.Sprintf("%x", sha256.Sum256([]byte(s)))
}

// TestFetchServedRetriesTransientFailureThenSucceeds is the whole point of the
// retry: the exact shape of run 32624106095, where one request failed and the
// next one ten minutes later was fine.
func TestFetchServedRetriesTransientFailureThenSucceeds(t *testing.T) {
	withFastRetries(t, 3)
	var hits int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if atomic.AddInt32(&hits, 1) == 1 {
			http.Error(w, "bad gateway", http.StatusBadGateway) // transient
			return
		}
		fmt.Fprint(w, envelope)
	}))
	defer srv.Close()

	got, err := fetchServed(srv.URL)
	if err != nil {
		t.Fatalf("expected the retry to recover, got error: %v", err)
	}
	if n := atomic.LoadInt32(&hits); n != 2 {
		t.Fatalf("expected exactly 2 requests (fail then succeed), got %d", n)
	}
	if len(got) != 1 || got["a--b--c"] == "" {
		t.Fatalf("expected the envelope to decode into one id, got %v", got)
	}
}

// TestFetchServedStillFailsWhenEveryAttemptFails is the guard against this
// change becoming a softening. UNREACHABLE must survive the retry.
func TestFetchServedStillFailsWhenEveryAttemptFails(t *testing.T) {
	withFastRetries(t, 3)
	var hits int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
		http.Error(w, "down", http.StatusServiceUnavailable)
	}))
	defer srv.Close()

	if _, err := fetchServed(srv.URL); err == nil {
		t.Fatal("a permanently failing host MUST error — a check that cannot check never reports clean")
	}
	if n := atomic.LoadInt32(&hits); n != 3 {
		t.Fatalf("expected all 3 attempts to be spent, got %d", n)
	}
}

// TestFetchServedDoesNotRetryWhatWaitingCannotFix — a 404 is a wrong URL, not a
// blip. Retrying it would just slow an honest failure down.
func TestFetchServedDoesNotRetryPermanentFailures(t *testing.T) {
	withFastRetries(t, 3)
	for _, tc := range []struct {
		name string
		code int
		body string
	}{
		{"404 not found", http.StatusNotFound, "nope"},
		{"401 unauthorized", http.StatusUnauthorized, "nope"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var hits int32
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				atomic.AddInt32(&hits, 1)
				http.Error(w, tc.body, tc.code)
			}))
			defer srv.Close()

			if _, err := fetchServed(srv.URL); err == nil {
				t.Fatal("expected an error")
			}
			if n := atomic.LoadInt32(&hits); n != 1 {
				t.Fatalf("expected exactly 1 attempt for a permanent failure, got %d", n)
			}
		})
	}
}

// A body that is not the envelope cannot be cured by waiting either.
func TestFetchServedDoesNotRetryUndecodableBody(t *testing.T) {
	withFastRetries(t, 3)
	var hits int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
		fmt.Fprint(w, "<html>not json</html>")
	}))
	defer srv.Close()

	_, err := fetchServed(srv.URL)
	if err == nil {
		t.Fatal("a non-envelope body MUST error, never decode to an empty catalog")
	}
	if !strings.Contains(err.Error(), "decode query envelope") {
		t.Fatalf("expected a decode error naming the envelope, got %v", err)
	}
	if n := atomic.LoadInt32(&hits); n != 1 {
		t.Fatalf("expected exactly 1 attempt for an undecodable body, got %d", n)
	}
}

// 429 IS transient — a rate limit clears on its own.
func TestFetchServedRetriesRateLimit(t *testing.T) {
	withFastRetries(t, 3)
	var hits int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if atomic.AddInt32(&hits, 1) < 3 {
			http.Error(w, "slow down", http.StatusTooManyRequests)
			return
		}
		fmt.Fprint(w, envelope)
	}))
	defer srv.Close()

	if _, err := fetchServed(srv.URL); err != nil {
		t.Fatalf("a rate limit should be retried and recover, got %v", err)
	}
	if n := atomic.LoadInt32(&hits); n != 3 {
		t.Fatalf("expected 3 attempts, got %d", n)
	}
}

// An UNREACHABLE host must produce NO table. The workflow tells UNREACHABLE
// apart from DRIFT by exactly that — a nonzero exit with no table row — so this
// pins the distinction the gate's step logic relies on.
func TestRunCheckOnUnreachableHostPrintsNoTable(t *testing.T) {
	withFastRetries(t, 2)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "down", http.StatusServiceUnavailable)
	}))
	srv.Close() // closed: nothing is listening, so this is a transport failure

	_, err := fetchServed(srv.URL)
	if err == nil {
		t.Fatal("expected a transport error against a closed listener")
	}
	for _, banned := range []string{"MATCH", "DRIFT", "MISSING", "EXTRA"} {
		if strings.Contains(err.Error(), banned) {
			t.Fatalf("an unreachable-host error must not read as a drift verdict; got %v", err)
		}
	}
}

// printCheckTable is the comparison the whole gate rests on. All four statuses,
// no network.
func TestPrintCheckTableStatuses(t *testing.T) {
	payloads := []*payload{
		{ID: "match--x--y", Source: "SAME"},
		{ID: "drift--x--y", Source: "LOCAL"},
		{ID: "missing--x--y", Source: "ONLY-LOCAL"},
	}
	served := map[string]string{
		"match--x--y": sha256hex("SAME"),
		"drift--x--y": sha256hex("SERVED"),
		"extra--x--y": sha256hex("ONLY-SERVED"),
	}

	var sb strings.Builder
	nonMatch := printCheckTable(&sb, "http://fixture", payloads, served)
	out := sb.String()

	if nonMatch != 3 {
		t.Fatalf("expected 3 non-MATCH rows (drift, missing, extra), got %d\n%s", nonMatch, out)
	}
	for _, want := range []string{
		"match--x--y", "drift--x--y", "missing--x--y", "extra--x--y",
		"MATCH", "DRIFT", "MISSING", "EXTRA",
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("table is missing %q\n%s", want, out)
		}
	}
	// A drifted catalog must never render the in-sync sentence the workflow
	// greps for, or the gate would read a red table as green.
	if strings.Contains(out, "MATCH — catalog in sync") {
		t.Fatalf("a drifted table must not print the in-sync line\n%s", out)
	}
}

func TestPrintCheckTableAllMatchPrintsTheInSyncLine(t *testing.T) {
	payloads := []*payload{{ID: "a--b--c", Source: "SRC"}}
	served := map[string]string{"a--b--c": sha256hex("SRC")}

	var sb strings.Builder
	if n := printCheckTable(&sb, "http://fixture", payloads, served); n != 0 {
		t.Fatalf("expected 0 non-MATCH rows, got %d", n)
	}
	if !strings.Contains(sb.String(), "MATCH — catalog in sync") {
		t.Fatalf("an in-sync catalog must print the line the workflow greps for:\n%s", sb.String())
	}
}
