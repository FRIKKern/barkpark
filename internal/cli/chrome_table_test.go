package cli

// chrome_table_test.go — S10 CLI table chrome: proves renderHzTable paints
// provider marks + lifecycle hues through the shared design tokens WITHOUT ever
// altering the color-off bytes.
//
//   • TestChromeTableColorGolden   — TrueColor+dark profile, color on → SGR
//     present on the PROVIDER + STATUS cells (frozen fixture).
//   • TestChromeTableAsciiGolden   — Ascii profile, color on → lipgloss strips
//     SGR (the degradation ladder), frozen fixture.
//   • TestChromeTableNoColorByteIdentity — color OFF (a pipe/--no-color): the
//     table is byte-for-byte the pre-chrome output and carries ZERO ANSI.
//   • TestChromeTableTintOnly       — color on: strip ANSI + rtrim ⇒ exactly the
//     plain layout; header + unknown values stay unpainted.
//   • TestTinterForHeader / TestProviderTint / TestLifecycleTint — the
//     header→column and value→colour vocabulary rules.

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/semrole"
	"github.com/charmbracelet/lipgloss"
	"github.com/muesli/termenv"
)

// chromeSampleHeaders/Rows exercise every branch: a painted provider
// (hetzner/azure), an unpainted provider (gcp), a painted lifecycle
// (live=ok, degraded=warn), a neutral-role lifecycle (stopped → unpainted), and
// an unrecognised status (a raw hcloud "running" → unpainted). NAME never paints.
var chromeSampleHeaders = []string{"NAME", "PROVIDER", "STATUS"}

func chromeSampleRows() [][]string {
	return [][]string{
		{"web-1", "hetzner", "live"},
		{"db-1", "azure", "degraded"},
		{"cache", "hetzner", "stopped"},
		{"legacy", "gcp", "running"},
	}
}

// The exact bytes the color-OFF path must produce — the byte-identity anchor
// (tint only; no glyphs, no invented column, no injected bytes).
const chromeTableNoColorWant = "NAME    PROVIDER  STATUS\n" +
	"web-1   hetzner   live\n" +
	"db-1    azure     degraded\n" +
	"cache   hetzner   stopped\n" +
	"legacy  gcp       running\n"

// renderChromeSample renders the sample table through the real renderHzTable at
// the given colour setting into a buffer and returns the bytes.
func renderChromeSample(color bool) string {
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr) // buffer → isTTY false → color false
	w.color = color
	renderHzTable(w, chromeSampleHeaders, chromeSampleRows())
	return stdout.String()
}

func chromeGolden(t *testing.T, name, got string) {
	t.Helper()
	path := filepath.Join("testdata", name)
	if *updateGolden { // shared -update flag (declared in cloud_cmd_test.go)
		if err := os.WriteFile(path, []byte(got), 0o644); err != nil {
			t.Fatalf("write golden: %v", err)
		}
		return
	}
	wantBytes, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read golden (run with -update): %v", err)
	}
	if want := string(wantBytes); got != want {
		t.Errorf("chrome table render diverged from %s\n--- got ---\n%q\n--- want ---\n%q", path, got, want)
	}
}

// TestChromeTableColorGolden pins TrueColor+dark so the AdaptiveColor tones
// resolve to deterministic truecolor SGR, then freezes the painted render.
func TestChromeTableColorGolden(t *testing.T) {
	oldProfile := lipgloss.ColorProfile()
	oldDark := lipgloss.HasDarkBackground()
	lipgloss.SetColorProfile(termenv.TrueColor)
	lipgloss.SetHasDarkBackground(true)
	t.Cleanup(func() {
		lipgloss.SetColorProfile(oldProfile)
		lipgloss.SetHasDarkBackground(oldDark)
	})
	got := renderChromeSample(true)
	if !strings.Contains(got, "\x1b[") {
		t.Fatal("TrueColor render carried no SGR — chrome did not paint")
	}
	chromeGolden(t, "chrome_table_color.txt", got)
}

// TestChromeTableAsciiGolden pins the Ascii profile: even with color ON, lipgloss
// strips SGR, proving the colour-degradation ladder. The fixture must be plain.
func TestChromeTableAsciiGolden(t *testing.T) {
	oldProfile := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.Ascii)
	t.Cleanup(func() { lipgloss.SetColorProfile(oldProfile) })
	got := renderChromeSample(true)
	if strings.Contains(got, "\x1b") {
		t.Fatalf("Ascii profile must strip all SGR; got:\n%q", got)
	}
	chromeGolden(t, "chrome_table_ascii.txt", got)
}

// TestChromeTableNoColorByteIdentity: with color off (a pipe / --no-color) the
// table is byte-for-byte the pre-chrome output and carries ZERO ANSI escapes —
// the HARD CONTRACT. Independent of the ambient lipgloss profile (color off
// never reaches lipgloss).
func TestChromeTableNoColorByteIdentity(t *testing.T) {
	got := renderChromeSample(false)
	if got != chromeTableNoColorWant {
		t.Fatalf("color-off table not byte-identical:\n--- got ---\n%q\n--- want ---\n%q", got, chromeTableNoColorWant)
	}
	if strings.Contains(got, "\x1b") {
		t.Fatalf("color-off output must contain NO ANSI escape; got:\n%q", got)
	}
}

// TestChromeTableTintOnly: with color ON the provider + lifecycle cells are
// painted and NOTHING else changes — strip the ANSI, right-trim, and the layout
// is exactly the color-off table. The header row is never painted; unknown
// values (gcp / running) stay unpainted.
func TestChromeTableTintOnly(t *testing.T) {
	oldProfile := lipgloss.ColorProfile()
	oldDark := lipgloss.HasDarkBackground()
	lipgloss.SetColorProfile(termenv.TrueColor)
	lipgloss.SetHasDarkBackground(true)
	t.Cleanup(func() {
		lipgloss.SetColorProfile(oldProfile)
		lipgloss.SetHasDarkBackground(oldDark)
	})
	got := renderChromeSample(true)

	// Header row must never be painted.
	if header := strings.SplitN(got, "\n", 2)[0]; strings.Contains(header, "\x1b") {
		t.Errorf("header row was painted:\n%q", header)
	}
	// Strip color + right-trim ⇒ identical visible layout to the color-off table.
	if gotStripped, wantStripped := rtrimLines(stripANSI(got)), rtrimLines(chromeTableNoColorWant); gotStripped != wantStripped {
		t.Fatalf("stripping color changed the layout:\n--- got ---\n%q\n--- want ---\n%q", gotStripped, wantStripped)
	}
	// The unknown provider + unknown status lines carry no SGR at all.
	for _, line := range strings.Split(got, "\n") {
		if strings.HasPrefix(line, "legacy") && strings.Contains(line, "\x1b") {
			t.Errorf("unknown provider/status line was painted:\n%q", line)
		}
	}
}

func TestTinterForHeader(t *testing.T) {
	paints := []string{"PROVIDER", "provider", " Provider ", "STATUS", "STATE", "LIFECYCLE", "status"}
	for _, h := range paints {
		if tinterForHeader(h) == nil {
			t.Errorf("tinterForHeader(%q) = nil, want a tinter", h)
		}
	}
	skips := []string{"NAME", "ID", "IPV4", "TYPE", "LOCATION", "", "SERVICES"}
	for _, h := range skips {
		if tinterForHeader(h) != nil {
			t.Errorf("tinterForHeader(%q) != nil, want no tinter", h)
		}
	}
}

func TestProviderTint(t *testing.T) {
	for _, in := range []string{"hetzner", "HETZNER", " azure "} {
		if _, ok := providerTint(in); !ok {
			t.Errorf("providerTint(%q) not ok, want a mark", in)
		}
	}
	for _, in := range []string{"gcp", "aws", "", "live"} {
		if _, ok := providerTint(in); ok {
			t.Errorf("providerTint(%q) ok, want unpainted", in)
		}
	}
	// Sanity: the mark colour is the generated token, read as a symbol.
	got, _ := providerTint("azure")
	if got != semrole.GenProviderMark["azure"] {
		t.Errorf("providerTint(azure) = %v, want GenProviderMark[azure]", got)
	}
}

func TestLifecycleTint(t *testing.T) {
	// Role-bearing states paint through their role hue.
	roleStates := map[string]string{
		"live":           "ok",
		"degraded":       "warn",
		"provisioning":   "info",
		"decommissioned": "danger",
		"adopted":        "info",
	}
	for state, role := range roleStates {
		got, ok := lifecycleTint(state)
		if !ok {
			t.Errorf("lifecycleTint(%q) not ok, want painted", state)
			continue
		}
		want, _ := semrole.RoleColor(role)
		if got != want {
			t.Errorf("lifecycleTint(%q) = %v, want RoleColor(%q)=%v", state, got, role, want)
		}
	}
	// Neutral-role states + unknown statuses pass through unpainted.
	for _, in := range []string{"stopped", "archived", "running", "off", "", "hetzner"} {
		if _, ok := lifecycleTint(in); ok {
			t.Errorf("lifecycleTint(%q) ok, want unpainted", in)
		}
	}
}
