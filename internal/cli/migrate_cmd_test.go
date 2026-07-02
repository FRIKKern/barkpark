package cli

import (
	"bytes"
	"strings"
	"testing"
)

// `bp migrate --help` must print usage to stdout and exit 0 — parseGlobals
// consumes --help into g.help, so runMigrate has to honor it instead of falling
// through to the "needs <from> and <to>" argument error (exit 2 on stderr).
func TestRunMigrateHelpPrintsUsageAndExitsZero(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)

	code := runMigrate(w, globals{help: true}, nil)

	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK (%d)", code, exitOK)
	}
	if !strings.Contains(stdout.String(), "usage: bp migrate") {
		t.Errorf("usage should go to stdout; stdout=%q", stdout.String())
	}
	if stderr.Len() != 0 {
		t.Errorf("--help must not write to stderr; stderr=%q", stderr.String())
	}
	if strings.Contains(stdout.String(), "needs <from> and <to>") {
		t.Errorf("--help must not emit the argument error; stdout=%q", stdout.String())
	}
}

// The error path (missing servers, no --help) still goes to stderr with a
// non-zero exit — the help refactor must not have flipped that.
func TestRunMigrateMissingArgsErrorsToStderr(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)

	code := runMigrate(w, globals{}, nil)

	if code == exitOK {
		t.Fatalf("missing <from>/<to> should be a non-zero exit, got exitOK")
	}
	if !strings.Contains(stderr.String(), "needs <from> and <to>") {
		t.Errorf("arg error should go to stderr; stderr=%q", stderr.String())
	}
}
