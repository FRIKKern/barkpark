package hostguard

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestRepoIsFreeOfBannedHosts is the regression arm. It reds the moment any
// banned hostname re-enters the tree, in any file, in any lane.
func TestRepoIsFreeOfBannedHosts(t *testing.T) {
	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	root, err := RepoRoot(wd)
	if err != nil {
		t.Fatalf("RepoRoot: %v", err)
	}

	hits, err := Scan(root, Banned)
	if err != nil {
		t.Fatalf("Scan(%s): %v", root, err)
	}
	for _, h := range hits {
		t.Errorf("%s", h)
	}
	if len(hits) > 0 {
		t.Fatalf("%d banned-host occurrence(s) in the tree; the canonical "+
			"control-plane origin is https://barkpark.cloud (deploy/cp-deploy.sh "+
			"pins the live provisioner unit to it)", len(hits))
	}
}

// TestScanFindsAPlantedHost proves the scan CAN LOSE. Without this, a green
// above is indistinguishable from a scan that never looks at anything.
func TestScanFindsAPlantedHost(t *testing.T) {
	dir := t.TempDir()
	nested := filepath.Join(dir, "cmd", "thing")
	if err := os.MkdirAll(nested, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	bad := filepath.Join(nested, "main.go")
	body := "package main\n\n// --control-url https://" + Banned[0] + "\nfunc main() {}\n"
	if err := os.WriteFile(bad, []byte(body), 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}

	hits, err := Scan(dir, Banned)
	if err != nil {
		t.Fatalf("Scan: %v", err)
	}
	if len(hits) != 1 {
		t.Fatalf("planted 1 occurrence, Scan found %d: %v", len(hits), hits)
	}
	if got := filepath.ToSlash(hits[0].Path); got != "cmd/thing/main.go" {
		t.Errorf("hit path = %q, want cmd/thing/main.go", got)
	}
	if hits[0].Line != 3 {
		t.Errorf("hit line = %d, want 3", hits[0].Line)
	}
}

// TestScanIgnoresTheCanonicalHost is the CONTROL for the arm above: a tree
// carrying only the correct host must come back clean, so a hit means the
// banned string and not merely "the scanner fires on everything".
func TestScanIgnoresTheCanonicalHost(t *testing.T) {
	dir := t.TempDir()
	good := filepath.Join(dir, "main.go")
	body := "package main\n\n// --control-url https://barkpark.cloud\n"
	if err := os.WriteFile(good, []byte(body), 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}
	hits, err := Scan(dir, Banned)
	if err != nil {
		t.Fatalf("Scan: %v", err)
	}
	if len(hits) != 0 {
		t.Fatalf("canonical host flagged: %v", hits)
	}
}

// TestScanSkipsBuildOutput keeps the repo-wide arm from reding on a stale
// artifact under _build/ or node_modules that no operator ever reads.
func TestScanSkipsBuildOutput(t *testing.T) {
	dir := t.TempDir()
	for _, skipped := range []string{"_build", "node_modules", ".git"} {
		sub := filepath.Join(dir, skipped)
		if err := os.MkdirAll(sub, 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", skipped, err)
		}
		if err := os.WriteFile(filepath.Join(sub, "x.txt"), []byte(Banned[0]), 0o600); err != nil {
			t.Fatalf("write %s: %v", skipped, err)
		}
	}
	hits, err := Scan(dir, Banned)
	if err != nil {
		t.Fatalf("Scan: %v", err)
	}
	if len(hits) != 0 {
		t.Fatalf("skipped dirs produced hits: %v", hits)
	}
}

// TestBannedEntriesAreAssembled guards the guard: a future editor who
// "simplifies" Banned into a string literal would plant the very occurrence
// the repo-wide arm hunts, and the arm would then red on itself forever.
func TestBannedEntriesAreAssembled(t *testing.T) {
	src, err := os.ReadFile("hostguard.go")
	if err != nil {
		t.Fatalf("read hostguard.go: %v", err)
	}
	for _, host := range Banned {
		if strings.Contains(string(src), host) {
			t.Errorf("hostguard.go contains the literal %q — assemble it from "+
				"fragments so the file is not a hit on itself", host)
		}
	}
}
