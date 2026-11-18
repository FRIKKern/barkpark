package cli

// The check command an ambiguous create prints is pasted into a shell
// (task-5985afa7b6e7454f). It quoted the title with Go's %q, which is a
// double-quoted string to a shell: `$HOME` expanded and a backtick ran a
// command, so the search looked for a different title, or ran something.

import (
	"os/exec"
	"strings"
	"testing"
)

// shellWords is the argv a POSIX shell builds from s.
func shellWords(t *testing.T, s string) []string {
	t.Helper()
	out, err := exec.Command("sh", "-c", `for a in `+s+`; do printf '%s\0' "$a"; done`).Output()
	if err != nil {
		t.Fatalf("sh could not read %q: %v", s, err)
	}
	words := strings.Split(string(out), "\x00")
	return words[:len(words)-1]
}

func TestTaskCreateAmbiguousHintIsShellSafe(t *testing.T) {
	for _, title := range []string{
		"Costs $HOME and `echo INJECTED` in one title",
		`A title with 'single' and "double" quotes and a \ backslash`,
		"plain",
	} {
		check := ambiguousWrite{title: title}.checkCommand()
		rest, ok := strings.CutPrefix(check, "bp search query ")
		if !ok {
			t.Fatalf("check command %q is not a bp search query", check)
		}
		got := shellWords(t, rest)
		want := []string{title, "--perspective", "drafts"}
		if strings.Join(got, "\x00") != strings.Join(want, "\x00") {
			t.Errorf("pasted into a shell, %q gives argv %q, want %q", check, got, want)
		}
	}
}
