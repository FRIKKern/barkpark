package cli

import (
	"bytes"
	"strings"
	"testing"
)

// `bp -s nosuch doc ls post` used the typo as a raw URL: a withheld-credential
// notice, then `unsupported protocol scheme ""` from the manifest fetch, exit 1
// (stranger walk, 2026-10-01). It is now the same not_found `bp use` gives.

func TestServerFlagUnknownNameIsRefused(t *testing.T) {
	seedServersConfig(t)
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	code, refused := refuseUnknownServerName(w, globals{server: "nosuch"})
	if !refused || code != exitUsage {
		t.Fatalf("refused=%v code=%d, want a usage refusal", refused, code)
	}
	for _, want := range []string{`no known server matches "nosuch"`, "known servers: prod, localdev", "-s https://nosuch"} {
		if !strings.Contains(stderr.String(), want) {
			t.Errorf("stderr missing %q:\n%s", want, stderr.String())
		}
	}
}

func TestServerFlagUnknownNameJSON(t *testing.T) {
	seedServersConfig(t)
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "json"
	if _, refused := refuseUnknownServerName(w, globals{server: "guerrilla.barkpark.cloud"}); !refused {
		t.Fatal("a bare hostname with no scheme must be refused")
	}
	got := stdout.String()
	for _, want := range []string{`"code":"not_found"`, `"known":["prod","localdev"]`, `-s https://guerrilla.barkpark.cloud`} {
		if !strings.Contains(got, want) {
			t.Errorf("json missing %s:\n%s", want, got)
		}
	}
}

func TestServerFlagKnownNamesAndURLsPass(t *testing.T) {
	seedServersConfig(t)
	for _, v := range []string{"", "prod", "LOCALDEV", "https://api.example.com", "http://127.0.0.1:4610", "https://unsaved.example.com"} {
		var stdout, stderr bytes.Buffer
		if _, refused := refuseUnknownServerName(newWriter(&stdout, &stderr), globals{server: v}); refused {
			t.Errorf("-s %q was refused; a saved name or any URL must resolve as before", v)
		}
	}
}

func TestServerFlagTypoExitsUsageThroughExecute(t *testing.T) {
	seedServersConfig(t)
	if code := Execute([]string{"-s", "nosuch", "doc", "ls", "post"}); code != exitUsage {
		t.Fatalf("Execute exit = %d, want %d (the refusal, before any request)", code, exitUsage)
	}
}
