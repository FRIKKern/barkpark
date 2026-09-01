package main

import (
	"errors"
	"os/exec"
	"testing"
)

func TestAuthReady(t *testing.T) {
	if !authReady("claude", []byte(`{"loggedIn":true}`), nil) {
		t.Fatal("expected Claude JSON status to be ready")
	}
	if !authReady("codex", []byte("Logged in using ChatGPT"), nil) {
		t.Fatal("expected Codex login status to be ready")
	}
	if authReady("codex", []byte("Logged in using ChatGPT"), errors.New("failed")) {
		t.Fatal("command failure must fail closed")
	}
}

// TestAuthReadyRejectsCodexNegation is the anti-regression for reading the
// codex CLI's own NO as a YES. `codex login status` prints the literal line
// "Not logged in" when no credential is present — and that line CONTAINS the
// token "logged in", so an unanchored substring test answers "authenticated"
// to the exact output that says the opposite. Measured against codex-cli
// 0.149.0: the affirmative lines all read "Logged in using <method>" and the
// sole negative reads "Not logged in".
//
// The exit status is the structural discriminator (0 logged in / 1 not), and
// authReady already consults it — so today the substring test is carried
// entirely by the `err != nil` gate above it and contributes only this wrong
// answer. A codex build, wrapper, or shim that reports the negative on a zero
// exit is advertised to the control plane as auth_ready:true, and the server
// then dispatches turns to a host that cannot run them.
func TestAuthReadyRejectsCodexNegation(t *testing.T) {
	for _, out := range []string{
		"Not logged in",
		"Not logged in\n",
		"WARNING: proceeding, even though we could not create PATH aliases\nNot logged in\n",
	} {
		if authReady("codex", []byte(out), nil) {
			t.Fatalf("authReady classified codex output %q as authenticated: the negative status line "+
				"\"Not logged in\" CONTAINS the token \"logged in\", so an unanchored substring match "+
				"reads the CLI's own NO as a YES", out)
		}
	}
}

// TestAuthReadyAcceptsEveryCodexAffirmative pins the whole affirmative set the
// codex binary actually ships (one line per auth mode), each behind the stderr
// noise CombinedOutput merges in: `codex login status` was measured emitting a
// "WARNING: proceeding, …" line AHEAD of its status line, so the affirmative
// test must be anchored PER LINE — anchoring on the whole output would fail
// closed on a real, authenticated host.
func TestAuthReadyAcceptsEveryCodexAffirmative(t *testing.T) {
	affirmatives := []string{
		"Logged in using ChatGPT",
		"Logged in using workload identity",
		"Logged in using access token",
		"Logged in using personal access token",
		"Logged in using Amazon Bedrock API key",
		"Logged in using an API key - sk-…",
	}
	for _, line := range affirmatives {
		if !authReady("codex", []byte(line+"\n"), nil) {
			t.Fatalf("authReady rejected a real codex affirmative status line %q", line)
		}
		noisy := "WARNING: proceeding, even though we could not create PATH aliases\n" + line + "\n"
		if !authReady("codex", []byte(noisy), nil) {
			t.Fatalf("authReady rejected codex affirmative %q behind the stderr warning CombinedOutput merges in", line)
		}
	}
}

func TestCapabilitiesAdvertiseBidirectionalChatRuntime(t *testing.T) {
	got := capabilities()
	chat, _ := got["chat_runtime"].(map[string]any)
	if chat["protocol"] != "bidirectional-v2" {
		t.Fatalf("chat protocol = %v", chat["protocol"])
	}
	providers, _ := got["providers"].(map[string]any)
	_, bpErr := exec.LookPath("bp")
	for _, name := range []string{"claude", "codex"} {
		provider, _ := providers[name].(map[string]any)
		operations, _ := provider["operations"].([]string)
		if len(operations) != 5 || provider["task_hands"] != (bpErr == nil) {
			t.Fatalf("%s capabilities = %#v", name, provider)
		}
	}
}
