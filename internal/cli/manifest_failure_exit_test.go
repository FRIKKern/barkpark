package cli

import (
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The exit contract for "the CLI could not reach the environment".
//
// Row spd-bl-bp-search-exits-zero-while-failing reported that `bp search query
// "..."` printed `acquire manifest from …: context deadline exceeded` on stderr
// and the following `echo EXIT=$?` printed 0 — so a caller could not tell an
// outage from an empty result set. Six of fifteen wave-17 surveyors hit it.
//
// Re-measured against this tree, the headline is REFUTED: every manifest
// acquisition failure already exits non-zero, and has since #1077 moved manifest
// errors onto the `bp:`-prefixed seam (`out.userErr(...); return exitGeneric`).
// The observed EXIT=0 is reproducible only when the invocation is PIPED —
// `bp search … | head` reports head's status, not bp's — which is a shell
// property, not a CLI defect.
//
// What was genuinely missing is the guard: NOTHING pinned the exit code, so the
// path was one refactor away from regressing back into exactly the reported
// shape. These tests are that pin. They assert the exit CODE, deliberately not
// the stderr text — the defect the row describes is precisely one where the
// stderr text was already right while the exit code was wrong, so a test that
// keys on the message would have stayed green through it.

// isolatedEnv points config AND the manifest ETag cache at throwaway dirs, so a
// developer's real ~/.config/barkpark and ~/.cache/barkpark can neither satisfy
// the fetch nor leak a manifest into a test that requires the fetch to fail.
func isolatedEnv(t *testing.T) {
	t.Helper()
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(t.TempDir(), "config"))
	t.Setenv("XDG_CACHE_HOME", filepath.Join(t.TempDir(), "cache"))
	// A manifest override file would bypass the network entirely and make every
	// assertion below vacuous.
	t.Setenv("BARKPARK_MANIFEST", "")
}

// TestSearchExitsNonZeroWhenManifestFetchFails is the row's FIX clause verbatim
// in intent: "Add a test that a failed manifest fetch yields a non-zero exit."
// Both triggers the row names are exercised — an unreachable server and a 500
// from /v1/capabilities — because a timeout and a 500 can take different paths
// and the row asserts they behave identically.
func TestSearchExitsNonZeroWhenManifestFetchFails(t *testing.T) {
	cases := []struct {
		name string
		// serverURL returns a base URL whose /v1/capabilities cannot produce a
		// usable manifest.
		serverURL func(t *testing.T) string
	}{
		{
			name: "server unreachable",
			serverURL: func(t *testing.T) string {
				// A started-then-closed httptest server hands back a port
				// nothing is listening on: connection refused, no timeout wait.
				srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
				url := srv.URL
				srv.Close()
				return url
			},
		},
		{
			name: "capabilities answers 500",
			serverURL: func(t *testing.T) string {
				srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					w.WriteHeader(http.StatusInternalServerError)
					_, _ = io.WriteString(w, `{"error":{"code":"internal_error","message":"boom"}}`)
				}))
				t.Cleanup(srv.Close)
				return srv.URL
			},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			isolatedEnv(t)
			t.Setenv("BARKPARK_API_URL", tc.serverURL(t))

			out, code := captureExecuteCode(t, []string{"search", "query", "anything"})

			if code == exitOK {
				t.Fatalf("a failed manifest fetch exited %d (success) — an outage is indistinguishable from an empty result set; output:\n%s", code, out)
			}
		})
	}
}

// TestSearchExitsZeroOnGenuinelyEmptyResult is the row's NEGATIVE ARM: a
// reachable server returning zero documents must STAY exit 0. Making empty
// non-zero would swap one indistinguishability for another, which is the
// failure mode the row explicitly warns against.
func TestSearchExitsZeroOnGenuinelyEmptyResult(t *testing.T) {
	isolatedEnv(t)

	manifestBody, err := os.ReadFile(fixtureManifest)
	if err != nil {
		t.Fatalf("read manifest fixture: %v", err)
	}

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if strings.HasPrefix(r.URL.Path, "/v1/capabilities") {
			_, _ = w.Write(manifestBody)
			return
		}
		// Server reachable, query understood, zero hits.
		_, _ = io.WriteString(w, `{"hits":[],"total":0}`)
	}))
	defer srv.Close()

	t.Setenv("BARKPARK_API_URL", srv.URL)

	out, code := captureExecuteCode(t, []string{"search", "query", "anything", "-o", "json"})

	if code != exitOK {
		t.Fatalf("an empty result set exited %d, want 0 — empty is a finding, not an outage; output:\n%s", code, out)
	}
}
