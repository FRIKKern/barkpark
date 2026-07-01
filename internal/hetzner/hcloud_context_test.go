package hetzner

import (
	"os"
	"path/filepath"
	"testing"
)

// writeCLIToml writes a cli.toml under a temp dir and points HCLOUD_CONFIG at
// it, mirroring what the hcloud CLI itself writes (indented quoted values).
func writeCLIToml(t *testing.T, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "cli.toml")
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("write cli.toml: %v", err)
	}
	t.Setenv("HCLOUD_CONFIG", path)
	return path
}

const sampleCLIToml = `active_context = "work"

[[contexts]]
  name = "personal"
  token = "tok-personal"

[[contexts]]
  name = "work"
  token = "tok-work"
`

// TestTokenFromCLIContext asserts the active-context read, the
// HCLOUD_CONTEXT override, and the unknown-context error.
func TestTokenFromCLIContext(t *testing.T) {
	writeCLIToml(t, sampleCLIToml)
	t.Setenv("HCLOUD_CONTEXT", "")

	tok, err := TokenFromCLIContext()
	if err != nil || tok != "tok-work" {
		t.Fatalf("TokenFromCLIContext = %q, %v; want tok-work (the active context)", tok, err)
	}

	t.Setenv("HCLOUD_CONTEXT", "personal")
	tok, err = TokenFromCLIContext()
	if err != nil || tok != "tok-personal" {
		t.Fatalf("TokenFromCLIContext with HCLOUD_CONTEXT=personal = %q, %v; want tok-personal", tok, err)
	}

	t.Setenv("HCLOUD_CONTEXT", "missing")
	if _, err := TokenFromCLIContext(); err == nil {
		t.Fatal("TokenFromCLIContext with an unknown context name did not error")
	}
}

// TestResolveTokenFallsBackToCLIContext asserts the full ladder: a blank
// HCLOUD_TOKEN descends to the active hcloud context.
func TestResolveTokenFallsBackToCLIContext(t *testing.T) {
	writeCLIToml(t, sampleCLIToml)
	t.Setenv("HCLOUD_CONTEXT", "")
	t.Setenv("HCLOUD_TOKEN", "")

	tok, err := ResolveToken()
	if err != nil || tok != "tok-work" {
		t.Fatalf("ResolveToken = %q, %v; want the context fallback tok-work", tok, err)
	}

	// An explicitly-set env var still outranks the context file.
	t.Setenv("HCLOUD_TOKEN", "env-wins")
	tok, err = ResolveToken()
	if err != nil || tok != "env-wins" {
		t.Fatalf("ResolveToken = %q, %v; want env-wins over the context file", tok, err)
	}
}

// TestParseHcloudConfigTolerance asserts the subset parser skips what it does
// not understand instead of erroring — comments, unknown sections, unquoted
// values.
func TestParseHcloudConfigTolerance(t *testing.T) {
	active, contexts := parseHcloudConfig(`# a comment
active_context = "x"  # trailing comment inside quotes handled

[preferences]
  poll_interval = 500

[[contexts]]
  name = "x"
  token = tok-unquoted
`)
	if active != "x" {
		t.Fatalf("active = %q, want x", active)
	}
	if len(contexts) != 1 || contexts[0].name != "x" || contexts[0].token != "tok-unquoted" {
		t.Fatalf("contexts = %+v, want one entry x/tok-unquoted", contexts)
	}
}
