package cli

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// withTempConfigHome points XDG_CONFIG_HOME at a fresh temp dir for the duration
// of a test, so config read/write never touches the real ~/.config/barkpark.
func withTempConfigHome(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	return dir
}

func TestConfigRoundTrip(t *testing.T) {
	withTempConfigHome(t)

	want := &Config{
		Server:      "https://api.barkpark.cloud",
		Token:       "tok-123",
		AdminToken:  "admin-456",
		IngestToken: "ingest-789",
		Workspace:   "default",
		Project:     "default",
		Dataset:     "production",
		Output:      "json",
	}

	if err := SaveConfig(want); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}

	got, err := LoadConfig()
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}

	if *got != *want {
		t.Fatalf("round-trip mismatch:\n got=%+v\nwant=%+v", *got, *want)
	}
}

func TestConfigSavePerms(t *testing.T) {
	root := withTempConfigHome(t)

	if err := SaveConfig(&Config{Server: "https://api.barkpark.cloud"}); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}

	// File must be 0600 — it holds tokens.
	path := filepath.Join(root, "barkpark", "config.json")
	fi, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat config: %v", err)
	}
	if perm := fi.Mode().Perm(); perm != 0o600 {
		t.Fatalf("config perms = %o, want 0600", perm)
	}

	// Dir must be 0700.
	di, err := os.Stat(filepath.Join(root, "barkpark"))
	if err != nil {
		t.Fatalf("stat config dir: %v", err)
	}
	if perm := di.Mode().Perm(); perm != 0o700 {
		t.Fatalf("config dir perms = %o, want 0700", perm)
	}
}

func TestConfigReTightensPerms(t *testing.T) {
	root := withTempConfigHome(t)

	if err := SaveConfig(&Config{Server: "a"}); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}
	path := filepath.Join(root, "barkpark", "config.json")
	// Loosen the file, then re-save — SaveConfig must re-tighten to 0600.
	if err := os.Chmod(path, 0o644); err != nil {
		t.Fatalf("chmod loosen: %v", err)
	}
	if err := SaveConfig(&Config{Server: "b"}); err != nil {
		t.Fatalf("SaveConfig re-save: %v", err)
	}
	fi, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if perm := fi.Mode().Perm(); perm != 0o600 {
		t.Fatalf("re-save perms = %o, want 0600", perm)
	}
}

func TestLoadConfigMissingIsEmpty(t *testing.T) {
	withTempConfigHome(t) // fresh dir, no config file written

	got, err := LoadConfig()
	if err != nil {
		t.Fatalf("LoadConfig on missing file should not error, got: %v", err)
	}
	if (*got != Config{}) {
		t.Fatalf("missing-file config should be empty, got %+v", *got)
	}
}

func TestToActiveContext(t *testing.T) {
	c := &Config{Server: "s", Token: "t", Workspace: "w", Project: "p", Dataset: "d", Output: "json"}
	ac := c.ToActiveContext()
	if ac.Server != "s" || ac.Token != "t" || ac.Workspace != "w" || ac.Project != "p" || ac.Dataset != "d" || ac.Output != "json" {
		t.Fatalf("ToActiveContext mismatch: %+v", ac)
	}

	// Nil receiver is safe and yields an empty ActiveContext.
	var nilC *Config
	if nilC.ToActiveContext() != (manifest.ActiveContext{}) {
		t.Fatalf("nil config should yield empty ActiveContext")
	}
}
