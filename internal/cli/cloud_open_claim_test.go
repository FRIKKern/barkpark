package cli

// cloud_open_claim_test.go is the behavioural lock for task-c49e91ced1d6fd23:
// the `bp cloud open` receipt may report only what the CLI actually read.
// browserOpener Start()s a launcher and never Wait()s, so the strongest TRUE
// statement is "a launcher process started" — never "your browser opened".
// These arms red if the sentence, the failure line or the JSON key goes back to
// asserting the window. It is the sibling of cloud_site_open_claim_test.go,
// which locks the same property for `bp cloud site open` (PR #17491).

import (
	"fmt"
	"strings"
	"testing"
)

// stubBrowserErr replaces browserOpener with a stub returning openErr, and
// counts the calls. "" calls means the launcher was never reached.
func stubBrowserErr(t *testing.T, openErr error) *int {
	t.Helper()
	calls := 0
	prev := browserOpener
	browserOpener = func(string) error { calls++; return openErr }
	t.Cleanup(func() { browserOpener = prev })
	return &calls
}

// runOpenReceipt drives `bp cloud open fleet` (a tab — no network) on a tty with
// a stubbed launcher. verbose is on because the launch note rides out.info, and
// output is forced to "table" because applyGlobals defaults a non-tty writer to
// json: these arms measure the HUMAN receipt, not the envelope.
func runOpenReceipt(t *testing.T, openErr error) (string, string, int) {
	t.Helper()
	withTempConfigHome(t)
	seedCloudLogin(t, "https://dash.test")
	stubBrowserErr(t, openErr)

	return runCloudCapture(t, false, func(out *writer) int {
		out.isTTY = true
		out.verbose = true
		out.output = "table"
		return runCloudOpen(out, globals{}, []string{"fleet"})
	})
}

// TestCloudOpenReceiptDoesNotClaimTheBrowserOpened is the mutation target:
// restore "opening in your browser…" and this reds on three arms.
func TestCloudOpenReceiptDoesNotClaimTheBrowserOpened(t *testing.T) {
	stdout, stderr, code := runOpenReceipt(t, nil)
	if code != exitOK {
		t.Fatalf("exit = %d, want %d\nstdout: %s\nstderr: %s", code, exitOK, stdout, stderr)
	}
	if !strings.Contains(stdout, "https://dash.test/#fleet") {
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
	if !strings.Contains(stderr, openLaunchNote()) {
		t.Errorf("receipt is not openLaunchNote(); stderr: %q", stderr)
	}
}

// TestCloudOpenFailureLineNamesTheLauncher: a launcher that errors yields no
// launch sentence at all, and the failure names the launcher, not a browser the
// CLI never observed. Exit stays 0 — the URL is still printed.
func TestCloudOpenFailureLineNamesTheLauncher(t *testing.T) {
	stdout, stderr, code := runOpenReceipt(t, fmt.Errorf("exec: \"xdg-open\": not found"))
	if code != exitOK {
		t.Fatalf("a failed launch must not fail the command (the URL printed); exit = %d\nstderr: %s", code, stderr)
	}
	if !strings.Contains(stdout, "https://dash.test/#fleet") {
		t.Fatalf("URL missing from stdout: %q", stdout)
	}
	if strings.Contains(stderr, openLaunchNote()) {
		t.Errorf("launch note printed although the launcher errored; stderr: %q", stderr)
	}
	if strings.Contains(stderr, "could not open a browser") {
		t.Errorf("failure line names a browser the CLI never observed; stderr: %q", stderr)
	}
	if !strings.Contains(stderr, "could not start a browser launcher") {
		t.Errorf("failure line must say the launcher did not start; stderr: %q", stderr)
	}
}

// TestCloudOpenPrintOnlyNeverLaunches pins --print-only: no launcher call, no
// launch claim, URL still on stdout.
func TestCloudOpenPrintOnlyNeverLaunches(t *testing.T) {
	withTempConfigHome(t)
	seedCloudLogin(t, "https://dash.test")
	calls := stubBrowserErr(t, nil)

	stdout, stderr, code := runCloudCapture(t, false, func(out *writer) int {
		out.isTTY = true
		out.verbose = true
		out.output = "table"
		return runCloudOpen(out, globals{}, []string{"fleet", "--print-only"})
	})
	if code != exitOK {
		t.Fatalf("exit = %d\nstderr: %s", code, stderr)
	}
	if *calls != 0 {
		t.Errorf("--print-only launched a browser %d time(s)", *calls)
	}
	if strings.Contains(stderr, openLaunchNote()) {
		t.Errorf("--print-only printed a launch note; stderr: %q", stderr)
	}
	if !strings.Contains(stdout, "https://dash.test/#fleet") {
		t.Errorf("URL missing from stdout: %q", stdout)
	}
}

// TestCloudOpenJSONFieldIsLaunchedNotOpened: the machine envelope carries the
// same honesty as the sentence — a bool named `opened` is the claim in JSON.
// This is the true=arm; TestRunCloudOpenJSON pins the false= arm.
func TestCloudOpenJSONFieldIsLaunchedNotOpened(t *testing.T) {
	withTempConfigHome(t)
	seedCloudLogin(t, "https://dash.test")
	stubBrowserErr(t, nil)

	stdout, stderr, code := runCloudCapture(t, true, func(out *writer) int {
		out.isTTY = true
		return runCloudOpen(out, globals{}, []string{"fleet"})
	})
	if code != exitOK {
		t.Fatalf("exit = %d\nstderr: %s", code, stderr)
	}
	for _, want := range []string{`"ok":true`, `"target":"fleet"`, `"url":"https://dash.test/#fleet"`, `"launched":true`} {
		if !strings.Contains(stdout, want) {
			t.Errorf("json missing %q:\n%s", want, stdout)
		}
	}
	if strings.Contains(stdout, `"opened"`) {
		t.Errorf("json still carries an `opened` bool — it records a launcher start, not a window:\n%s", stdout)
	}
}
