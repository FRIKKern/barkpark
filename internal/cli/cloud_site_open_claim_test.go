package cli

// cloud_site_open_claim_test.go is the behavioural lock for ssw8: the
// `bp cloud site open` receipt may report only what the CLI actually read.
// browserOpener Start()s a launcher and never Wait()s, so the strongest true
// statement is "a launcher process started" — never "your browser opened".
// These arms red if the sentence goes back to asserting the window.

import (
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// siteOpenFixtureID is a UUID-shaped ref so resolveOpenSiteID short-circuits and
// the fake control plane only has to answer GET /v1/sites/<id>.
const siteOpenFixtureID = "11111111-2222-3333-4444-555555555555"

// siteOpenServer answers the one read `bp cloud site open` makes, with a site
// carrying an explicit URL.
func siteOpenServer(t *testing.T) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/sites/"+siteOpenFixtureID {
			http.NotFound(w, r)
			return
		}
		_, _ = io.WriteString(w, `{"site":{"id":"`+siteOpenFixtureID+`","slug":"blog","instance":"acme","url":"https://acme.barkpark.cloud/sites/blog/"}}`)
	}))
	t.Cleanup(srv.Close)
	return srv
}

// runSiteOpen drives the verb on a tty with a stubbed launcher. openErr is what
// browserOpener returns; verbose is on because the launch note rides out.info.
func runSiteOpen(t *testing.T, jsonOut bool, openErr error, args ...string) (string, string, int) {
	t.Helper()
	withTempConfigHome(t)
	srv := siteOpenServer(t)
	seedCloudLogin(t, srv.URL)
	prev := browserOpener
	browserOpener = func(string) error { return openErr }
	t.Cleanup(func() { browserOpener = prev })

	return runCloudCapture(t, jsonOut, func(out *writer) int {
		out.isTTY = true
		out.verbose = true
		if !jsonOut {
			// applyGlobals defaults a non-tty writer to json; the human receipt is
			// what these arms measure, so say so explicitly.
			out.output = "table"
		}
		return runCloudSiteOpen(out, globals{}, args)
	})
}

// TestSiteOpenReceiptDoesNotClaimTheBrowserOpened is the mutation target: restore
// "opening in your browser…" and this reds on both arms.
func TestSiteOpenReceiptDoesNotClaimTheBrowserOpened(t *testing.T) {
	stdout, stderr, code := runSiteOpen(t, false, nil, siteOpenFixtureID)
	if code != exitOK {
		t.Fatalf("exit = %d, want %d\nstdout: %s\nstderr: %s", code, exitOK, stdout, stderr)
	}
	if !strings.Contains(stdout, "https://acme.barkpark.cloud/sites/blog/") {
		t.Fatalf("the URL is the deliverable and must always print; stdout: %q", stdout)
	}
	// The claim it must NOT make: a window, a page, a browser.
	for _, banned := range []string{"opening in your browser", "opened in your browser"} {
		if strings.Contains(strings.ToLower(stderr), banned) {
			t.Errorf("receipt asserts a browser opened (%q) — all the CLI read is that a launcher process started; stderr: %q", banned, stderr)
		}
	}
	// The limit, stated in the same breath.
	for _, want := range []string{"launcher", "never sees the window"} {
		if !strings.Contains(stderr, want) {
			t.Errorf("receipt must name what it did not read (missing %q); stderr: %q", want, stderr)
		}
	}
	if !strings.Contains(stderr, siteOpenLaunchNote()) {
		t.Errorf("receipt is not siteOpenLaunchNote(); stderr: %q", stderr)
	}
}

// TestSiteOpenReceiptSaysNothingWhenTheLauncherFails: a launcher that errors
// yields no launch sentence at all, and the failure names the launcher, not a
// browser it never observed.
func TestSiteOpenReceiptSaysNothingWhenTheLauncherFails(t *testing.T) {
	stdout, stderr, code := runSiteOpen(t, false, fmt.Errorf("exec: \"xdg-open\": not found"), siteOpenFixtureID)
	if code != exitOK {
		t.Fatalf("a failed launch must not fail the command (the URL printed); exit = %d", code)
	}
	if !strings.Contains(stdout, "https://acme.barkpark.cloud/sites/blog/") {
		t.Fatalf("URL missing from stdout: %q", stdout)
	}
	if strings.Contains(stderr, siteOpenLaunchNote()) {
		t.Errorf("launch note printed although the launcher errored; stderr: %q", stderr)
	}
	if !strings.Contains(stderr, "could not start a browser launcher") {
		t.Errorf("failure line must say the launcher did not start; stderr: %q", stderr)
	}
}

// TestSiteOpenPrintOnlyNeverLaunches pins --print-only: no launcher call, no
// launch claim.
func TestSiteOpenPrintOnlyNeverLaunches(t *testing.T) {
	withTempConfigHome(t)
	srv := siteOpenServer(t)
	seedCloudLogin(t, srv.URL)
	calls := 0
	prev := browserOpener
	browserOpener = func(string) error { calls++; return nil }
	t.Cleanup(func() { browserOpener = prev })

	stdout, stderr, code := runCloudCapture(t, false, func(out *writer) int {
		out.isTTY = true
		out.verbose = true
		out.output = "table"
		return runCloudSiteOpen(out, globals{}, []string{siteOpenFixtureID, "--print-only"})
	})
	if code != exitOK {
		t.Fatalf("exit = %d\nstderr: %s", code, stderr)
	}
	if calls != 0 {
		t.Errorf("--print-only launched a browser %d time(s)", calls)
	}
	if strings.Contains(stderr, siteOpenLaunchNote()) {
		t.Errorf("--print-only printed a launch note; stderr: %q", stderr)
	}
	if !strings.Contains(stdout, "https://acme.barkpark.cloud/sites/blog/") {
		t.Errorf("URL missing from stdout: %q", stdout)
	}
}

// TestSiteOpenJSONFieldIsLaunchedNotOpened: the machine envelope carries the same
// honesty as the sentence — a bool named `opened` is the claim in JSON.
func TestSiteOpenJSONFieldIsLaunchedNotOpened(t *testing.T) {
	stdout, stderr, code := runSiteOpen(t, true, nil, siteOpenFixtureID)
	if code != exitOK {
		t.Fatalf("exit = %d\nstderr: %s", code, stderr)
	}
	for _, want := range []string{`"ok":true`, `"site":"blog"`, `"url":"https://acme.barkpark.cloud/sites/blog/"`, `"launched":true`} {
		if !strings.Contains(stdout, want) {
			t.Errorf("json missing %q:\n%s", want, stdout)
		}
	}
	if strings.Contains(stdout, `"opened"`) {
		t.Errorf("json still carries an `opened` bool — it records a launcher start, not a window:\n%s", stdout)
	}
}
