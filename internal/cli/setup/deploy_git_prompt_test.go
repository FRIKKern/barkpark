package setup

// task-466aef17f2085404: deploy.sh runs unattended over ssh with no tty. A git
// network call that wants a username must FAIL LOUDLY, never wait on a prompt.
// Two locks: (1) every clone/pull/fetch in the rendered script goes through
// bp_git under GIT_TERMINAL_PROMPT=0 — a fifth call added bare reds here; (2) the
// bp_git arm itself, driven by a fake git that fails the way git 2.34 does
// against GitHub (task-8a523f080fa406d2), names the call and the likely cause.

import (
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cli/setup/assets"
)

// A call may open a line or follow `&&`/`;` (`cd "$APP_DIR" && bp_git pull`).
// Lines that are comments or `echo` advice text are not calls.
var gitNetworkCall = regexp.MustCompile(`(?:^|&&|;)\s*(bp_git|git)\s+(clone|pull|fetch)\b`)

func gitNetworkCalls(script string) [][]string {
	var calls [][]string
	for _, line := range strings.Split(script, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "#") || strings.HasPrefix(trimmed, "echo ") {
			continue
		}
		calls = append(calls, gitNetworkCall.FindAllStringSubmatch(trimmed, -1)...)
	}
	return calls
}

func TestDeployScriptGitNetworkCallsCannotPrompt(t *testing.T) {
	script := string(assets.DeployScript)
	if !strings.Contains(script, "export GIT_TERMINAL_PROMPT=0") {
		t.Fatalf("deploy.sh no longer exports GIT_TERMINAL_PROMPT=0 — a git that wants a username will hang the unattended provision")
	}
	calls := gitNetworkCalls(script)
	if len(calls) < 3 {
		t.Fatalf("positive control: expected at least the 3 known git network calls in deploy.sh (asdf clone, repo pull, repo clone), the scan found %d — the scan is blind", len(calls))
	}
	for _, c := range calls {
		if c[1] != "bp_git" {
			t.Errorf("a bare `git %s` in deploy.sh bypasses bp_git and would die as a bare exit: %q", c[2], strings.TrimSpace(c[0]))
		}
	}
}

func TestDeployScriptBpGitNamesTheFailure(t *testing.T) {
	script := string(assets.DeployScript)
	begin, end := strings.Index(script, "# bp_git BEGIN"), strings.Index(script, "# bp_git END")
	if begin < 0 || end < begin {
		t.Fatalf("bp_git markers missing from deploy.sh")
	}
	fn := script[begin:end]
	dir := t.TempDir()
	fake := filepath.Join(dir, "git")
	fakeBody := "#!/bin/sh\n" +
		"[ -n \"$GIT_TERMINAL_PROMPT\" ] && [ \"$GIT_TERMINAL_PROMPT\" = 0 ] || { echo 'fake git: GIT_TERMINAL_PROMPT not 0' >&2; exit 99; }\n" +
		"echo \"fatal: could not read Username for 'https://github.com': No such device or address\" >&2\n" +
		"exit 128\n"
	if err := os.WriteFile(fake, []byte(fakeBody), 0o755); err != nil {
		t.Fatal(err)
	}
	harness := "set -uo pipefail\nexport GIT_TERMINAL_PROMPT=0\n" + fn + "\nbp_git clone https://github.com/example/private.git /tmp/x\n"
	cmd := exec.Command("bash", "-c", harness)
	cmd.Env = append(os.Environ(), "PATH="+dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	out, err := cmd.CombinedOutput()
	if err == nil {
		t.Fatalf("bp_git returned 0 on a failing git; output: %s", out)
	}
	for _, want := range []string{"git clone failed", "credentials", "could not read Username"} {
		if !strings.Contains(string(out), want) {
			t.Errorf("bp_git failure output lacks %q:\n%s", want, out)
		}
	}
}
