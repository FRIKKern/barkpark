package cli

import (
	"strings"
	"testing"
)

// bp-login-ux-epic criterion 0: every unauthenticated state presents "Log in to
// Barkpark Cloud" as a first-class path WITHOUT obscuring the local and
// self-hosted choices. These pin both halves on the shared menu and on the real
// `bp task ready` refusal a fresh install hits.

func assertNoServerMenu(t *testing.T, where, out string) {
	t.Helper()
	for _, want := range []string{
		"Log in to Barkpark Cloud",
		"bp login",
		"bp setup",
		"-s <url>",
		"BARKPARK_API_URL",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("%s: missing %q — the no-server menu must offer Cloud login beside setup and the one-off flag; got:\n%s", where, want, out)
		}
	}
}

func TestNoServerAdviceOffersCloudBesideLocalAndSelfHosted(t *testing.T) {
	assertNoServerMenu(t, "NoServerAdvice()", NoServerAdvice())
}

func TestTaskReadyWithNoConfigPointsAtCloudLogin(t *testing.T) {
	helpEnvNoManifestAtAll(t) // fresh install: temp config home, no BARKPARK_* env
	resetManifestMemo()

	out, code := captureExecuteCode(t, []string{"task", "ready"})
	if code == exitOK {
		t.Fatalf("`bp task ready` with no server exited 0; out:\n%s", out)
	}
	if !strings.Contains(out, "no server configured") {
		t.Fatalf("expected the no-server refusal; out:\n%s", out)
	}
	assertNoServerMenu(t, "bp task ready", out)
}

// The anonymous 401 (no credential sent) is an unauthenticated state too: its
// hint keeps the token and self-hosted remedies and adds Cloud login beside them.
func TestAnonymousUnauthorizedHintOffersCloudLogin(t *testing.T) {
	h := apiError{code: "unauthorized"}.hint()
	for _, want := range []string{"set BARKPARK_API_TOKEN", "bp setup --target connect", "Log in to Barkpark Cloud", "bp login"} {
		if !strings.Contains(h, want) {
			t.Errorf("anonymous 401 hint missing %q: %q", want, h)
		}
	}
	// A credential that was SENT and refused must not be told to log in again.
	if sent := (apiError{code: "unauthorized", credentialSent: true}).hint(); strings.Contains(sent, "bp login") {
		t.Errorf("credential-sent 401 hint must not suggest a fresh login: %q", sent)
	}
}
