package cli

import (
	"bytes"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// A bytes.Buffer stdout is never a TTY, so `bp tasks` must refuse to launch the
// full-screen program and instead point at the scriptable `bp task …` verbs.
func TestTasksBoardRequiresTTY(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)

	code := runTasksBoard(w, globals{}, manifest.Context{Server: "http://localhost:4000"}, nil)
	if code != exitGeneric {
		t.Fatalf("exit code = %d, want %d (non-TTY)", code, exitGeneric)
	}
	if !strings.Contains(stderr.String(), "needs a terminal") {
		t.Fatalf("stderr missing the terminal-gate message: %q", stderr.String())
	}
	if !strings.Contains(stderr.String(), "bp task") {
		t.Fatalf("terminal-gate message should cross-reference `bp task …`: %q", stderr.String())
	}
	// It must NOT have tried to open the program (no stdout escape spew).
	if stdout.Len() != 0 {
		t.Fatalf("non-TTY run wrote to stdout: %q", stdout.String())
	}
}

// -h prints the help block (before any TTY check) and cross-references the
// singular `bp task …` verbs so neither entry point is a dead end.
func TestTasksBoardHelp(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)

	code := runTasksBoard(w, globals{help: true}, manifest.Context{}, nil)
	if code != exitOK {
		t.Fatalf("help exit code = %d, want %d", code, exitOK)
	}
	out := stdout.String()
	if !strings.Contains(out, "usage: bp tasks") {
		t.Fatalf("help missing usage line: %q", out)
	}
	if !strings.Contains(out, "bp task") {
		t.Fatalf("help should cross-reference `bp task …`: %q", out)
	}
	// The footer advertises c/x/o; the help must document them so they are not a
	// dead promise.
	for _, want := range []string{"claim", "close", "Studio"} {
		if !strings.Contains(out, want) {
			t.Fatalf("help missing the %q act-verb key: %q", want, out)
		}
	}
}

// A stray positional (a `bp task` verb typo) is rejected with a helpful
// cross-reference, not silently ignored.
func TestTasksBoardRejectsArgs(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)

	code := runTasksBoard(w, globals{}, manifest.Context{}, []string{"ready"})
	if code != exitUsage {
		t.Fatalf("stray-arg exit code = %d, want %d", code, exitUsage)
	}
	if !strings.Contains(stderr.String(), "bp task ready") {
		t.Fatalf("stray-arg error should suggest `bp task ready`: %q", stderr.String())
	}
}
