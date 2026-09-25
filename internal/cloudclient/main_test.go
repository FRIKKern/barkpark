package cloudclient

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

// sandboxConfigHome is the throwaway XDG_CONFIG_HOME this package's tests run
// under. cloudclient does not read the bp config today; this is the same floor
// internal/cli has (see its main_test.go), so a future test here that reaches
// config through a helper cannot touch the real ~/.config/barkpark.
var sandboxConfigHome string

func TestMain(m *testing.M) {
	os.Exit(runWithSandboxedConfigHome(m))
}

func runWithSandboxedConfigHome(m *testing.M) int {
	dir, err := os.MkdirTemp("", "bp-cloudclient-test-xdg-")
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
	return m.Run()
}

func TestConfigHomeIsSandboxedForThePackage(t *testing.T) {
	if sandboxConfigHome == "" {
		t.Fatal("TestMain did not run: sandboxConfigHome is empty")
	}
	if got := os.Getenv("XDG_CONFIG_HOME"); got != sandboxConfigHome {
		t.Fatalf("XDG_CONFIG_HOME = %q, want the package sandbox %q", got, sandboxConfigHome)
	}
	if got, _ := os.UserHomeDir(); got != sandboxHomeDir {
		t.Fatalf("HOME resolves to %q, want the package sandbox %q", got, sandboxHomeDir)
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
	home, err := os.MkdirTemp("", "bp-cloudclient-test-home-")
	if err != nil {
		return err
	}
	sandboxHomeDir = home
	return os.Setenv("HOME", home)
}

// sandboxHomeDir is the throwaway HOME, removed by the OS temp reaper.
var sandboxHomeDir string
