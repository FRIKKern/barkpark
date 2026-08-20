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
