package cli

import (
	"bytes"
	"regexp"
	"strings"
	"testing"
)

// ansiRe matches an SGR color escape so the byte-identity tests can strip color
// back out and compare the visible layout.
var ansiRe = regexp.MustCompile("\x1b\\[[0-9;]*m")

func stripANSI(s string) string { return ansiRe.ReplaceAllString(s, "") }

// rtrimLines right-trims every line so a color span's trailing padding spaces
// (which ride INSIDE the color, past joinCols' TrimRight) don't count as a
// visible-layout difference.
func rtrimLines(s string) string {
	lines := strings.Split(s, "\n")
	for i := range lines {
		lines[i] = strings.TrimRight(lines[i], " ")
	}
	return strings.Join(lines, "\n")
}

// TestStatusRoleMapping pins the charter-decision-12 value→role table, including
// the "unknown-string → no role" rule and case-insensitivity.
func TestStatusRoleMapping(t *testing.T) {
	cases := map[string]string{
		"live": "ok", "up": "ok", "online": "ok", "ok": "ok", "OK": "ok", " Live ": "ok",
		"queued": "info", "building": "info", "pushing": "info", "provisioning": "info",
		"pending": "info", "removing": "info",
		// "behind" is info, not warn — the decision-32 fixture pins its tone
		// ("update available" is news, not an alarm);
		// TestAttentionVocabularyMatchesFixture cross-checks the committed file.
		"behind":   "info",
		// "inactive" is the webhook list's manually-switched-off state (the data
		// model's own word for active:false) — attention-worthy, not a fault;
		// "suspended" stays reserved for the system-imposed instance state.
		"degraded": "warn", "unknown": "warn", "suspended": "warn", "inactive": "warn",
		"failed": "danger", "error": "danger", "offline": "danger", "removal_failed": "danger",
		// Unknown strings get NO role (never a guess).
		"":                    "",
		"banana":              "",
		"42":                  "",
		"a title with spaces": "",
	}
	for in, want := range cases {
		if got := statusRole(in); got != want {
			t.Errorf("statusRole(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestAnsiForRole(t *testing.T) {
	cases := map[string]string{
		"ok": "\x1b[32m", "info": "\x1b[36m", "warn": "\x1b[33m", "danger": "\x1b[31m",
		"": "", "nope": "",
	}
	for role, want := range cases {
		if got := ansiForRole(role); got != want {
			t.Errorf("ansiForRole(%q) = %q, want %q", role, got, want)
		}
	}
}

const statusTablePayload = `{"documents":[{"id":"1","title":"A","status":"live"},{"id":"2","title":"B","status":"failed"}]}`

// The exact bytes the color-OFF path must produce — the byte-identity anchor
// (charter decision 12: piped / --no-color output stays identical to today).
const statusTableWant = "id  title  status\n" +
	"--  -----  ------\n" +
	"1   A      live\n" +
	"2   B      failed\n"

// TestRenderTableNoColorByteIdentity: with color off (a pipe / --no-color) the
// table is byte-for-byte the pre-color output and carries ZERO ANSI escapes.
func TestRenderTableNoColorByteIdentity(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr) // buffer → isTTY false → color false
	w.output = "table"
	if w.color {
		t.Fatal("buffer writer should default to color OFF")
	}
	renderTable(w, []byte(statusTablePayload))
	got := stdout.String()
	if got != statusTableWant {
		t.Fatalf("color-off table not byte-identical:\n--- got ---\n%q\n--- want ---\n%q", got, statusTableWant)
	}
	if strings.Contains(got, "\x1b") {
		t.Fatalf("color-off output must contain NO ANSI escape; got:\n%q", got)
	}
}

// TestRenderTableColorInjectsAnsi: with color ON the status cells are painted by
// role — green for "live", red for "failed" — and NOTHING else changes: strip
// the ANSI and right-trim and the layout is exactly the color-off table. Header
// and non-status cells stay unpainted.
func TestRenderTableColorInjectsAnsi(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "table"
	w.color = true
	renderTable(w, []byte(statusTablePayload))
	got := stdout.String()

	if !strings.Contains(got, "\x1b[32m"+"live") {
		t.Errorf("expected green-painted 'live' (\\x1b[32m); got:\n%q", got)
	}
	if !strings.Contains(got, "\x1b[31m"+"failed"+"\x1b[0m") {
		t.Errorf("expected red-painted 'failed' with reset; got:\n%q", got)
	}
	// The header row must never be painted.
	if strings.Contains(strings.SplitN(got, "\n", 2)[0], "\x1b") {
		t.Errorf("header row was painted:\n%q", got)
	}
	// Strip color + right-trim → identical visible layout to the color-off table.
	if gotStripped, wantStripped := rtrimLines(stripANSI(got)), rtrimLines(statusTableWant); gotStripped != wantStripped {
		t.Fatalf("stripping color changed the layout:\n--- got ---\n%q\n--- want ---\n%q", gotStripped, wantStripped)
	}
}

// TestNoColorFlagIsByteIdentical proves the --no-color global (g.noColor) forces
// the color-off bytes even on a would-be-color writer.
func TestNoColorFlagIsByteIdentical(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.color = true // pretend a tty…
	w.applyGlobals(globals{noColor: true, output: "table", outputSet: true})
	w.output = "table"
	renderTable(w, []byte(statusTablePayload))
	if got := stdout.String(); got != statusTableWant || strings.Contains(got, "\x1b") {
		t.Fatalf("--no-color must yield the plain bytes; got:\n%q", got)
	}
}
