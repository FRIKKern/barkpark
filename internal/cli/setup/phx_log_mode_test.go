package setup

import (
	"os"
	"path/filepath"
	"testing"
)

// The dev server's log (~/.barkpark/phx.log) is owner-only, including when an
// older bp already created it world-readable (r2-lane-b Go secret-exposure audit).
func TestPhxLogIsOwnerOnly(t *testing.T) {
	dir := filepath.Join(t.TempDir(), ".barkpark")
	logPath := filepath.Join(dir, "phx.log")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(logPath, []byte("old\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(dir, 0o755); err != nil {
		t.Fatal(err)
	}

	f, err := openPhxLog(logPath)
	if err != nil {
		t.Fatalf("openPhxLog: %v", err)
	}
	f.Close()

	if fi, _ := os.Stat(logPath); fi.Mode().Perm() != 0o600 {
		t.Fatalf("phx.log perms = %o, want 0600", fi.Mode().Perm())
	}
	if di, _ := os.Stat(dir); di.Mode().Perm() != 0o700 {
		t.Fatalf("log dir perms = %o, want 0700", di.Mode().Perm())
	}

	fresh := filepath.Join(t.TempDir(), "new", "phx.log")
	f, err = openPhxLog(fresh)
	if err != nil {
		t.Fatalf("openPhxLog fresh: %v", err)
	}
	f.Close()
	if fi, _ := os.Stat(fresh); fi.Mode().Perm() != 0o600 {
		t.Fatalf("fresh phx.log perms = %o, want 0600", fi.Mode().Perm())
	}
}
