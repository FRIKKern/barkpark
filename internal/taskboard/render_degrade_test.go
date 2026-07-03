package taskboard

import (
	"strings"
	"testing"
	"time"

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
	if !strings.Contains(stripped, "loop-epic/theme") {
		t.Errorf("branch text lost to escape-byte truncation: %q", stripped)
	}
	if !strings.Contains(stripped, "live") {
		t.Errorf("conn state lost: %q", stripped)
	}
}

// TestManyClaimsKeepHeightContract proves the pinned NOW band degrades
// (separators dropped, then cards folded to "+N more claimed") instead of
// pushing the spine/ticker/footer off the pane — 6+ concurrent claims is the
// NORM when a builder swarm is running.
func TestManyClaimsKeepHeightContract(t *testing.T) {
	b := loadBoardFixture(t)
	for i := 0; i < 8; i++ {
		c := b.Now[0]
		c.DocID = c.DocID + strings.Repeat("x", i+1)
		b.Now = append(b.Now, c)
	}
	frame := plainFrame(b, fixtureUIState(), 80, 30)
	lines := strings.Split(frame, "\n")
	if len(lines) != 30 {
		t.Fatalf("frame is %d lines, want exactly 30", len(lines))
	}
	if !strings.Contains(lines[len(lines)-1], "jk move") {
		t.Errorf("footer not pinned: %q", lines[len(lines)-1])
	}
	if !strings.Contains(frame, "more claimed") {
		t.Errorf("folded claims must be honestly counted:\n%s", frame)
	}
}

// TestNowBreadcrumbResolvesDormantEpic proves a claimed task whose epic is
// dormant (children folded away, so it is absent from the visible spine)
// still gets its epic breadcrumb on the NOW card via ParentID resolution.
func TestNowBreadcrumbResolvesDormantEpic(t *testing.T) {
	b := loadBoardFixture(t)
	b.Now = append(b.Now, Task{
		DocID: "under-dormant", Title: "Reindex the media store",
		Lifecycle: "in_progress", ParentID: "search-media-epic",
		Claim: &Claim{Worker: "opus-9", ClaimedAt: fixedNow.Add(-time.Minute)},
	})
	frame := plainFrame(b, fixtureUIState(), 80, 50)
	idx := strings.Index(frame, "Reindex the media store")
	if idx < 0 {
		t.Fatalf("NOW card missing:\n%s", frame)
	}
	line2 := strings.Split(frame[idx:], "\n")[1]
	if !strings.Contains(line2, "Search & Media epic") {
		t.Errorf("breadcrumb missing for dormant-epic claim: %q", line2)
	}
}

// TestBarsNeverLieAtTheEdges pins the scaled-bar honesty clamp: progress > 0
// never renders an empty bar, and unfinished work never renders a full one.
func TestBarsNeverLieAtTheEdges(t *testing.T) {
	if got := Meter(&Criteria{Met: 1, Total: 20}); strings.HasPrefix(got, "▱") {
		t.Errorf("1/20 must show at least one filled cell: %q", got)
	}
	if got := Meter(&Criteria{Met: 19, Total: 20}); !strings.Contains(got, "▱") {
		t.Errorf("19/20 must keep one unfilled cell: %q", got)
	}
	if got := EpicBar(1, 20); !strings.HasPrefix(got, "▰") {
		t.Errorf("EpicBar(1,20) must show progress: %q", got)
	}
	if got := EpicBar(19, 20); !strings.Contains(got, "▱") {
		t.Errorf("EpicBar(19,20) must not render full: %q", got)
	}
	if got := EpicBar(20, 20); strings.Contains(got, "▱") {
		t.Errorf("EpicBar(20,20) must render full: %q", got)
	}
}
