package taskboard

import (
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"github.com/muesli/termenv"
)

// TestHeaderStyledTruncateKeepsContent forces a truecolor profile (tests run
// without a TTY, so lipgloss otherwise emits no ANSI and hides the bug) and
// proves that clipping a long styled header keeps the visible content instead
// of letting SGR parameter bytes eat the width budget. Before the ANSI-aware
// truncate, this exact case rendered "⎇ …" — the whole branch destroyed.
func TestHeaderStyledTruncateKeepsContent(t *testing.T) {
	oldp := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() { lipgloss.SetColorProfile(oldp) })

	old := Chrome
	Chrome = ChromeInfo{
		RepoName: "barkpark-very-long-repo-name",
		Branch:   "loop-epic/theme-component-kit-portrait-renderer-wi-1",
		Server:   "guerrilla.barkpark.cloud",
	}
	t.Cleanup(func() { Chrome = old })

	b := loadBoardFixture(t)
	frame := Render(b, fixtureUIState(), 60, 40, fixedNow)
	line1 := strings.Split(frame, "\n")[0]
	stripped := ansi.Strip(line1)

	if w := ansi.StringWidth(line1); w > 60 {
		t.Errorf("styled header is %d cols (over 60): %q", w, stripped)
	}
	// The header dropped the branch chrome (wish Amendment 3): line 1 is now
	// "barkpark · tasks … ⇄ <server> ● live". The styled truncation must keep the
	// left title and the honest conn state, never let SGR bytes eat the content.
	if !strings.Contains(stripped, "tasks") {
		t.Errorf("header title lost to escape-byte truncation: %q", stripped)
	}
	if !strings.Contains(stripped, "live") {
		t.Errorf("conn state lost: %q", stripped)
	}
}

// The scaled-bar (Meter) honesty test was retired with Meter itself — the
// navigation-shell wave deleted the ▰▱ meter (charter D14/D31); the detail frame
// renders criteria as a ○/✓ checklist, not a bar.
