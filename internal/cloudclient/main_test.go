package cloudclient

import (
	"fmt"
	"os"
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
}
