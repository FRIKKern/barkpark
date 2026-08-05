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
	if !strings.Contains(got, "{") || !strings.Contains(got, "\"ok\":false") {
		t.Errorf("json stdout missing braces / `\"ok\":false`:\n%s", got)
	}
	if strings.Contains(stderr.String(), "bp:") {
		t.Errorf("json path leaked the human stderr line:\n%s", stderr.String())
	}
}

// ── PDS wave 48 — the receipt's CHECKMARK must descend from the count too ───
//
// The success-claim registry pins that `written` VARIES with the server's
// response; it cannot pin the checkmark, because both halves of its pair vary
// and so both would still differ if the ✓ were printed unconditionally
// (measured: forcing the short-write branch off leaves the registry green).
//
// The ✓ is the part a human reads. A short write wearing one is the same lie
// the count fix removed, one glyph out — so it gets its own falsifier here:
// the checkmark is legal ONLY when the server confirmed everything sent.
func TestMigrateTypeReceiptDropsTheCheckmarkOnAShortWrite(t *testing.T) {
	full := migrateTypeReceipt("post", 2, 2)
	if !strings.Contains(full, "✓") {
		t.Errorf("a fully-confirmed write must keep the checkmark:\n%s", full)
	}

	short := migrateTypeReceipt("post", 1, 2)
	if strings.Contains(short, "✓") {
		t.Errorf("a SHORT write must not wear a checkmark — the server confirmed 1 of 2:\n%s", short)
	}
	if !strings.Contains(short, "!") {
		t.Errorf("a short write must be marked, not merely counted:\n%s", short)
	}
	// And it must SAY what went unconfirmed, not just drop a glyph a reader
	// might not notice is missing.
	for _, want := range []string{"1/2", "confirmed 1 write results", "2 documents sent"} {
		if !strings.Contains(short, want) {
			t.Errorf("the short-write line must contain %q:\n%s", want, short)
		}
	}

	// The over-count direction too: a server confirming MORE than we sent is
	// also a disagreement, and must not print as a clean success.
	over := migrateTypeReceipt("post", 3, 2)
	if strings.Contains(over, "✓") {
		t.Errorf("a server confirming more writes than documents sent is not a clean ✓:\n%s", over)
	}
}
