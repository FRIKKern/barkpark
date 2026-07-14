package main

import (
	"errors"
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
