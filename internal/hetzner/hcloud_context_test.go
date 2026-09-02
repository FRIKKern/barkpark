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

// shapeDarwinHost points the platform seams at a fixture tree shaped like a
// macOS host: os.UserConfigDir() answers <root>/Library/Application Support,
// HOME is <root>, and neither HCLOUD_CONFIG nor XDG_CONFIG_HOME is set. It
// runs on ANY platform — the darwin-only case is reproduced by the fixture,
// not skipped away on Linux and in CI.
func shapeDarwinHost(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	t.Setenv("HCLOUD_CONFIG", "")
	t.Setenv("XDG_CONFIG_HOME", "")
	t.Setenv("HCLOUD_CONTEXT", "")
	t.Setenv("HOME", root)

	oldCfg, oldHome := userConfigDirFunc, userHomeDirFunc
	userConfigDirFunc = func() (string, error) { return filepath.Join(root, "Library", "Application Support"), nil }
	userHomeDirFunc = func() (string, error) { return root, nil }
	t.Cleanup(func() { userConfigDirFunc, userHomeDirFunc = oldCfg, oldHome })
	return root
}

// writeAt writes content at path, creating its directories.
func writeAt(t *testing.T, path, content string) string {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatalf("mkdir %s: %v", filepath.Dir(path), err)
	}
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
	return path
}

// TestHcloudConfigPathDarwinDotConfig is the macOS shape, measured on a real
// host 2026-07-31: os.UserConfigDir() answers ~/Library/Application Support,
// the hcloud CLI writes ~/.config/hcloud/cli.toml, and nothing lives in the
// former — so the third credential rung was DEAD on every Mac while it worked
// on Linux and in CI. bp must find the file the hcloud CLI actually wrote.
func TestHcloudConfigPathDarwinDotConfig(t *testing.T) {
	root := shapeDarwinHost(t)
	// Only the hcloud CLI's real location holds a config. The Go-spelled
	// directory EXISTS (as it does on any Mac) but has no hcloud/ in it.
	want := writeAt(t, filepath.Join(root, ".config", "hcloud", "cli.toml"), sampleCLIToml)
	if err := os.MkdirAll(filepath.Join(root, "Library", "Application Support"), 0o700); err != nil {
		t.Fatal(err)
	}

	if got := hcloudConfigPath(); got != want {
		t.Fatalf("hcloudConfigPath() = %q, want the hcloud CLI's own %q — the third rung is dead on macOS without it", got, want)
	}
	tok, err := TokenFromCLIContext()
	if err != nil || tok != "tok-work" {
		t.Fatalf("TokenFromCLIContext() = %q, %v; want tok-work read from ~/.config/hcloud/cli.toml", tok, err)
	}
	// The whole ladder pays with BOTH env vars unset — the rung's actual claim.
	t.Setenv("HCLOUD_TOKEN", "")
	tok, err = ResolveToken()
	if err != nil || tok != "tok-work" {
		t.Fatalf("ResolveToken() = %q, %v; want the bare-cli.toml rung to pay with no env token", tok, err)
	}
}

// TestHcloudConfigPathPrecedence: HCLOUD_CONFIG still outranks both spellings,
// and the Go-spelled UserConfigDir keeps its place at the FRONT of the queue —
// the ~/.config lookup is an added fallback, not a reordering.
func TestHcloudConfigPathPrecedence(t *testing.T) {
	root := shapeDarwinHost(t)
	dotConfig := writeAt(t, filepath.Join(root, ".config", "hcloud", "cli.toml"), sampleCLIToml)
	libConfig := writeAt(t, filepath.Join(root, "Library", "Application Support", "hcloud", "cli.toml"), sampleCLIToml)

	if got := hcloudConfigPath(); got != libConfig {
		t.Errorf("with both present hcloudConfigPath() = %q, want the UserConfigDir spelling %q first", got, libConfig)
	}

	override := writeAt(t, filepath.Join(root, "elsewhere", "cli.toml"), sampleCLIToml)
	t.Setenv("HCLOUD_CONFIG", override)
	if got := hcloudConfigPath(); got != override {
		t.Errorf("hcloudConfigPath() = %q, want HCLOUD_CONFIG %q to win over both", got, override)
	}
	t.Setenv("HCLOUD_CONFIG", "")

	// XDG_CONFIG_HOME redirects the second candidate, as it does for the CLI.
	xdg := writeAt(t, filepath.Join(root, "xdg", "hcloud", "cli.toml"), sampleCLIToml)
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(root, "xdg"))
	if err := os.Remove(libConfig); err != nil {
		t.Fatal(err)
	}
	if got := hcloudConfigPath(); got != xdg {
		t.Errorf("with XDG_CONFIG_HOME set hcloudConfigPath() = %q, want %q (not %q)", got, xdg, dotConfig)
	}
}

// TestHcloudConfigPathNoneReadable: with nothing on disk the path is still a
// real one, so the no-token error names a place rather than an empty string.
func TestHcloudConfigPathNoneReadable(t *testing.T) {
	root := shapeDarwinHost(t)
	want := filepath.Join(root, "Library", "Application Support", "hcloud", "cli.toml")
	if got := hcloudConfigPath(); got != want {
		t.Errorf("hcloudConfigPath() with no config = %q, want the first candidate %q", got, want)
	}
	if _, err := TokenFromCLIContext(); err == nil {
		t.Error("TokenFromCLIContext with no config anywhere did not error")
	}
}
