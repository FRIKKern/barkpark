package cli

// cloud_site_prebuilt_ambient_test.go covers the D7 shadow guard on the ONE
// deploy lane that can carry an ambient token into shipped bytes: `--prebuilt`.
// The managed lane is closed by construction on the box (see
// warnPrebuiltAmbientToken's comment), so there is nothing to guard there.

import (
	"bytes"
	"strings"
	"testing"
)

func TestWarnPrebuiltAmbientTokenSpeaksAndTeaches(t *testing.T) {
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	env := map[string]string{"BARKPARK_TOKEN": "bp_admin_wxyz9876"}
	warnPrebuiltAmbientToken(w, "my-site", "dist", func(k string) (string, bool) { v, ok := env[k]; return v, ok })

	all := sout.String() + serr.String()
	if !strings.Contains(all, "BARKPARK_TOKEN is set in this shell") {
		t.Errorf("the prebuilt lane must NAME what it saw, got:\n%s", all)
	}
	if !strings.Contains(all, "env -u BARKPARK_TOKEN") {
		t.Errorf("the notice must carry its own remedy command, got:\n%s", all)
	}
	if !strings.Contains(all, "--deployment") {
		t.Errorf("the remedy must say how to re-ship to the SAME deployment, got:\n%s", all)
	}
	if strings.Contains(all, "bp_admin_wxyz9876") {
		t.Errorf("the notice must not echo the credential, got:\n%s", all)
	}
}

func TestWarnPrebuiltAmbientTokenSilentOnACleanShell(t *testing.T) {
	var sout, serr bytes.Buffer
	w := newWriter(&sout, &serr)
	warnPrebuiltAmbientToken(w, "my-site", "dist", func(string) (string, bool) { return "", false })
	if all := sout.String() + serr.String(); strings.TrimSpace(all) != "" {
		t.Errorf("a clean shell must produce no notice, got:\n%s", all)
	}
	// A blank value is "no hazard" (ambientTokenShadow's contract) — a notice
	// here would fire on every CI job that exports an empty placeholder.
	sout.Reset()
	serr.Reset()
	warnPrebuiltAmbientToken(w, "my-site", "dist", func(string) (string, bool) { return "   ", true })
	if all := sout.String() + serr.String(); strings.TrimSpace(all) != "" {
		t.Errorf("a blank BARKPARK_TOKEN must produce no notice, got:\n%s", all)
	}
}
