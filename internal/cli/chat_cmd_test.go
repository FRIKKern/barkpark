package cli

import (
	"bytes"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// A bytes.Buffer stdout is never a TTY, so `bp chat` must refuse to launch the
// full-screen program rather than scribble escape codes into a pipe.
func TestChatRequiresTTY(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)

	code := runChat(w, globals{}, manifest.Context{Server: "http://localhost:4000"}, nil)
	if code != exitGeneric {
		t.Fatalf("exit code = %d, want %d (non-TTY)", code, exitGeneric)
	}
	if !strings.Contains(stderr.String(), "needs a terminal") {
		t.Fatalf("stderr missing the terminal-gate message: %q", stderr.String())
	}
	if stdout.Len() != 0 {
		t.Fatalf("non-TTY run wrote to stdout: %q", stdout.String())
	}
}

// -h prints the help block before any TTY check.
func TestChatHelp(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)

	code := runChat(w, globals{help: true}, manifest.Context{}, nil)
	if code != exitOK {
		t.Fatalf("help exit code = %d, want %d", code, exitOK)
	}
	out := stdout.String()
	if !strings.Contains(out, "usage: bp chat") {
		t.Fatalf("help missing usage line: %q", out)
	}
	for _, want := range []string{"esc", "interrupt", "new session", "quit"} {
		if !strings.Contains(out, want) {
			t.Fatalf("help missing %q: %q", want, out)
		}
	}
}

// A stray positional is rejected, not silently ignored.
func TestChatRejectsArgs(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)

	code := runChat(w, globals{}, manifest.Context{}, []string{"resume"})
	if code != exitUsage {
		t.Fatalf("stray-arg exit code = %d, want %d", code, exitUsage)
	}
	if !strings.Contains(stderr.String(), "takes no arguments") {
		t.Fatalf("stray-arg error should explain: %q", stderr.String())
	}
}
