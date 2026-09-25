package cli

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// sandboxConfigHome is the throwaway XDG_CONFIG_HOME every test in this package
// starts under. TestMain sets it before any test runs.
var sandboxConfigHome string

// TestMain points XDG_CONFIG_HOME at a fresh temp dir for the WHOLE package, so
// no test can read or write the real ${XDG_CONFIG_HOME:-~/.config}/barkpark.
//
// WHY A PACKAGE-WIDE DEFAULT, not only withTempConfigHome(t): the per-test
// helper is opt-in, and one test that forgot it (seedCloudLogin -> SaveConfig
// in a new dark-duration render test, 2026-09-25) overwrote the owner's real
// config.json four times in one morning. withTempConfigHome(t) still works and
// still gives a test its own dir; this is the floor under it.
func TestMain(m *testing.M) {
	os.Exit(runWithSandboxedConfigHome(m))
}

// realHomeAtStart is the caller's HOME, captured before the sandbox replaces it.
var realHomeAtStart string

func runWithSandboxedConfigHome(m *testing.M) int {
	realHomeAtStart, _ = os.UserHomeDir()
	// Resolve the REAL config dir with the caller's environment, before the
	// sandbox replaces it, and fingerprint what is there.
	realDir, _ := configDir()
	before := snapshotConfigDir(realDir)

	dir, err := os.MkdirTemp("", "bp-cli-test-xdg-")
	if err != nil {
		fmt.Fprintf(os.Stderr, "TestMain: cannot create sandbox config home: %v\n", err)
		return 2
	}
	defer os.RemoveAll(dir)
	if err := os.Setenv("XDG_CONFIG_HOME", dir); err != nil {
		fmt.Fprintf(os.Stderr, "TestMain: cannot set XDG_CONFIG_HOME: %v\n", err)
		return 2
	}
	if err := sandboxHome(); err != nil {
		fmt.Fprintf(os.Stderr, "TestMain: cannot sandbox HOME: %v\n", err)
		return 2
	}
	sandboxConfigHome = dir
	code := m.Run()

	// THE WRITE DETECTOR. A test that escapes the sandbox (by re-pointing
	// XDG_CONFIG_HOME at the real home, or by writing a path it built itself)
	// changes the real dir; this fails the whole binary and names it.
	if after := snapshotConfigDir(realDir); !bytes.Equal(before, after) {
		fmt.Fprintf(os.Stderr, "FAIL: a test in this package WROTE the real bp config dir %s (its contents changed during the run). Use withTempConfigHome(t).\n", realDir)
		if code == 0 {
			code = 1
		}
	}
	return code
}

// snapshotConfigDir fingerprints every regular file directly in dir as
// name + size + mtime + bytes. A missing dir fingerprints as empty, so a test
// that CREATES the real dir is caught too.
func snapshotConfigDir(dir string) []byte {
	var b bytes.Buffer
	if dir == "" {
		return nil
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	for _, e := range entries {
		info, err := e.Info()
		if err != nil || !info.Mode().IsRegular() {
			continue
		}
		data, _ := os.ReadFile(filepath.Join(dir, e.Name()))
		fmt.Fprintf(&b, "%s|%d|%d|", e.Name(), info.Size(), info.ModTime().UnixNano())
		b.Write(data)
		b.WriteByte(0)
	}
	return b.Bytes()
}

// The guard. It reds if TestMain is deleted or stops exporting the sandbox, and
// it asserts the property that matters (where SaveConfig would write), not just
// that an env var is set.
func TestConfigHomeIsSandboxedForThePackage(t *testing.T) {
	if sandboxConfigHome == "" {
		t.Fatal("TestMain did not run: sandboxConfigHome is empty, so tests in this package can write the real ~/.config/barkpark")
	}
	if got := os.Getenv("XDG_CONFIG_HOME"); got != sandboxConfigHome {
		t.Fatalf("XDG_CONFIG_HOME = %q, want the package sandbox %q", got, sandboxConfigHome)
	}
	path, err := ConfigPath()
	if err != nil {
		t.Fatalf("ConfigPath: %v", err)
	}
	if !strings.HasPrefix(path, sandboxConfigHome+string(filepath.Separator)) {
		t.Fatalf("ConfigPath() = %q is outside the sandbox %q", path, sandboxConfigHome)
	}
	if got, _ := os.UserHomeDir(); got != sandboxHomeDir {
		t.Fatalf("HOME resolves to %q, want the package sandbox %q", got, sandboxHomeDir)
	}
	if home := realHomeAtStart; home != "" {
		real := filepath.Join(home, ".config", "barkpark")
		if strings.HasPrefix(path, real) {
			t.Fatalf("ConfigPath() = %q resolves under the real config dir %q", path, real)
		}
	}
}

// sandboxHome points HOME at a fresh temp dir too, so a path a test builds from
// os.UserHomeDir (~/.config, ~/.claude, ~/.ssh) cannot reach the real home.
// The Go toolchain derives its caches from HOME, and some tests shell out to
// `go`, so GOPATH and GOCACHE are pinned to their REAL values first (only when
// the caller has not set them); otherwise a subprocess would re-download every
// module into an empty cache.
func sandboxHome() error {
	realHome, herr := os.UserHomeDir()
	if herr == nil {
		if os.Getenv("GOPATH") == "" {
			os.Setenv("GOPATH", filepath.Join(realHome, "go"))
		}
	}
	if os.Getenv("GOCACHE") == "" {
		if c, err := os.UserCacheDir(); err == nil {
			os.Setenv("GOCACHE", filepath.Join(c, "go-build"))
		}
	}
	home, err := os.MkdirTemp("", "bp-cli-test-home-")
	if err != nil {
		return err
	}
	sandboxHomeDir = home
	return os.Setenv("HOME", home)
}

// sandboxHomeDir is the throwaway HOME, removed by the OS temp reaper.
var sandboxHomeDir string
