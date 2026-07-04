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

// -o yaml is a machine shape, not the human report: migrateError must emit the
// parseable `ok: false` envelope to stdout via emitStructured, NOT the human
// `bp:`-prefixed stderr line. This is the silent-downgrade the machineOut
// gate (json|yaml) fixes.
func TestMigrateErrorYAMLEmitsEnvelope(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "yaml"

	if code := migrateError(w, true, "config", "boom", exitGeneric); code != exitGeneric {
		t.Fatalf("exit = %d, want %d", code, exitGeneric)
	}
	got := stdout.String()
	if !strings.Contains(got, "ok: false") {
		t.Errorf("yaml stdout missing `ok: false`:\n%s", got)
	}
	if !strings.Contains(got, "code: config") {
		t.Errorf("yaml stdout missing `code: config`:\n%s", got)
	}
	if strings.Contains(stderr.String(), "bp:") {
		t.Errorf("yaml path leaked the human stderr line:\n%s", stderr.String())
	}
}

// Sibling json call proves the machineOut gate did not regress the original
// -o json path: emitStructured renders the same envelope as JSON braces.
func TestMigrateErrorJSONEmitsEnvelope(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "json"

	if code := migrateError(w, true, "config", "boom", exitGeneric); code != exitGeneric {
		t.Fatalf("exit = %d, want %d", code, exitGeneric)
	}
	got := stdout.String()
	if !strings.Contains(got, "{") || !strings.Contains(got, "\"ok\": false") {
		t.Errorf("json stdout missing braces / `\"ok\": false`:\n%s", got)
	}
	if strings.Contains(stderr.String(), "bp:") {
		t.Errorf("json path leaked the human stderr line:\n%s", stderr.String())
	}
}
