package cli

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// runUninstallCapture drives runUninstall with an in-memory writer and (when
// jsonOut) parses the stdout envelope. Tests run non-TTY, so the --yes gate is
// exactly what an agent sees.
func runUninstallCapture(t *testing.T, g globals, args []string, jsonOut bool) (map[string]any, string, string, int) {
	t.Helper()
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	if jsonOut {
		g.output = "json"
		g.outputSet = true
	}
	w.applyGlobals(g)
	code := runUninstall(w, g, args)
	var env map[string]any
	if jsonOut && stdout.Len() > 0 {
		if err := json.Unmarshal(stdout.Bytes(), &env); err != nil {
			t.Fatalf("unmarshal stdout %q: %v", stdout.String(), err)
		}
	}
	return env, stdout.String(), stderr.String(), code
}

// stubUninstallCmds replaces the shell-out seam for the duration of a test and
// records every invocation, so --local never actually drops a database or
// touches docker.
func stubUninstallCmds(t *testing.T) *[]string {
	t.Helper()
	var calls []string
	orig := uninstallRunCmd
	uninstallRunCmd = func(_ *writer, dir, name string, args ...string) error {
		calls = append(calls, strings.TrimSpace(name+" "+strings.Join(args, " ")+" ["+dir+"]"))
		return nil
	}
	t.Cleanup(func() { uninstallRunCmd = orig })
	return &calls
}

func TestUninstallDryRunDeletesNothing(t *testing.T) {
	withTempConfigHome(t)
	seedActiveServer(t)
	path, _ := ConfigPath()

	_, stdout, _, code := runUninstallCapture(t, globals{dryRun: true}, nil, false)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("dry-run must not delete the config: %v", err)
	}
	for _, want := range []string{"would remove", path, "to remove the binary itself:"} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("dry-run output missing %q:\n%s", want, stdout)
		}
	}
}

func TestUninstallYesRemovesConfig(t *testing.T) {
	withTempConfigHome(t)
	seedActiveServer(t)
	path, _ := ConfigPath()

	env, _, _, code := runUninstallCapture(t, globals{yes: true}, nil, true)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0 (%v)", code, env)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("config should be removed, stat err = %v", err)
	}
	if ok, _ := env["ok"].(bool); !ok {
		t.Fatalf("ok = %v, want true (%v)", env["ok"], env)
	}
	if removed, _ := env["removed"].([]any); len(removed) == 0 {
		t.Fatalf("removed empty (%v)", env)
	}
}

func TestUninstallNonTTYWithoutYesExitsUsage(t *testing.T) {
	withTempConfigHome(t)
	seedActiveServer(t)
	path, _ := ConfigPath()

	_, _, stderr, code := runUninstallCapture(t, globals{}, nil, false)
	if code != exitUsage {
		t.Fatalf("exit = %d, want %d", code, exitUsage)
	}
	if !strings.Contains(stderr, "--yes") {
		t.Fatalf("error should name the --yes escape hatch: %q", stderr)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("nothing should be removed on the gate: %v", err)
	}
}

func TestUninstallLocalRemovesBarkparkHome(t *testing.T) {
	withTempConfigHome(t)
	seedActiveServer(t)
	calls := stubUninstallCmds(t)

	home := filepath.Join(t.TempDir(), "barkpark-home")
	if err := os.MkdirAll(filepath.Join(home, "src"), 0o755); err != nil {
		t.Fatalf("mkdir fake home: %v", err)
	}
	t.Setenv("BARKPARK_HOME", home)

	env, _, _, code := runUninstallCapture(t, globals{yes: true}, []string{"--local"}, true)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0 (%v)", code, env)
	}
	if _, err := os.Stat(home); !os.IsNotExist(err) {
		t.Fatalf("~/.barkpark should be removed, stat err = %v", err)
	}
	// No docker-compose.yml in the fake src => the dropdb path. The seam is
	// stubbed, so nothing real runs; the call is only attempted when dropdb is
	// on PATH (hosts without it get the manual hint instead).
	if _, perr := exec.LookPath("dropdb"); perr == nil {
		foundDrop := false
		for _, c := range *calls {
			if strings.HasPrefix(c, "dropdb --if-exists "+localDevDB) {
				foundDrop = true
			}
		}
		if !foundDrop {
			t.Fatalf("expected a stubbed dropdb call, got %v", *calls)
		}
	}
}

func TestUninstallHelp(t *testing.T) {
	_, stdout, _, code := runUninstallCapture(t, globals{}, []string{"-h"}, false)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	for _, want := range []string{"WHAT IT REMOVES", "WHAT IT NEVER TOUCHES", "--local"} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("help missing %q:\n%s", want, stdout)
		}
	}
}

func TestUninstallUnknownFlagIsUsageError(t *testing.T) {
	_, _, _, code := runUninstallCapture(t, globals{}, []string{"--bogus"}, false)
	if code != exitUsage {
		t.Fatalf("exit = %d, want %d", code, exitUsage)
	}
}
