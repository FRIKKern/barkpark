package taskboard

import (
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/x/ansi"
)

var update = flag.Bool("update", false, "regenerate the golden frames")

// fixedNow is the injected clock all board goldens render against, so the
// frame is byte-stable regardless of when the suite runs.
var fixedNow = time.Date(2026, 7, 3, 12, 0, 0, 0, time.UTC)

func loadBoardFixture(t *testing.T) Board {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", "board_fixture.json"))
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	var b Board
	if err := json.Unmarshal(raw, &b); err != nil {
		t.Fatalf("decode fixture: %v", err)
	}
	return b
}

// fixtureUIState pins a cursor-selected row and one expanded task (the SSE
// bridge) so the goldens exercise both selection and inline expansion. The
// cursor indexes the SHELL's visibleRows order (NOW cards, then each epic's
// header + children, then orphans): with two NOW cards and one header ahead of
// the spine children, index 5 is the ready "Reconcile the #979 role seam".
func fixtureUIState() UIState {
	return UIState{
		Cursor:   5,
		Expanded: map[string]bool{"wire-sse-bridge": true},
		Conn:     ConnLive,
		LastSync: time.Date(2026, 7, 3, 11, 58, 0, 0, time.UTC),
	}
}

// plainFrame renders the board and strips ANSI so the golden is byte-stable
// across color-capable and dumb terminals alike (the profile-forcing
// alternative the charter allows; stripping is renderer-agnostic).
func plainFrame(b Board, st UIState, width, height int) string {
	return ansi.Strip(Render(b, st, width, height, fixedNow))
}

func TestRenderGoldens(t *testing.T) {
	old := Chrome
	Chrome = ChromeInfo{RepoName: "barkpark", Branch: "work/doc-fresh", Server: "guerrilla"}
	t.Cleanup(func() { Chrome = old })

	b := loadBoardFixture(t)
	st := fixtureUIState()

	for _, width := range []int{60, 80, 100} {
		width := width
		t.Run(goldenName(width), func(t *testing.T) {
			got := plainFrame(b, st, width, 40)
			path := filepath.Join("testdata", goldenName(width))
			if *update {
				if err := os.WriteFile(path, []byte(got), 0o644); err != nil {
					t.Fatalf("write golden: %v", err)
				}
				return
			}
			want, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("read golden (run with -update): %v", err)
			}
			if got != string(want) {
				t.Errorf("frame at %d cols diverged from %s\n--- got ---\n%s\n--- want ---\n%s",
					width, path, got, want)
			}
		})
	}
}

func goldenName(width int) string {
	switch width {
	case 60:
		return "golden_60.txt"
	case 80:
		return "golden_80.txt"
	default:
		return "golden_100.txt"
	}
}

// TestRenderNeverExceedsWidth guards the runewidth-safety invariant across a
// sweep of widths (including sub-60 degrade): no rendered line may be wider
// than the pane, on the multi-byte fixture.
func TestRenderNeverExceedsWidth(t *testing.T) {
	b := loadBoardFixture(t)
	st := fixtureUIState()
	for _, width := range []int{40, 52, 60, 72, 80, 100, 120} {
		frame := plainFrame(b, st, width, 40)
		for i, ln := range strings.Split(frame, "\n") {
			if w := ansi.StringWidth(ln); w > width {
				t.Errorf("width %d: line %d is %d cols (over budget): %q", width, i, w, ln)
			}
		}
	}
}

// TestRenderHeightPinsTickerAndFooter proves the frame is exactly `height`
// lines and that the footer hint is the last line regardless of body size.
func TestRenderHeightPinsTickerAndFooter(t *testing.T) {
	b := loadBoardFixture(t)
	st := fixtureUIState()
	for _, height := range []int{20, 30, 40, 60} {
		frame := plainFrame(b, st, 80, height)
		lines := strings.Split(frame, "\n")
		if len(lines) != height {
			t.Fatalf("height %d: got %d lines", height, len(lines))
		}
		if !strings.Contains(lines[len(lines)-1], "jk move") {
			t.Errorf("height %d: footer not pinned to last line: %q", height, lines[len(lines)-1])
		}
	}
}

// TestRenderShortHeightScrolls proves the spine windows (not overflows) when
// the pane is too short to show every row, and surfaces a "more below" hint.
func TestRenderShortHeightScrolls(t *testing.T) {
	b := loadBoardFixture(t)
	st := fixtureUIState()
	frame := plainFrame(b, st, 80, 18)
	if lines := strings.Split(frame, "\n"); len(lines) != 18 {
		t.Fatalf("got %d lines, want 18", len(lines))
	}
	if !strings.Contains(frame, "more below") && !strings.Contains(frame, "more above") {
		t.Errorf("short pane should surface a scroll affordance:\n%s", frame)
	}
}

// TestRenderFlatQueue proves the wave-2 orphan policy in the frame: with zero
// epics the loose section reads as a plain "── tasks ──" title (never
// "(no epic)"), the 55 stale-done orphans collapse to a single "+55 done" line,
// no folded row is painted, and the header's ready count comes from the overlaid
// tasks (8), not the fictional stored count.
func TestRenderFlatQueue(t *testing.T) {
	b := BuildBoard(loadFlatSnapshot(t), RepoContext{}, refNow)
	frame := ansi.Strip(Render(b, UIState{Conn: ConnPolling}, 80, 120, fixedNow))

	if strings.Contains(frame, "(no epic)") {
		t.Errorf("zero-epics board still shows '(no epic)':\n%s", frame)
	}
	if !strings.Contains(frame, "── tasks ─") {
		t.Errorf("zero-epics board is missing the plain 'tasks' queue title:\n%s", frame)
	}
	if !strings.Contains(frame, "+55 done") {
		t.Errorf("55 stale-done orphans did not fold to '+55 done':\n%s", frame)
	}
	if strings.Contains(frame, "dn001") || strings.Contains(frame, "dn055") {
		t.Errorf("a folded stale-done orphan was painted as a row:\n%s", frame)
	}
	if !strings.Contains(frame, "8 ready") {
		t.Errorf("ready count should be 8 (overlaid tasks), not the stored count:\n%s", frame)
	}
}

// TestRenderReadyClampSuffix — a clamped ready head puts a "+" on the header
// count, so the pane is honest that the true ready total is at least this many.
func TestRenderReadyClampSuffix(t *testing.T) {
	b := Board{
		Counts:           map[string]int{"in_progress": 1, "blocked": 0, "done": 0},
		ReadyHeadClamped: true,
		Orphans: []Task{
			{DocID: "r1", Title: "ready one", Lifecycle: "ready", UpdatedAt: fixedNow},
			{DocID: "r2", Title: "ready two", Lifecycle: "ready", UpdatedAt: fixedNow},
		},
	}
	frame := ansi.Strip(Render(b, UIState{Conn: ConnPolling}, 80, 30, fixedNow))
	if !strings.Contains(frame, "2+ ready") {
		t.Errorf("clamped ready count should render '2+ ready':\n%s", frame)
	}
}

// TestReadyCountIncludesEpicRoots — a claimable parent task (overlaid ready,
// heading a subtree so it renders only as a section header) still counts in the
// header's ready number: the strip is a corpus summary, and `bp task next` can
// hand you that root. 1 ready root + 1 ready child + 1 ready orphan = 3.
func TestReadyCountIncludesEpicRoots(t *testing.T) {
	b := Board{
		Epics: []Epic{{
			Root: Task{DocID: "root", Title: "Claimable parent", Lifecycle: "ready", UpdatedAt: fixedNow},
			Children: []Task{
				{DocID: "c1", Title: "ready child", Lifecycle: "ready", UpdatedAt: fixedNow},
				{DocID: "c2", Title: "open child", Lifecycle: "open", UpdatedAt: fixedNow},
			},
		}},
		Orphans: []Task{{DocID: "o1", Title: "ready orphan", Lifecycle: "ready", UpdatedAt: fixedNow}},
	}
	if got := readyCountLabel(b); got != "3" {
		t.Errorf("readyCountLabel = %q, want %q (root + child + orphan)", got, "3")
	}
}

// TestRenderTruncationNote — when the list clamp dropped rows (TaskCount below
// the summed lifecycle counts), the header carries an honest "showing N of M"
// note instead of presenting a partial board as the whole.
func TestRenderTruncationNote(t *testing.T) {
	b := Board{
		TaskCount: 1000,
		Counts:    map[string]int{"open": 900, "done": 600}, // total 1500 > 1000 fetched
	}
	frame := ansi.Strip(Render(b, UIState{Conn: ConnPolling}, 80, 30, fixedNow))
	if !strings.Contains(frame, "showing 1000 of 1500") {
		t.Errorf("truncated board is missing the 'showing N of M' note:\n%s", frame)
	}

	// A whole board (fetched == total) shows no note.
	whole := Board{TaskCount: 60, Counts: map[string]int{"open": 20, "done": 40}}
	wf := ansi.Strip(Render(whole, UIState{Conn: ConnPolling}, 80, 30, fixedNow))
	if strings.Contains(wf, "showing") {
		t.Errorf("a whole board should carry no truncation note:\n%s", wf)
	}
}

// TestRenderEmptyBoardIsHonest proves the never-blank promise: an empty board
// still paints header + NOW-empty + an honest all-clear + ticker + footer.
func TestRenderEmptyBoardIsHonest(t *testing.T) {
	empty := Board{Counts: map[string]int{}}
	frame := ansi.Strip(Render(empty, UIState{Conn: ConnOffline}, 80, 30, fixedNow))
	for _, want := range []string{"NOW", "nothing claimed", "All clear", "offline", "jk move"} {
		if !strings.Contains(frame, want) {
			t.Errorf("empty frame missing %q:\n%s", want, frame)
		}
	}
}

// TestRenderActionStrip proves the strip renders directly above the footer, and
// only consumes a line when it has something to say.
func TestRenderActionStrip(t *testing.T) {
	b := Board{Counts: map[string]int{}}
	st := UIState{Conn: ConnLive, LastSync: fixedNow,
		Strip: ActionStrip{Message: "claimed as tui-mbp · epoch 4", Role: RoleOK}}
	lines := strings.Split(ansi.Strip(Render(b, st, 80, 20, fixedNow)), "\n")
	if len(lines) != 20 {
		t.Fatalf("got %d lines, want 20", len(lines))
	}
	footer := lines[len(lines)-1]
	strip := lines[len(lines)-2]
	if !strings.Contains(footer, "jk move") {
		t.Errorf("footer not pinned last: %q", footer)
	}
	if !strings.Contains(strip, "claimed as tui-mbp · epoch 4") {
		t.Errorf("action strip not directly above the footer: %q", strip)
	}

	// An empty strip costs no line: the footer is the last line with the ticker
	// immediately above it (no blank act line inserted).
	stNo := UIState{Conn: ConnLive, LastSync: fixedNow}
	noStrip := ansi.Strip(Render(b, stNo, 80, 20, fixedNow))
	if strings.Contains(noStrip, "claimed as") {
		t.Errorf("empty strip still rendered content:\n%s", noStrip)
	}
}

// TestRenderWokenDormantEpicShowsChildren pins the shared fold rule on the
// render side: an explicit CollapsedEpics entry (even =false) OVERRIDES
// Dormant, so an epic the user woke with enter/l actually paints its children.
// Before the shared foldedEpic rule the renderer kept a woken dormant epic
// folded while the shell navigated its (invisible) children.
func TestRenderWokenDormantEpicShowsChildren(t *testing.T) {
	b := Board{Epics: []Epic{{
		Root:     Task{DocID: "e2", Title: "Search epic"},
		Children: []Task{{DocID: "cx", Title: "Reindex media"}},
		Dormant:  true,
	}}}
	st := UIState{Conn: ConnLive, LastSync: fixedNow,
		CollapsedEpics: map[string]bool{"e2": false}} // the user woke it
	frame := ansi.Strip(Render(b, st, 80, 30, fixedNow))
	if !strings.Contains(frame, "Reindex media") {
		t.Errorf("woken dormant epic still hides its children:\n%s", frame)
	}
	// And without the override the dormant epic stays folded.
	stAuto := UIState{Conn: ConnLive, LastSync: fixedNow}
	if frame := ansi.Strip(Render(b, stAuto, 80, 30, fixedNow)); strings.Contains(frame, "Reindex media") {
		t.Errorf("dormant epic did not auto-fold:\n%s", frame)
	}
}

// TestRenderSyncingStateIsHonest proves the first-paint state reads "syncing…",
// distinct from "offline" — the pane never claims "all clear" before it has
// actually heard back from the server.
func TestRenderSyncingStateIsHonest(t *testing.T) {
	b := Board{Counts: map[string]int{}}
	st := UIState{Conn: ConnPolling} // LastSync zero → first fetch in flight
	frame := ansi.Strip(Render(b, st, 80, 20, fixedNow))
	if !strings.Contains(frame, "syncing") {
		t.Errorf("first-paint frame missing the syncing state:\n%s", frame)
	}
	if strings.Contains(frame, "offline") || strings.Contains(frame, "All clear") {
		t.Errorf("syncing frame dishonestly claims offline/all-clear:\n%s", frame)
	}
}
