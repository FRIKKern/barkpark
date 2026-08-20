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
	if !strings.Contains(out, "bp task tui") {
		t.Fatalf("help missing the singular-noun TUI alias: %q", out)
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

	// Wave-16 shipped full mouse support; the help must teach the SAME concise
	// grammar as the live footer. Each phrase below is one advertised gesture —
	// deleting any one of them from printTasksBoardHelp fails here, so the help
	// cannot silently drift back to keys-only or drop a gesture (mutation-proof).
	for _, gesture := range []string{
		"mouse",                             // the block exists at all
		"wheel",                             // wheel scrolls the pane under the pointer
		"free-scroll",                       // reading-frame wheel semantics
		"preview scrolls",                   // depth-0 preview wheel semantics
		"click",                             // click selects
		"click again",                       // click-on-selected activates
		"same as enter",                     // Enter equivalence
		"double-click",                      // double-click == two presses, no separate path
		"M ",                                // M toggles mouse capture
		"toggle mouse",                      // …capture on/off
		"opt/shift-click",                   // native-terminal text-selection bypass
		"text selection",                    // …what opt/shift-click reaches
		`opt/shift-click selects · M mouse`, // exact live-footer vocabulary
	} {
		if !strings.Contains(out, gesture) {
			t.Fatalf("help missing the shipped mouse gesture %q: %q", gesture, out)
		}
	}

	// The wide split is X-threshold PANE routing — there are no draggable
	// dividers, no resizable or column-local scroll gestures (grep-proven never
	// shipped). Help must never advertise those false premises.
	for _, phantom := range []string{"divider", "resize", "drag the"} {
		if strings.Contains(out, phantom) {
			t.Fatalf("help advertises a never-shipped gesture %q: %q", phantom, out)
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
