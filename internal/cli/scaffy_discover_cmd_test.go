package cli

// scaffy_discover_cmd_test.go covers the `bp scaffy discover` CLI wiring:
// flag parsing + the exit-code contract (0/2/4), the help text, the human
// table and the -o json machine envelope. The mining semantics themselves
// (window derivation, filters, coverage) are pinned in internal/scaffy's
// discover_test.go on a synthetic repo — this file never restates them.

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// seedDiscoverCliRepo builds a minimal git repo with an in-window history
// (three commits touching reg.txt) and chdirs the test into it.
func seedDiscoverCliRepo(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	git := func(args ...string) {
		t.Helper()
		full := append([]string{"-C", root,
			"-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"}, args...)
		cmd := exec.Command("git", full...)
		cmd.Env = append(os.Environ(),
			"GIT_AUTHOR_DATE=2026-01-10T12:00:00+00:00",
			"GIT_COMMITTER_DATE=2026-01-10T12:00:00+00:00")
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	git("init", "-q", "-b", "main")
	for i, line := range []string{"one", "two", "three"} {
		f := filepath.Join(root, "reg.txt")
		fh, err := os.OpenFile(f, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := fh.WriteString(line + "\n"); err != nil {
			t.Fatal(err)
		}
		fh.Close()
		git("add", ".")
		git("commit", "-q", "-m", "c"+string(rune('1'+i)))
	}
	t.Chdir(root)
	return root
}

func TestScaffyDiscoverHelp(t *testing.T) {
	code, stdout, _ := runScaffyTest(t, globals{help: true}, "", "discover")
	if code != exitOK {
		t.Fatalf("help exit = %d, want 0", code)
	}
	for _, want := range []string{
		"usage: bp scaffy discover",
		"--since", "--until", "--min-support", "--top",
		"FREQUENCY evidence, not verdicts",
		"tooling/scaffy-mine/mine.sh",
	} {
		if !strings.Contains(stdout, want) {
			t.Errorf("help missing %q:\n%s", want, stdout)
		}
	}
	// The scaffy noun help lists the verb too.
	code, stdout, _ = runScaffyTest(t, globals{help: true}, "")
	if code != exitOK || !strings.Contains(stdout, "discover [--since") {
		t.Errorf("scaffy noun help must list discover (exit %d):\n%s", code, stdout)
	}
}

func TestScaffyDiscoverUsageErrors(t *testing.T) {
	for name, args := range map[string][]string{
		"unknown flag":    {"discover", "--bogus"},
		"positional":      {"discover", "somewhere"},
		"bad min-support": {"discover", "--min-support", "0"},
		"non-numeric top": {"discover", "--top", "many"},
		"dangling since":  {"discover", "--since"},
		"malformed since": {"discover", "--since", "banana"},
		"duplicate until": {"discover", "--until", "a", "--until", "b"},
	} {
		if code, stdout, stderr := runScaffyTest(t, globals{}, "", args...); code != exitUsage {
			t.Errorf("%s: exit = %d, want %d\nstdout:\n%s\nstderr:\n%s", name, code, exitUsage, stdout, stderr)
		}
	}
}

func TestScaffyDiscoverNotARepoExitsFour(t *testing.T) {
	t.Chdir(t.TempDir())
	if code, _, stderr := runScaffyTest(t, globals{}, "", "discover"); code != exitNotFound {
		t.Errorf("exit = %d, want %d\nstderr:\n%s", code, exitNotFound, stderr)
	}
}

func TestScaffyDiscoverTableOnSeededRepo(t *testing.T) {
	seedDiscoverCliRepo(t)
	code, stdout, stderr := runScaffyTest(t, globals{}, "table", "discover", "--min-support", "2", "--top", "5")
	if code != exitOK {
		t.Fatalf("exit = %d\nstdout:\n%s\nstderr:\n%s", code, stdout, stderr)
	}
	for _, want := range []string{
		"window: 2025-01-10", // 12m before the seeded commit day, pin-derived
		"min-support 2, top 5",
		"accretion candidates",
		"UNSERVED", "reg.txt",
		"co-creation pairs",
		"*.ex + *_test.exs",
		"note: counts are FREQUENCY evidence",
	} {
		if !strings.Contains(stdout, want) {
			t.Errorf("table missing %q:\n%s", want, stdout)
		}
	}
}

func TestScaffyDiscoverJSONEnvelope(t *testing.T) {
	seedDiscoverCliRepo(t)
	code, stdout, stderr := runScaffyTest(t, globals{}, "json", "discover", "--min-support", "2")
	if code != exitOK {
		t.Fatalf("exit = %d\nstderr:\n%s", code, stderr)
	}
	var env struct {
		Ok     bool `json:"ok"`
		Window struct {
			Since    string `json:"since"`
			UntilDay string `json:"until_day"`
			NoMerges bool   `json:"no_merges"`
		} `json:"window"`
		MinSupport int `json:"min_support"`
		Accretion  []struct {
			Path    string `json:"path"`
			Commits int    `json:"commits"`
		} `json:"accretion"`
		CoCreation []any  `json:"co_creation"`
		Note       string `json:"note"`
	}
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("bad JSON: %v\n%s", err, stdout)
	}
	if !env.Ok || !env.Window.NoMerges || env.MinSupport != 2 {
		t.Errorf("envelope basics wrong: %+v", env)
	}
	if env.Window.Since != "2025-01-10" || env.Window.UntilDay != "2026-01-10" {
		t.Errorf("window = %+v, want 2025-01-10 → 2026-01-10", env.Window)
	}
	if len(env.Accretion) != 1 || env.Accretion[0].Path != "reg.txt" || env.Accretion[0].Commits != 3 {
		t.Errorf("accretion = %+v, want reg.txt with 3 commits", env.Accretion)
	}
	if len(env.CoCreation) == 0 || env.Note == "" {
		t.Errorf("envelope must carry co_creation rules and the note")
	}
}
