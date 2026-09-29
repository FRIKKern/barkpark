package cli

import (
	"bytes"
	"errors"
	"strings"
	"testing"
)

// TestDeviceLoginBrowserOpenFailureFallsBackToCopyLink pins the browser-open
// failure path (bp-login-ux-epic criterion 2): on a terminal the user presses
// Enter, the opener FAILS (no browser, headless box, xdg-open missing), and the
// flow must NOT die. It says it could not open a browser, points at the URL
// already printed in the box, keeps polling, and lands the session once the
// user approves from any device via the copied link.
func TestDeviceLoginBrowserOpenFailureFallsBackToCopyLink(t *testing.T) {
	withTempConfigHome(t)
	withInstantDevicePolls(t, 10)

	var opened []string
	orig := browserOpener
	browserOpener = func(url string) error {
		opened = append(opened, url)
		return errors.New("exec: \"xdg-open\": executable file not found in $PATH")
	}
	t.Cleanup(func() { browserOpener = orig })

	var ds deviceServer
	srv := newDeviceServer(t, &ds, 1, "sess-copied-link", "team-copy")

	cfg := &Config{}
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"
	w.isTTY = true // force the interactive Enter → open-browser path

	var err error
	withStdin(t, "\n", func() { err = runDeviceLoginFlow(w, cfg, srv.URL, "bp on test") })
	if err != nil {
		t.Fatalf("a browser-open failure must not fail the login: %v\nstderr:\n%s", err, stderr.String())
	}

	// The opener WAS attempted, with the code-prefilled URL.
	if len(opened) != 1 || !strings.HasSuffix(opened[0], "/device?code=WXYZ-1234") {
		t.Fatalf("browserOpener calls = %v, want one call with the complete verification URL", opened)
	}

	errOut := stderr.String()
	for _, want := range []string{
		"could not open a browser",
		"copy the URL above",
		srv.URL + "/device", // the copyable link is on screen
		"WXYZ-1234",         // and the code to type into it
		"Or log in with email",
	} {
		if !strings.Contains(errOut, want) {
			t.Fatalf("stderr missing %q after a failed browser open:\n%s", want, errOut)
		}
	}

	// Polling carried on past the failure and the session landed.
	if ds.pollHits.Load() != 2 {
		t.Fatalf("device/poll hits = %d, want 2 (1 pending + 1 approved)", ds.pollHits.Load())
	}
	loaded, lerr := LoadConfig()
	if lerr != nil {
		t.Fatalf("LoadConfig: %v", lerr)
	}
	if loaded.CloudToken != "sess-copied-link" || loaded.CloudTeam != "team-copy" {
		t.Fatalf("session not stored after copy-link approval: token=%q team=%q", loaded.CloudToken, loaded.CloudTeam)
	}
	// The failure text is chrome: nothing about it (or the token) rides stdout.
	if strings.Contains(stdout.String(), "could not open a browser") || strings.Contains(stdout.String(), "sess-copied-link") {
		t.Fatalf("stdout must stay free of chrome and the bearer:\n%s", stdout.String())
	}
}
