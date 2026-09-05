package cloud

// task-466aef17f2085404: freshenCheckScript runs on the box with no tty. The
// fetch must run under GIT_TERMINAL_PROMPT=0 and a failure must NAME itself
// (FRESHEN_CHECK_FAILED + likely cause), never surface as a bare `set -e` exit
// after burning the 90 s timeout on a prompt nobody can answer.

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestFreshenCheckScriptCannotPrompt(t *testing.T) {
	if !strings.Contains(freshenCheckScript, "export GIT_TERMINAL_PROMPT=0") {
		t.Fatalf("freshenCheckScript no longer exports GIT_TERMINAL_PROMPT=0")
	}
	if !strings.Contains(freshenCheckScript, "FRESHEN_CHECK_FAILED") {
		t.Fatalf("freshenCheckScript has no named failure arm around the fetch")
	}
}

func TestFreshenCheckScriptNamesAFetchFailure(t *testing.T) {
	dir := t.TempDir()
	repo := filepath.Join(dir, "repo")
	if err := os.MkdirAll(repo, 0o755); err != nil {
		t.Fatal(err)
	}
	write := func(name, body string) {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	// git 2.34 against GitHub over protocol v2 (task-8a523f080fa406d2), and a
	// coreutils-shaped `timeout` shim so the script runs on a box without one.
	write("git", "#!/bin/sh\n"+
		"[ \"${GIT_TERMINAL_PROMPT:-}\" = 0 ] || { echo 'fake git: GIT_TERMINAL_PROMPT not 0' >&2; exit 99; }\n"+
		"echo \"fatal: could not read Username for 'https://github.com': No such device or address\" >&2\nexit 128\n")
	write("timeout", "#!/bin/sh\nshift\nexec \"$@\"\n")
	script := strings.Replace(freshenCheckScript, "cd "+freshenRepoDir, "cd "+repo, 1)
	cmd := exec.Command("bash", "-c", script)
	cmd.Env = append(os.Environ(), "PATH="+dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	out, err := cmd.CombinedOutput()
	if err == nil {
		t.Fatalf("check script exited 0 on a failing fetch; output: %s", out)
	}
	for _, want := range []string{"FRESHEN_CHECK_FAILED", "credentials", "could not read Username"} {
		if !strings.Contains(string(out), want) {
			t.Errorf("failure output lacks %q:\n%s", want, out)
		}
	}
	if strings.Contains(string(out), "FRESHEN_HEAD=") {
		t.Errorf("the script kept going after a failed fetch and printed a stale comparison:\n%s", out)
	}
}
