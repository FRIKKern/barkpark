package cli

import (
	"os"
	"path/filepath"
	"testing"
)

// A config directory that ALREADY exists with loose permissions — e.g. created
// 0755 by an earlier `bp cmux` hook writing <config>/barkpark/cmux — is
// tightened to 0700 by the save that writes the token file into it. MkdirAll is
// a no-op on an existing directory, so without the explicit chmod the token
// file lived in a world-listable directory (r2-lane-b Go secret-exposure audit).
func TestConfigSaveTightensPreexistingLooseDir(t *testing.T) {
	root := withTempConfigHome(t)
	dir := filepath.Join(root, "barkpark")
	if err := os.MkdirAll(filepath.Join(dir, "cmux"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(dir, 0o755); err != nil {
		t.Fatal(err)
	}

	if err := SaveConfig(&Config{Server: "https://api.barkpark.cloud", Token: "fixture-not-a-token"}); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}

	di, err := os.Stat(dir)
	if err != nil {
		t.Fatal(err)
	}
	if perm := di.Mode().Perm(); perm != 0o700 {
		t.Fatalf("pre-existing config dir perms = %o after save, want 0700", perm)
	}
}
