package cli

import (
	"bytes"
	"strings"
	"testing"
)

func TestRunCompletionBash(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	if code := runCompletion(w, []string{"bash"}); code != exitOK {
		t.Fatalf("exit = %d, want %d; stderr=%s", code, exitOK, stderr.String())
	}
	out := stdout.String()
	for _, want := range []string{"complete -F _bp_complete bp", "compgen", "doc", "schema", "--dataset"} {
		if !strings.Contains(out, want) {
			t.Errorf("bash completion missing %q:\n%s", want, out)
		}
	}
}

func TestRunCompletionZsh(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	if code := runCompletion(w, []string{"zsh"}); code != exitOK {
		t.Fatalf("exit = %d, want %d", code, exitOK)
	}
	out := stdout.String()
	for _, want := range []string{"#compdef bp", "compdef _bp_complete bp", "compadd", "task"} {
		if !strings.Contains(out, want) {
			t.Errorf("zsh completion missing %q:\n%s", want, out)
		}
	}
}

func TestRunCompletionDefaultsToBash(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	if code := runCompletion(w, nil); code != exitOK {
		t.Fatalf("exit = %d, want %d", code, exitOK)
	}
	if !strings.Contains(stdout.String(), "complete -F _bp_complete bp") {
		t.Errorf("no-arg completion should default to bash:\n%s", stdout.String())
	}
}

func TestRunCompletionUnknownShell(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	if code := runCompletion(w, []string{"fish"}); code != exitUsage {
		t.Errorf("unknown shell exit = %d, want %d (usage)", code, exitUsage)
	}
}
