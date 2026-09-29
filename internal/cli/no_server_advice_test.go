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
