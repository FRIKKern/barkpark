package main

import (
	"bytes"
	"strings"
	"testing"
)

// Bare `bp` on a fresh install (no config, no env, schema load fails) must offer
// Barkpark Cloud login beside `bp setup` — bp-login-ux-epic criterion 0.
func TestBareBpFirstRunAdviceNamesCloudLoginAndSetup(t *testing.T) {
	var buf bytes.Buffer
	schemaLoadFailureAdvice(&buf, true, "http://localhost:4000")
	out := buf.String()
	for _, want := range []string{"No server is configured yet", "Log in to Barkpark Cloud", "bp login", "bp setup", "BARKPARK_API_URL"} {
		if !strings.Contains(out, want) {
			t.Errorf("first-run advice missing %q:\n%s", want, out)
		}
	}
}

// A configured target keeps target-derived advice and does not print the menu.
func TestConfiguredTargetAdviceUnchanged(t *testing.T) {
	var buf bytes.Buffer
	schemaLoadFailureAdvice(&buf, false, "https://guerrilla.barkpark.cloud")
	out := buf.String()
	if !strings.Contains(out, "bp doctor") || strings.Contains(out, "bp login") {
		t.Errorf("configured remote target advice changed unexpectedly:\n%s", out)
	}
}
