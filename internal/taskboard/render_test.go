package taskboard

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
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

// fixtureUIState pins a cursor-selected spine row so the goldens exercise the ▎
// selection marker. The cursor indexes the SHELL's visibleRows order (NOW cards,
// then each epic's header + children, then clusters, then orphans). After the
// NOW de-dup the two claimed tasks render ONLY in the pinned band, so the first
// spine child under the epic header is index 3 — the ready "Reconcile the #979
// role seam". Inline expand is gone (charter D11): enter now PUSHES a detail
// frame the compositor paints, so the BOARD golden is a single calm line per row.
//
// Frame is left at 0: the calm-board subtraction retired the frame-driven glyph
// animation (there is no spinner to capture in a moving state anymore), so a
// still and a moving frame render identically for the steady spine.
func fixtureUIState() UIState {
	return UIState{
		Cursor:   3,
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

// TestRenderFlatQueue proves the orphan policy in the frame: with zero epics the
// loose section reads as a plain "── tasks ──" title (never "(no epic)"), the done
// orphans collapse (charter D50 folds all but the ≤2 freshest cue → "+56 done"),
// no folded row is painted, and the header's ready count comes from the overlaid
// tasks (8), not the fictional stored count.
func TestRenderFlatQueue(t *testing.T) {
	b := BuildBoard(loadFlatSnapshot(t), RepoContext{}, refNow)
	frame := ansi.Strip(Render(b, UIState{Conn: ConnPolling}, 80, 120, fixedNow))

	if strings.Contains(frame, "(no epic)") {
		t.Errorf("zero-epics board still shows '(no epic)':\n%s", frame)
	}
	if !strings.Contains(frame, "tasks ·") {
		t.Errorf("zero-epics board is missing the plain 'tasks' queue title (dotted leader):\n%s", frame)
	}
	if !strings.Contains(frame, "56 done") {
		t.Errorf("the done orphans did not fold to a '56 done' tally:\n%s", frame)
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
	// Empty NOW + empty NEXT collapse the pinned band to NOTHING (charter wave-12
	// D58/D63 — no "NOW" label, no "nothing claimed" line). The honest all-clear
	// lives in the spine ("All clear — no open tasks."), and the header/footer still
	// paint, so the frame is never blank.
	for _, want := range []string{"All clear", "offline", "jk move"} {
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

// TestRenderInactiveHeaderOnlyAndExpandOverride pins the shared mode rule on the
// render side (the renderer and the shell share the ONE spineRows producer, so
// what navigates is what paints): an INACTIVE section (no FocusSet) with no fold
// entry paints HEADER-ONLY (charter D51 / wave-11 — the dotted rollup is the
// big-picture line), while an explicit CollapsedEpics entry (=false) OVERRIDES to
// modeExpanded and paints EVERY child. (Repurposed from the wave-8 head-cap test;
// the head-of-5 default it pinned is gone.)
func TestRenderInactiveHeaderOnlyAndExpandOverride(t *testing.T) {
	b := Board{Epics: []Epic{{
		Root: Task{DocID: "big", Title: "Search epic"},
		Children: []Task{
			{DocID: "k1", Title: "Head one"},
			{DocID: "k2", Title: "Head two"},
			{DocID: "k3", Title: "Head three"},
			{DocID: "k4", Title: "Head four"},
			{DocID: "k5", Title: "Head five"},
			{DocID: "k6", Title: "Tail beyond the head"},
		},
	}}}
	// Explicit expand (entry=false): every child paints.
	stOpen := UIState{Conn: ConnLive, LastSync: fixedNow,
		CollapsedEpics: map[string]bool{"big": false}}
	fOpen := ansi.Strip(Render(b, stOpen, 80, 30, fixedNow))
	for _, want := range []string{"Head one", "Head five", "Tail beyond the head"} {
		if !strings.Contains(fOpen, want) {
			t.Errorf("explicitly-expanded epic hides %q:\n%s", want, fOpen)
		}
	}
	// Default (no entry, inactive → no focus): the section paints header-ONLY.
	stHeader := UIState{Conn: ConnLive, LastSync: fixedNow}
	frame := ansi.Strip(Render(b, stHeader, 80, 30, fixedNow))
	if strings.Contains(frame, "Head one") || strings.Contains(frame, "Tail beyond the head") {
		t.Errorf("inactive epic painted child rows, want header only:\n%s", frame)
	}
	if !strings.Contains(frame, "Search epic") {
		t.Errorf("inactive epic dropped its header:\n%s", frame)
	}
}

// --- wave 4: motion paint (flash fades / live elapsed / working ticker) ------

// stillBoard is a board with NO claims in flight, NO flashes and events that are
// steady (not syncing) — the "at rest" case. Every motion path is a no-op on it
// (no NOW cards to tick, no flash — the calm board has no working line at all),
// so it renders identically whatever the Frame index. TestRenderAtRestGolden is
// the aliveness-budget tripwire (decision 16 — a diff between a still render and
// its golden is a motion leak).
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
			// A blocked child (canvas-cutover) makes this a focus section (charter
			// D51 / wave-11): the neighborhood is the blocked seed + its ready sibling.
			FocusSet: focusOf("reconcile-979-seam", "canvas-cutover"),
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
			path := filepath.Join("testdata", "still_golden_"+strconv.Itoa(width)+".txt")
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
			// flash-now is claimed, so after the NOW de-dup it renders ONLY in the
			// pinned band, never as a duplicate spine child.
			Children: []Task{
				{DocID: "flash-spine", Title: "Reticulate the splines", Lifecycle: "ready",
					ParentID: "motion-epic", Priority: "P2", UpdatedAt: fixedNow.Add(-2 * time.Second)},
				{DocID: "calm-row", Title: "A settled unchanged row", Lifecycle: "ready",
					ParentID: "motion-epic", Priority: "P3", UpdatedAt: fixedNow.Add(-time.Hour)},
			},
			DoneFolded: 2,
			// Active (owns the NOW claim flash-now) → focus neighborhood over both
			// ready children (charter D51 / wave-11).
			FocusSet: focusOf("flash-spine", "calm-row"),
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
		Frame:    4, // vestigial: the calm board no longer animates on the frame
		Conn:     ConnLive,
		LastSync: fixedNow.Add(-30 * time.Second),
		Flashes: map[string]time.Time{
			"flash-now":   fixedNow,                       // age 0    → level 2 (bright)
			"flash-spine": fixedNow.Add(-2 * time.Second), // age 2s   → level 1 (fading)
		},
	}
}

// TestRenderMotionGolden pins the visible (ANSI-stripped) motion at 60 and 100
// cols: the NOW card's ticking "4m30s" elapsed. The calm-board subtraction
// retired the ticker's cycling working head, so the only surviving visible motion
// is the NOW-band stopwatch. The flash tint is foreground-only (decision 17) so
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
			path := filepath.Join("testdata", "motion_golden_"+strconv.Itoa(width)+".txt")
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
			// The one surviving visible motion must be present: the NOW card's
			// ticking seconds.
			if !strings.Contains(got, "4m30s") {
				t.Errorf("width %d: motion frame missing the ticking 4m30s:\n%s", width, got)
			}
		})
	}
}

// TestRenderMotionElapsedIsNowBandOnly proves the ticking second-hand runs ONLY
// where real work runs (decision 19): the NOW card shows the seconds form
// "4m30s", and that seconds vocabulary appears on exactly ONE line — the pinned
// NOW card's meta line — never anywhere else (the claim is de-duped out of the
// spine, so it can only ever tick in the band).
func TestRenderMotionElapsedIsNowBandOnly(t *testing.T) {
	frame := plainFrame(motionBoard(), motionUIState(), 100, goldenHeight)
	if !strings.Contains(frame, "4m30s") {
		t.Errorf("NOW card is missing the ticking LiveElapsed token:\n%s", frame)
	}
	n := 0
	for _, ln := range strings.Split(frame, "\n") {
		if strings.Contains(ln, "4m30s") {
			n++
		}
	}
	if n != 1 {
		t.Errorf("the seconds vocabulary appears on %d lines, want exactly 1 (the NOW card only):\n%s", n, frame)
	}
}

// TestFlashPaintedInFrame proves the one-shot flash in the STYLED frame (a
// forced truecolor profile, since the test runner's default drops ANSI): a live
// flash tints the frame, an expired flash does not, and a settled board is
// byte-identical to no-flash — the aliveness budget, proven in color.
func TestFlashPaintedInFrame(t *testing.T) {
	oldp := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() { lipgloss.SetColorProfile(oldp) })

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
			Key:    "proj:sheets-parity",
			Active: true,
			// FocusSet over every member so the section renders its members (charter
			// D51 / wave-11 — a section without a focus set paints header-only).
			FocusSet: focusOf("sum1", "sum2", "vlookup", "pivot"),
			Tasks: []Task{
				{DocID: "sum1", Title: "Add the SUM() function", Lifecycle: "ready",
					Labels: []string{"proj:sheets-parity", "phase:build"},
					TwinOf: "sum2", TwinTitle: "Add a SUM function to the grid", UpdatedAt: warmNow},
				{DocID: "sum2", Title: "Add a SUM function to the grid", Lifecycle: "ready",
					Labels: []string{"proj:sheets-parity"},
					TwinOf: "sum1", TwinTitle: "Add the SUM() function", UpdatedAt: warmNow},
				{DocID: "vlookup", Title: "Implement VLOOKUP", Lifecycle: "ready",
					Labels: []string{"proj:sheets-parity"}, UpdatedAt: warmNow.Add(-6 * 24 * time.Hour)},
				{DocID: "pivot", Title: "Pivot tables", Lifecycle: "open",
					Labels: []string{"proj:sheets-parity", "area:grid"}, UpdatedAt: warmNow.Add(-11 * 24 * time.Hour)},
			},
			DoneFolded: 3,
		}},
		Orphans: []Task{
			{DocID: "cell-edit", Title: "Inline cell editing", Lifecycle: "open",
				UpdatedAt: warmNow},
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
	// The header carries the claim-forward rail (wave-7 D34): 3 ready · 3 done.
	for _, want := range []string{"sheets-parity ~", "3 ready", "3 done", "Add the SUM() function", "Pivot tables"} {
		if !strings.Contains(frame, want) {
			t.Errorf("cluster frame missing %q:\n%s", want, frame)
		}
	}
	// The calm-board subtraction retired per-tag chips: a member row never restates
	// its section, and no label paints on the row at all. The cluster key appears
	// exactly ONCE in the whole frame — the section header — because the orphan's
	// "+key?" suggestion chip is gone too.
	if n := strings.Count(frame, "sheets-parity"); n != 1 {
		t.Errorf("want exactly 1 'sheets-parity' occurrence (the dim section header), got %d:\n%s", n, frame)
	}
	// No ▰▱ progress bar survives on the cluster header (digits only).
	if strings.ContainsAny(frame, "▰▱") {
		t.Errorf("cluster header still paints a ▰▱ bar — the subtraction keeps digits only:\n%s", frame)
	}
}

// The wave-3 twin-marker and suggestion-chip render tests were retired by the
// calm-board subtraction (charter D14/D22): twins and suggestions leave the list,
// so there is nothing to assert in the spine. The underlying TwinOf/Suggested
// derivations are still exercised in board_test.go.

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

// TestNowCardIsAgentFirst proves a pinned NOW card is ONE agent-first line
// (charter wave-12 D59): the live Braille spinner (frame 0 ⠋ at rest), then the
// WORKER as the subject BEFORE the title, then bare criteria DIGITS (no ▰▱ bar)
// and the ticking age — no twin ⧉ marker, no epic breadcrumb.
func TestNowCardIsAgentFirst(t *testing.T) {
	claimed := Task{
		DocID: "sum1", Title: "Add the SUM() function", Lifecycle: "in_progress",
		TwinOf: "sum2", Criteria: &Criteria{Met: 2, Total: 3}, UpdatedAt: fixedNow,
		Claim: &Claim{Worker: "opus-3", Epoch: 1, ClaimedAt: fixedNow.Add(-4 * time.Minute)},
	}
	lines := NowCard(claimed, false, 80, 0, fixedNow)
	if len(lines) != 1 {
		t.Fatalf("NOW card should be exactly ONE line now, got %d: %q", len(lines), lines)
	}
	l0 := ansi.Strip(lines[0])
	if !strings.HasPrefix(strings.TrimLeft(l0, " "), "⠋ opus-3") {
		t.Errorf("NOW card should lead with ⠋ spinner + worker (agent-first), got %q", l0)
	}
	// The worker (subject) precedes the title.
	wi := strings.Index(l0, "opus-3")
	ti := strings.Index(l0, "Add the SUM() function")
	if wi < 0 || ti < 0 || wi > ti {
		t.Errorf("worker must lead the title (agent-first), got %q", l0)
	}
	if strings.Contains(l0, "⧉") {
		t.Errorf("NOW card should not wear a twin ⧉ marker: %q", l0)
	}
	if !strings.Contains(l0, "2/3") || strings.Contains(l0, "▰") || strings.Contains(l0, "▱") {
		t.Errorf("NOW card should show bare criteria digits, no bar: %q", l0)
	}
}

// TestRenderFooterCalmVerbs proves the footer advertises the subtracted verb set
// (no more `t tag`, and `enter open`) — and that at the 60-col charter minimum
// EVERY verb still paints (the compact variant drops the word "move", never the
// trailing "o studio").
func TestRenderFooterCalmVerbs(t *testing.T) {
	for _, width := range []int{60, 80} {
		frame := ansi.Strip(Render(Board{Counts: map[string]int{}}, UIState{Conn: ConnLive, LastSync: fixedNow}, width, 20, fixedNow))
		for _, verb := range []string{"jk", "enter open", "c claim", "x close", "o studio"} {
			if !strings.Contains(frame, verb) {
				t.Errorf("width %d: footer missing the %q hint:\n%s", width, verb, frame)
			}
		}
		if strings.Contains(frame, "t tag") {
			t.Errorf("width %d: footer should no longer advertise the retired t verb:\n%s", width, frame)
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

// firstPaintHeight is a compact pane the first-paint frames fit whole into, so
// the goldens show the full header + NOW band + spine a first launch presents.
const firstPaintHeight = 24

// firstPaintBoard is the modest board a fresh launch paints from its cache: one
// in-progress claim in the NOW band and one epic with a ready + a blocked child.
// It is a hand-built Board (not a BuildBoard result) so these goldens stay
// pinned to the RENDER, independent of any later re-tuning of the board policy —
// the same discipline as board_fixture.json.
func firstPaintBoard() Board {
	return Board{
		Counts: map[string]int{"in_progress": 1, "blocked": 1, "done": 5},
		Now: []Task{{
			DocID: "sse-loop", Title: "SSE reconnect backoff", Lifecycle: lifeInProgress,
			Claim:    &Claim{Worker: "opus-3", Epoch: 2, ClaimedAt: fixedNow.Add(-12 * time.Minute)},
			Criteria: &Criteria{Met: 1, Total: 3},
			ParentID: "cloud",
		}},
		Epics: []Epic{{
			Root: Task{DocID: "cloud", Title: "Cloud GUI epic", Lifecycle: lifeInProgress},
			Children: []Task{
				{DocID: "role-seam", Title: "Reconcile the #979 role seam", Lifecycle: lifeReady, UpdatedAt: fixedNow.Add(-20 * time.Minute)},
				{DocID: "banner", Title: "Ship the offline banner", Lifecycle: lifeBlocked, DependencyCount: 1, UpdatedAt: fixedNow.Add(-40 * time.Minute)},
			},
			// Active (owns the NOW claim) with a focus neighborhood over both children
			// (charter D51 / wave-11), so the epic renders its context, not header-only.
			Active:   true,
			FocusSet: focusOf("role-seam", "banner"),
		}},
	}
}

// TestFirstPaintGoldens pins the three states the first-paint cache introduces
// (charter decisions #9 + #20), each as a full frame at 60 and 80 cols:
//
//	(a) syncing — cold start, NO cache: an empty board painting the honest
//	    "syncing…" state (ConnPolling, LastSync still zero → isSyncing).
//	(b) cache   — primed from a cached snapshot: real rows with a "◐ polling · 3m"
//	    last-synced banner. It must NEVER read "● live" — the cached data is shown
//	    honestly as stale until the first live fetch swaps truth in.
//	(c) offline — the SAME cached rows after the first fetch failed: "✗ offline ·
//	    3m", the one degraded render path shared with loading, still honest about
//	    when the data was last true.
func TestFirstPaintGoldens(t *testing.T) {
	old := Chrome
	Chrome = ChromeInfo{RepoName: "barkpark", Branch: "work/doc-fresh", Server: "guerrilla"}
	t.Cleanup(func() { Chrome = old })

	lastSynced := fixedNow.Add(-3 * time.Minute) // the honest "3m" banner
	cases := []struct {
		name  string
		board Board
		st    UIState
	}{
		{"syncing", Board{Counts: map[string]int{}}, UIState{Conn: ConnPolling}},
		{"cache", firstPaintBoard(), UIState{Conn: ConnPolling, LastSync: lastSynced}},
		{"offline", firstPaintBoard(), UIState{Conn: ConnOffline, LastSync: lastSynced}},
	}
	for _, tc := range cases {
		tc := tc
		for _, width := range []int{60, 80} {
			width := width
			name := fmt.Sprintf("firstpaint_%s_%d.txt", tc.name, width)
			t.Run(name, func(t *testing.T) {
				got := plainFrame(tc.board, tc.st, width, firstPaintHeight)
				path := filepath.Join("testdata", name)
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
					t.Errorf("frame %s diverged\n--- got ---\n%s\n--- want ---\n%s", name, got, want)
				}
			})
		}
	}
}
