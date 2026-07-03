package taskboard

import (
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"github.com/muesli/termenv"
)

var update = flag.Bool("update", false, "regenerate the golden frames")

// goldenHeight is tall enough that the wave-3 fixture (two epics + two derived
// clusters + orphans, with one row expanded) renders WHOLE, so the goldens show
// every cluster header, twin marker, chip and stale token at once rather than a
// windowed slice — the frame a reviewer eyeballs.
const goldenHeight = 48

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
			got := plainFrame(b, st, width, goldenHeight)
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

// TestRenderActionStripKeepsURLTail proves the niggle fix: a Studio deep-link
// message on a narrow (<85 col) pane keeps its doc-id tail (middle-out clip)
// instead of the tail-first truncation that used to eat the one part an SSH
// user needs to paste.
func TestRenderActionStripKeepsURLTail(t *testing.T) {
	b := Board{Counts: map[string]int{}}
	// Live doc ids are 36-col UUIDs (not short slugs) — the id must come
	// through WHOLE, because a partially clipped UUID looks pasteable but
	// resolves to nothing.
	const id = "35578fb4-079f-43bc-b232-ee2454eec867"
	url := "opening https://guerrilla.barkpark.cloud/studio/production/task/" + id
	st := UIState{Conn: ConnLive, LastSync: fixedNow, Strip: ActionStrip{Message: url, Role: RoleOK}}
	for _, width := range []int{60, 72, 84} {
		lines := strings.Split(ansi.Strip(Render(b, st, width, 20, fixedNow)), "\n")
		strip := lines[len(lines)-2]
		if ansi.StringWidth(strip) > width {
			t.Errorf("width %d: strip over budget: %q", width, strip)
		}
		if !strings.Contains(strip, id) {
			t.Errorf("width %d: strip dropped the doc-id tail: %q", width, strip)
		}
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

// --- wave 4: motion paint (flash fades / live elapsed / working ticker) ------

// stillBoard is a board with NO claims in flight, NO flashes and events that are
// steady (not syncing) — the "at rest" case. Every wave-4 motion path is a no-op
// on it (no NOW cards to tick, no working line, no flash), so it must render
// BYTE-FOR-BYTE identical to the pre-slice code. still_golden_* was captured on
// the unmodified render.go: TestRenderAtRestGolden is the aliveness-budget
// tripwire (decision 16 — a diff here is a motion leak).
func stillBoard() Board {
	return Board{
		Epics: []Epic{{
			Root: Task{DocID: "cloud-gui-epic", Title: "Cloud GUI epic",
				Lifecycle: "in_progress", Kind: "goal",
				UpdatedAt: time.Date(2026, 7, 3, 11, 40, 0, 0, time.UTC)},
			Children: []Task{
				{DocID: "reconcile-979-seam", Title: "Reconcile the #979 role seam",
					Lifecycle: "ready", Priority: "P2", DependencyCount: 1,
					UpdatedAt: time.Date(2026, 7, 3, 11, 40, 0, 0, time.UTC)},
				{DocID: "canvas-cutover", Title: "Cut over the canvas default",
					Lifecycle: "blocked", Priority: "P2", DependencyCount: 2,
					UpdatedAt: time.Date(2026, 7, 3, 11, 0, 0, 0, time.UTC)},
			},
			DoneFolded: 7,
		}},
		Orphans: []Task{
			{DocID: "timeago-clamp", Title: "Fix the timeago clock-skew clamp",
				Lifecycle: "ready", Priority: "P3",
				UpdatedAt: time.Date(2026, 7, 3, 9, 15, 0, 0, time.UTC)},
		},
		Counts: map[string]int{"in_progress": 3, "blocked": 4, "done": 41},
		Events: []Event{
			{Mutation: "task.closed", DocID: "sse-reconnect", At: time.Date(2026, 7, 3, 11, 58, 0, 0, time.UTC)},
			{Mutation: "task.claimed", DocID: "debounce-refetch", At: time.Date(2026, 7, 3, 11, 55, 0, 0, time.UTC)},
			{Mutation: "task.created", DocID: "empty-state-goldens", At: time.Date(2026, 7, 3, 11, 50, 0, 0, time.UTC)},
		},
	}
}

// stillUIState is at rest: a live connection with a recorded sync, Frame 0 and
// no flashes — nothing for the heartbeat to animate.
func stillUIState() UIState {
	return UIState{Conn: ConnLive, LastSync: time.Date(2026, 7, 3, 11, 58, 0, 0, time.UTC)}
}

func TestRenderAtRestGolden(t *testing.T) {
	old := Chrome
	Chrome = ChromeInfo{RepoName: "barkpark", Branch: "work/doc-fresh", Server: "guerrilla"}
	t.Cleanup(func() { Chrome = old })

	b := stillBoard()
	st := stillUIState()
	for _, width := range []int{60, 80} {
		width := width
		t.Run(goldenName(width), func(t *testing.T) {
			got := plainFrame(b, st, width, goldenHeight)
			path := filepath.Join("testdata", "still_golden_"+itoa(width)+".txt")
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
				t.Errorf("AT-REST frame at %d cols diverged from the pre-slice golden %s "+
					"(the aliveness budget leaked motion into a still board)\n--- got ---\n%s\n--- want ---\n%s",
					width, path, got, want)
			}
		})
	}
}

func itoa(n int) string {
	if n == 60 {
		return "60"
	}
	if n == 100 {
		return "100"
	}
	return "80"
}

// motionBoard is the in-flight scene the motion goldens pin: one claim running
// in the NOW band (age 4m30s → LiveElapsed's seconds vocabulary), an epic whose
// children include the running claim, a just-created ready row and a settled
// (unchanged) row. motionUIState marks the claim as a level-2 (bright) flash and
// the just-created row as a level-1 (fading) flash at Frame 4.
func motionBoard() Board {
	claimed := fixedNow.Add(-(4*time.Minute + 30*time.Second))
	claim := &Claim{Worker: "opus-3", Epoch: 4, ClaimedAt: claimed}
	return Board{
		Now: []Task{{
			DocID: "flash-now", Title: "Ship the live bridge", Lifecycle: "in_progress",
			ParentID: "motion-epic", Criteria: &Criteria{Met: 1, Total: 3},
			Claim: claim, UpdatedAt: claimed,
		}},
		Epics: []Epic{{
			Root: Task{DocID: "motion-epic", Title: "Motion epic", Lifecycle: "in_progress",
				Kind: "goal", UpdatedAt: fixedNow},
			Children: []Task{
				{DocID: "flash-now", Title: "Ship the live bridge", Lifecycle: "in_progress",
					ParentID: "motion-epic", Criteria: &Criteria{Met: 1, Total: 3},
					Claim: claim, UpdatedAt: claimed},
				{DocID: "flash-spine", Title: "Reticulate the splines", Lifecycle: "ready",
					ParentID: "motion-epic", Priority: "P2", UpdatedAt: fixedNow.Add(-2 * time.Second)},
				{DocID: "calm-row", Title: "A settled unchanged row", Lifecycle: "ready",
					ParentID: "motion-epic", Priority: "P3", UpdatedAt: fixedNow.Add(-time.Hour)},
			},
			DoneFolded: 2,
		}},
		Counts: map[string]int{"in_progress": 1, "blocked": 0, "done": 2},
		Events: []Event{
			{Mutation: "task.claimed", DocID: "flash-now", At: fixedNow.Add(-4 * time.Minute)},
			{Mutation: "task.created", DocID: "flash-spine", At: fixedNow.Add(-2 * time.Second)},
		},
	}
}

func motionUIState() UIState {
	return UIState{
		Frame:    4, // WorkingVerb(4) == "herding"
		Conn:     ConnLive,
		LastSync: fixedNow.Add(-30 * time.Second),
		Flashes: map[string]time.Time{
			"flash-now":   fixedNow,                       // age 0    → level 2 (bright)
			"flash-spine": fixedNow.Add(-2 * time.Second), // age 2s   → level 1 (fading)
		},
	}
}

// TestRenderMotionGolden pins the visible (ANSI-stripped) motion at 60 and 100
// cols: the NOW card's ticking "4m30s" elapsed and the ticker's "✻ herding… ·
// 1 in flight" working head. The flash tint is foreground-only (decision 17) so
// it does not survive the strip — TestFlashPaintedInFrame proves it in the
// styled frame instead.
func TestRenderMotionGolden(t *testing.T) {
	old := Chrome
	Chrome = ChromeInfo{RepoName: "barkpark", Branch: "work/doc-fresh", Server: "guerrilla"}
	t.Cleanup(func() { Chrome = old })

	b := motionBoard()
	st := motionUIState()
	for _, width := range []int{60, 100} {
		width := width
		t.Run(goldenName(width), func(t *testing.T) {
			got := plainFrame(b, st, width, goldenHeight)
			path := filepath.Join("testdata", "motion_golden_"+itoa(width)+".txt")
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
				t.Errorf("motion frame at %d cols diverged from %s\n--- got ---\n%s\n--- want ---\n%s",
					width, path, got, want)
			}
			// The visible motion must be present: the ticking seconds and the
			// in-flight working head.
			for _, tok := range []string{"4m30s", "✻ herding… · 1 in flight"} {
				if !strings.Contains(got, tok) {
					t.Errorf("width %d: motion frame missing %q:\n%s", width, tok, got)
				}
			}
		})
	}
}

// TestRenderMotionElapsedIsNowBandOnly proves the ticking second-hand runs ONLY
// where real work runs (decision 19): the NOW card shows "4m30s", but the SAME
// claim rendered as a spine in_progress row keeps the coarse "4m" AgeBadge — the
// board does not tick everywhere, only in the pinned NOW band.
func TestRenderMotionElapsedIsNowBandOnly(t *testing.T) {
	frame := plainFrame(motionBoard(), motionUIState(), 100, goldenHeight)
	if !strings.Contains(frame, "4m30s") {
		t.Errorf("NOW card is missing the ticking LiveElapsed token:\n%s", frame)
	}
	// The spine child line ("Ship the live bridge  …  opus-3  4m") must carry the
	// coarse AgeBadge, never the seconds form.
	spine := ""
	for _, ln := range strings.Split(frame, "\n") {
		// the spine row is the one indented under the epic header (leading spaces
		// + status glyph), distinct from the NOW card (which has the "   " meta on
		// its own second line).
		if strings.Contains(ln, "opus-3") && strings.Contains(ln, "Ship the live bridge") {
			spine = ln
		}
	}
	if spine == "" {
		t.Fatalf("could not find the spine in_progress row for the claim:\n%s", frame)
	}
	if strings.Contains(spine, "4m30s") {
		t.Errorf("the spine row is ticking seconds — elapsed must stay NOW-band only: %q", spine)
	}
	if !strings.Contains(spine, "4m") {
		t.Errorf("the spine row lost its coarse age badge: %q", spine)
	}
}

// TestFlashPaintedInFrame proves the one-shot flash in the STYLED frame (a
// forced truecolor profile, since the test runner's default drops ANSI): a live
// flash tints the frame, an expired flash does not, and a settled board is
// byte-identical to no-flash — the aliveness budget, proven in color.
func TestFlashPaintedInFrame(t *testing.T) {
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() { lipgloss.SetColorProfile(termenv.Ascii) })

	b := motionBoard()

	noFlash := motionUIState()
	noFlash.Flashes = nil
	without := Render(b, noFlash, 100, goldenHeight, fixedNow)

	withFlash := Render(b, motionUIState(), 100, goldenHeight, fixedNow)
	if withFlash == without {
		t.Errorf("a live flash produced NO visible change in the styled frame")
	}

	// An expired flash (older than the 4s remnant window) decays to level 0, so
	// the frame returns byte-identical to the no-flash render — the flash is a
	// true one-shot, never a persistent glow.
	gone := motionUIState()
	gone.Flashes = map[string]time.Time{
		"flash-now":   fixedNow.Add(-5 * time.Second),
		"flash-spine": fixedNow.Add(-5 * time.Second),
	}
	if got := Render(b, gone, 100, goldenHeight, fixedNow); got != without {
		t.Errorf("an EXPIRED flash still tints the frame — the fade is not a one-shot")
	}

	// The visible text is unchanged whether flashed or not (foreground tint only,
	// never a background block or an added glyph that would shift the layout).
	if ansi.Strip(withFlash) != ansi.Strip(without) {
		t.Errorf("the flash changed the visible layout — it must be a foreground tint only")
	}
}

// --- wave 3: clusters / twins / staleness / suggestions ----------------------

// wave3Board is a compact fixture with one derived cluster carrying a twin pair,
// a stale (amber) and very-stale (red) member, a chip that de-dups against the
// section key, plus an orphan wearing a "+key?" suggestion — everything the
// integration slice paints, in one frame.
func wave3Board() Board {
	warmNow := fixedNow
	return Board{
		Clusters: []Cluster{{
			Key: "proj:sheets-parity",
			Tasks: []Task{
				{DocID: "sum1", Title: "Add the SUM() function", Lifecycle: "ready",
					Labels: []string{"proj:sheets-parity", "phase:build"}, TwinOf: "sum2", UpdatedAt: warmNow},
				{DocID: "sum2", Title: "Add a SUM function to the grid", Lifecycle: "ready",
					Labels: []string{"proj:sheets-parity"}, TwinOf: "sum1", UpdatedAt: warmNow},
				{DocID: "vlookup", Title: "Implement VLOOKUP", Lifecycle: "ready",
					Labels: []string{"proj:sheets-parity"}, UpdatedAt: warmNow.Add(-6 * 24 * time.Hour)},
				{DocID: "pivot", Title: "Pivot tables", Lifecycle: "open",
					Labels: []string{"proj:sheets-parity", "area:grid"}, UpdatedAt: warmNow.Add(-11 * 24 * time.Hour)},
			},
			DoneFolded: 3,
		}},
		Orphans: []Task{
			{DocID: "cell-edit", Title: "Inline cell editing", Lifecycle: "open",
				Suggested: "proj:sheets-parity", UpdatedAt: warmNow},
		},
		Stale:  2,
		Counts: map[string]int{"in_progress": 0, "blocked": 0, "done": 3},
	}
}

// TestRenderClusterSection proves the derived cluster paints as its own section:
// a header in the cluster's short (prefix-stripped) name with the "~" derived
// cue and a progress rail, its members below.
func TestRenderClusterSection(t *testing.T) {
	frame := ansi.Strip(Render(wave3Board(), UIState{Conn: ConnLive, LastSync: fixedNow}, 80, 40, fixedNow))
	for _, want := range []string{"sheets-parity ~", "3/7", "Add the SUM() function", "Pivot tables"} {
		if !strings.Contains(frame, want) {
			t.Errorf("cluster frame missing %q:\n%s", want, frame)
		}
	}
	// The section-key chip is de-duped: a member never re-states "sheets-parity"
	// on its own row — the only occurrences in the whole frame are the section
	// header itself and the orphan's "+sheets-parity?" suggestion chip…
	if n := strings.Count(frame, "sheets-parity"); n != 2 {
		t.Errorf("want exactly 2 'sheets-parity' occurrences (header + suggestion), got %d:\n%s", n, frame)
	}
	// …while the cross-cutting phase chip still paints on the member row.
	if !strings.Contains(frame, "build") {
		t.Errorf("cross-cutting chip 'build' dropped from the member row:\n%s", frame)
	}
}

// TestRenderTwinMarker proves a twin task wears the ⧉ glyph before its title.
func TestRenderTwinMarker(t *testing.T) {
	frame := ansi.Strip(Render(wave3Board(), UIState{Conn: ConnLive, LastSync: fixedNow}, 80, 40, fixedNow))
	if !strings.Contains(frame, "⧉ Add the SUM() function") {
		t.Errorf("twin task missing the ⧉ marker:\n%s", frame)
	}
}

// TestRenderTwinExpandedNamesPartner proves an expanded twin names its partner.
func TestRenderTwinExpandedNamesPartner(t *testing.T) {
	st := UIState{Conn: ConnLive, LastSync: fixedNow, Expanded: map[string]bool{"sum1": true}}
	frame := ansi.Strip(Render(wave3Board(), st, 80, 40, fixedNow))
	if !strings.Contains(frame, "twin ⧉ 'sum2'") {
		t.Errorf("expanded twin does not name its partner:\n%s", frame)
	}
}

// TestRenderStaleAgesAndCount proves day-scale staleness surfaces: stale
// non-terminal members show an age token in the meta, and the counts strip
// carries the warn-tinted "N stale" instrument.
func TestRenderStaleAgesAndCount(t *testing.T) {
	frame := Render(wave3Board(), UIState{Conn: ConnLive, LastSync: fixedNow}, 80, 40, fixedNow)
	plain := ansi.Strip(frame)
	if !strings.Contains(plain, "2 stale") {
		t.Errorf("counts strip missing the '2 stale' instrument:\n%s", plain)
	}
	for _, want := range []string{"6d", "11d"} {
		if !strings.Contains(plain, want) {
			t.Errorf("stale member missing its %q age token:\n%s", want, plain)
		}
	}
	// The 11d (>7d) age is danger-tinted, the 6d (>3d) age warn-tinted — the raw
	// (unstripped) frame must carry each role color around its token.
	dangerAge := dangerStyle.Render("11d")
	warnAge := warnStyle.Render("6d")
	if !strings.Contains(frame, dangerAge) {
		t.Errorf("the 11d age is not danger-tinted in the styled frame")
	}
	if !strings.Contains(frame, warnAge) {
		t.Errorf("the 6d age is not warn-tinted in the styled frame")
	}
}

// TestRenderSuggestionChip proves an unkeyed orphan that plausibly belongs to a
// cluster wears a dim "+key?" suggestion chip (suggestion only — never applied).
func TestRenderSuggestionChip(t *testing.T) {
	frame := ansi.Strip(Render(wave3Board(), UIState{Conn: ConnLive, LastSync: fixedNow}, 80, 40, fixedNow))
	if !strings.Contains(frame, "+sheets-parity?") {
		t.Errorf("suggested-tag orphan missing the '+key?' chip:\n%s", frame)
	}
}

// TestNowCardTwinMarker proves a pinned NOW card wears the ⧉ too — a claim on a
// suspected near-duplicate is the loudest "two of us are doing the same work"
// signal the board has, so the NOW band may not render it marker-free.
func TestNowCardTwinMarker(t *testing.T) {
	claimed := Task{
		DocID: "sum1", Title: "Add the SUM() function", Lifecycle: "in_progress",
		TwinOf: "sum2", UpdatedAt: fixedNow,
		Claim: &Claim{Worker: "opus-3", Epoch: 1, ClaimedAt: fixedNow.Add(-4 * time.Minute)},
	}
	lines := NowCard(claimed, "", false, 80, fixedNow)
	if !strings.Contains(ansi.Strip(lines[0]), "⧉ Add the SUM() function") {
		t.Errorf("NOW card for a twin is missing the ⧉ marker: %q", ansi.Strip(lines[0]))
	}
}

// TestRenderFooterHasTagVerb proves the footer advertises the new t verb — and
// that at the 60-col charter minimum EVERY verb still paints (the compact
// variant drops the word "move", never the trailing "o studio").
func TestRenderFooterHasTagVerb(t *testing.T) {
	for _, width := range []int{60, 80} {
		frame := ansi.Strip(Render(Board{Counts: map[string]int{}}, UIState{Conn: ConnLive, LastSync: fixedNow}, width, 20, fixedNow))
		for _, verb := range []string{"jk", "enter expand", "c claim", "x close", "t tag", "o studio"} {
			if !strings.Contains(frame, verb) {
				t.Errorf("width %d: footer missing the %q hint:\n%s", width, verb, frame)
			}
		}
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
