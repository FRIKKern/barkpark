package cli

import (
	"bytes"
	"regexp"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/pdrender"
	"github.com/FRIKKern/barkpark/internal/semrole"

	"github.com/charmbracelet/lipgloss"
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
		"behind": "info",
		// "inactive" is the webhook list's manually-switched-off state (the data
		// model's own word for active:false) — attention-worthy, not a fault;
		// "suspended" stays reserved for the system-imposed instance state.
		"degraded": "warn", "unknown": "warn", "suspended": "warn", "inactive": "warn",
		"failed": "danger", "error": "danger", "offline": "danger", "removal_failed": "danger",
		// Usage-meter quota states (bp cloud usage STATE cell): near_limit warns as
		// a meter approaches its plan ceiling, over_limit is danger at/past it.
		"near_limit": "warn", "over_limit": "danger",
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

// coloredWriter builds a color-ON writer whose paint ladder is pinned to profile p
// (and a fixed background so AdaptiveColor light/dark selection is deterministic),
// bypassing tty auto-detection — the buffer sinks make isatty report false.
func coloredWriter(stdout, stderr *bytes.Buffer, p pdrender.Profile, dark bool) *writer {
	w := newWriter(stdout, stderr)
	w.color = true
	w.isTTY = true
	w.colorProfile = p
	r := lipgloss.NewRenderer(stdout)
	r.SetColorProfile(paperTermenvProfile(p))
	r.SetHasDarkBackground(dark)
	w.renderer = r
	return w
}

// TestPaintCellANSI16Floor pins the basic-16 floor: role-keyed semrole.GenANSI16
// SGR, with the DELIBERATE info cyan(36)→blue(34) retint (the cross-surface
// coherence fix), and lifecycle states degrading to their status role (done→ok→32).
func TestPaintCellANSI16Floor(t *testing.T) {
	var so, se bytes.Buffer
	w := coloredWriter(&so, &se, pdrender.ANSI16, true)
	cases := map[string]string{
		"live":      "\033[32m", // ok → green
		"failed":    "\033[31m", // danger → red
		"suspended": "\033[33m", // warn → yellow
		"building":  "\033[34m", // info → BLUE (was cyan 36 before the retint)
		"done":      "\033[32m", // lifecycle teal degrades to ok/green at the 16 floor
	}
	for token, want := range cases {
		got := w.paintCell(token, token)
		if !strings.HasPrefix(got, want) || !strings.HasSuffix(got, ansiReset) {
			t.Errorf("paintCell(%q) = %q, want prefix %q + reset", token, got, want)
		}
	}
	// The deliberate retint: info is NEVER the old cyan 36 at the floor.
	if strings.Contains(w.paintCell("building", "building"), "\033[36m") {
		t.Error("info still paints cyan 36 at the 16 floor; must be blue 34")
	}
	// Unknown token → unpainted, no escapes.
	if got := w.paintCell("banana", "banana"); got != "banana" {
		t.Errorf("unknown token painted: %q", got)
	}
}

// TestPaintCellLifecycleTealTrueColor proves the headline Decision-4 behaviour: a
// `done` cell routes to its LIFECYCLE teal hue, NOT the ok status green tone, and
// `in_progress` to its token blue — all as 24-bit SGR. Compared against the SAME
// lipgloss pipeline (not literal RGB) so termenv's hex round-trip can't flake it;
// the load-bearing claim is teal != green AND done == teal.
func TestPaintCellLifecycleTealTrueColor(t *testing.T) {
	var so, se bytes.Buffer
	w := coloredWriter(&so, &se, pdrender.TrueColor, true) // dark → the Dark hex side
	done := w.paintCell("done", "done")

	doneHue, _ := semrole.LifecycleColor("done")
	okTone, _ := semrole.RoleColor("ok")
	wantTeal := w.cellStyler().Foreground(doneHue).Render("done")
	wantGreen := w.cellStyler().Foreground(okTone).Render("done")

	if done != wantTeal {
		t.Errorf("done did not paint the lifecycle teal hue:\n got %q\nwant %q", done, wantTeal)
	}
	if done == wantGreen {
		t.Errorf("done painted the ok status green instead of lifecycle teal: %q", done)
	}
	if !strings.Contains(done, "\x1b[38;2;") {
		t.Errorf("truecolor profile did not emit 24-bit SGR: %q", done)
	}

	ip := w.paintCell("in_progress", "in_progress")
	ipHue, _ := semrole.LifecycleColor("in_progress")
	if want := w.cellStyler().Foreground(ipHue).Render("in_progress"); ip != want {
		t.Errorf("in_progress did not paint its token blue hue:\n got %q\nwant %q", ip, want)
	}
}

// TestPaintCellANSI256Downsample proves the middle rung is 8-bit indexed SGR
// (termenv's 24-bit→256 downsample), never 24-bit truecolor.
func TestPaintCellANSI256Downsample(t *testing.T) {
	var so, se bytes.Buffer
	w := coloredWriter(&so, &se, pdrender.ANSI256, true)
	got := w.paintCell("failed", "failed")
	if !strings.Contains(got, "\x1b[38;5;") {
		t.Errorf("ANSI256 profile did not emit 8-bit indexed SGR: %q", got)
	}
	if strings.Contains(got, "38;2;") {
		t.Errorf("ANSI256 leaked 24-bit truecolor SGR: %q", got)
	}
}

// TestBPColorEnvHatch pins the BP_COLOR escape hatch onto the paper --profile alias
// vocabulary, and that NO_COLOR still wins over it.
func TestBPColorEnvHatch(t *testing.T) {
	build := func() *writer {
		var so, se bytes.Buffer
		w := newWriter(&so, &se)
		w.color = true
		w.isTTY = true
		return w
	}
	t.Run("truecolor", func(t *testing.T) {
		t.Setenv("BP_COLOR", "truecolor")
		w := build()
		w.resolveColorProfile()
		if w.colorProfile != pdrender.TrueColor {
			t.Fatalf("BP_COLOR=truecolor → %v, want TrueColor", w.colorProfile)
		}
	})
	t.Run("16", func(t *testing.T) {
		t.Setenv("BP_COLOR", "16")
		w := build()
		w.resolveColorProfile()
		if w.colorProfile != pdrender.ANSI16 {
			t.Fatalf("BP_COLOR=16 → %v, want ANSI16", w.colorProfile)
		}
	})
	t.Run("none disables colour", func(t *testing.T) {
		t.Setenv("BP_COLOR", "none")
		w := build()
		w.resolveColorProfile()
		if w.color {
			t.Fatal("BP_COLOR=none must disable colour")
		}
	})
	t.Run("empty falls through to auto tty → 256", func(t *testing.T) {
		t.Setenv("BP_COLOR", "")
		w := build()
		w.resolveColorProfile()
		if w.colorProfile != pdrender.ANSI256 {
			t.Fatalf("auto over a tty → %v, want ANSI256 (safe)", w.colorProfile)
		}
	})
	t.Run("NO_COLOR beats BP_COLOR", func(t *testing.T) {
		t.Setenv("NO_COLOR", "1")
		t.Setenv("BP_COLOR", "truecolor")
		var so, se bytes.Buffer
		w := newWriter(&so, &se)
		w.color = true
		w.isTTY = true
		w.applyGlobals(globals{}) // noColorEnv() forces colour off; resolveColorProfile early-returns
		if w.color {
			t.Fatal("NO_COLOR must beat BP_COLOR=truecolor")
		}
		if w.colorProfile != pdrender.NoColor {
			t.Fatalf("NO_COLOR left colorProfile = %v, want NoColor", w.colorProfile)
		}
	})
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
// role — green for "live", red for "failed" — and NOTHING else changes: strip the
// ANSI and right-trim and the layout is exactly the color-off table. Header and
// non-status cells stay unpainted. Pinned to the ANSI16 floor so the SGR bytes are
// the deterministic semrole.GenANSI16 codes (32/31), not a background-dependent
// truecolor render.
func TestRenderTableColorInjectsAnsi(t *testing.T) {
	var stdout, stderr bytes.Buffer
	w := coloredWriter(&stdout, &stderr, pdrender.ANSI16, true)
	w.output = "table"
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
