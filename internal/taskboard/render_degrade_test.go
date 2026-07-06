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

// TestManyClaimsKeepHeightContract proves the pinned NOW band degrades (agent
// rows folded to "+N more claimed") instead of pushing the spine/ticker/footer off
// the pane — a large concurrent-claim swarm is the NORM when many builders run.
// With the wave-12 one-line agent rows the fold threshold is higher, so the fixture
// carries enough claims to force the fold at height 30 (charter wave-12 D59/D63).
func TestManyClaimsKeepHeightContract(t *testing.T) {
	b := loadBoardFixture(t)
	for i := 0; i < 24; i++ {
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

// TestNowAgentRowForDormantEpicClaim proves a claimed task whose epic is dormant
// (children folded away, so it is absent from the visible spine) still surfaces in
// the NOW band as an agent-first one-line row (charter wave-12 D59: worker leads,
// no line-2 epic breadcrumb — the breadcrumb is retired, D56 shows the claim in
// context down in the spine instead).
func TestNowAgentRowForDormantEpicClaim(t *testing.T) {
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
	// The claim's own row carries the worker (agent-attributed) alongside the title,
	// on ONE line — no separate breadcrumb line beneath it.
	rowStart := strings.LastIndex(frame[:idx], "\n") + 1
	row := frame[rowStart : strings.Index(frame[rowStart:], "\n")+rowStart]
	if !strings.Contains(row, "opus-9") {
		t.Errorf("NOW agent row missing the worker attribution: %q", row)
	}
}

// The scaled-bar (Meter) honesty test was retired with Meter itself — the
// navigation-shell wave deleted the ▰▱ meter (charter D14/D31); the detail frame
// renders criteria as a ○/✓ checklist, not a bar.
