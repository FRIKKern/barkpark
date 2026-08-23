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
// selection marker. The spine is the whole cursor space (Amendment 7 — the
// pinned NOW/NEXT band is retired), so the cursor indexes the SHELL's
// visibleRows order (spine headers + children + clusters + orphans) directly;
// index 3 lands on a spine row near the top of the list. Inline
// expand is gone (charter D11): enter PUSHES a detail frame the compositor paints,
// so the BOARD golden is a single calm line per row.
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

// TestRenderHeightPinsStatusAndFooter proves the frame is exactly `height`
// lines and that the footer hint is the last line regardless of body size.
func TestRenderHeightPinsStatusAndFooter(t *testing.T) {
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
	frame := plainFrame(b, st, 80, 14)
	if lines := strings.Split(frame, "\n"); len(lines) != 14 {
		t.Fatalf("got %d lines, want 14", len(lines))
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

func TestBottomChromeIsExactlyThreeUsefulLines(t *testing.T) {
	b := Board{
		TaskCount: 1500,
		Counts:    map[string]int{"open": 900, "done": 600}, // fetch == corpus: not clamped
	}
	chrome := bottomChrome(b, UIState{Conn: ConnPolling}, 80, fixedNow)
	if len(chrome) != 3 {
		t.Fatalf("bottom chrome uses %d lines, want bar + status + keys", len(chrome))
	}
	plain := ansi.Strip(strings.Join(chrome, "\n"))
	for _, want := range []string{"ready", "done", "▄", "jk move"} {
		if !strings.Contains(plain, want) {
			t.Errorf("three-line chrome missing %q:\n%s", want, plain)
		}
	}
	lines := strings.Split(plain, "\n")
	if !strings.Contains(lines[0], "▄") || !strings.Contains(lines[1], "in flight") || !strings.Contains(lines[2], "jk move") {
		t.Errorf("bottom chrome order = %q, want slim bar, totals, keys", lines)
	}
	for _, noise := range []string{"showing", "recent activity", "pulse"} {
		if strings.Contains(plain, noise) {
			t.Errorf("three-line chrome retained %q noise:\n%s", noise, plain)
		}
	}
}

// TestMomentumShowingNofM proves the 1000-row horizon disclosure (charter D40):
// when the fetch (TaskCount) is short of the true corpus (summed Counts) the
// momentum line owns a dim "showing N of M" note. It renders at a comfortable
// width, sheds WHOLE (never a mid-token fragment) when the pane is tight, and
// stays silent when nothing was clamped.
func TestMomentumShowingNofM(t *testing.T) {
	truncated := Board{
		TaskCount: 1000,
		Counts:    map[string]int{"in_progress": 2, "open": 4731, "done": 2000}, // 6733 corpus
	}
	st := UIState{Conn: ConnPolling}

	wide := ansi.Strip(momentumLine(truncated, st, 120))
	if !strings.Contains(wide, "showing 1000 of 6733") {
		t.Errorf("wide momentum should disclose the clamp:\n%s", wide)
	}

	// Narrow enough to clip the note but hold the base: it sheds WHOLE — no
	// partial "showing"/" of " — while the primary counts stay untruncated.
	narrow := ansi.Strip(momentumLine(truncated, st, 50))
	if strings.Contains(narrow, "showing") || strings.Contains(narrow, " of ") {
		t.Errorf("a tight pane must shed the note whole, never fragment it:\n%q", narrow)
	}
	// The primary instruments survive the shed.
	for _, want := range []string{"in flight", "done"} {
		if !strings.Contains(narrow, want) {
			t.Errorf("primary instrument %q lost to the shed:\n%q", want, narrow)
		}
	}

	// A full fetch (TaskCount == corpus) discloses nothing — nothing was clamped.
	full := Board{TaskCount: 6733, Counts: truncated.Counts}
	if got := ansi.Strip(momentumLine(full, st, 120)); strings.Contains(got, "showing") {
		t.Errorf("an un-clamped board must stay silent:\n%s", got)
	}
	// A zero fetch (no snapshot yet) is not a clamp either.
	zero := Board{Counts: truncated.Counts}
	if got := ansi.Strip(momentumLine(zero, st, 120)); strings.Contains(got, "showing") {
		t.Errorf("a zero-fetch board must stay silent:\n%s", got)
	}
}

// TestMomentumInFlightDenominatorCollapsed — the D115/D120 denominator proof.
// Prime's raw lifecycle_counts are twin-doubled (no collapse_twins), so a board
// painted from them shows an inflated "N in flight" AND — because the deciding
// predicate of the showing-N-of-M disclosure is TaskCount < summedLifecycleCounts,
// not any >1000 threshold — discloses a clamp that never happened. The collapsed
// path (mergeInflight + countInProgress, the exact FetchSnapshotFull seam)
// repairs both numbers. Twin divergence is SYNTHESIZED (twin-doubled prime
// counts + a union-only claimed row): the live prime-vs-union delta is 0 today,
// so a live inequality assert would be vacuously green.
func TestMomentumInFlightDenominatorCollapsed(t *testing.T) {
	window := []Task{
		{DocID: "w1", Kind: "task", Lifecycle: "in_progress", Claim: &Claim{Worker: "wA"}, UpdatedAt: fixedNow},
		{DocID: "w2", Kind: "task", Lifecycle: "open", UpdatedAt: fixedNow},
	}
	inflight := []Task{
		{DocID: "w1", Kind: "task", Lifecycle: "in_progress", Claim: &Claim{Worker: "wA"}, UpdatedAt: fixedNow}, // dedup case
		{DocID: "u1", Kind: "task", Lifecycle: "in_progress", Claim: &Claim{Worker: "wB"}, UpdatedAt: fixedNow}, // union-only
	}
	// A lifecycle-divergent twin counts once per copy in prime: it says 3 in
	// flight while the deduped union holds 2. Summed counts: 3 + 1 = 4.
	extras := primeExtras{counts: map[string]int{"in_progress": 3, "open": 1}}
	st := UIState{Conn: ConnLive}

	// MUTATION CONTROL — the pre-D120 board: prime's RAW counts, uncollapsed.
	// TaskCount(2, window only) < summed(4) fires the disclosure over a corpus
	// that was never clamped, and the in-flight count paints the doubled 3.
	// This is the exact lie D115 live-reproduced (11-vs-10); if the collapse
	// seam ever regresses, the assertions below are what the operator would see.
	//
	// The verbatim Counts copy is DELIBERATE, not a shortcut. D124 (#11974) put a
	// SECOND collapse inside BuildBoard itself — recomputeInProgress rewrites the
	// in_progress bucket from s.Tasks — so BuildBoard can no longer compose an
	// uncollapsed board: it collapses by construction. Left as it was, this
	// control silently lost its teeth (it painted "1 in flight" with no
	// disclosure at all, i.e. it stopped reproducing the lie it exists to
	// reproduce). Restoring the pre-D124 contract — Counts copied verbatim from
	// prime, the ONE line D124 changed on this path — is what keeps the
	// assertions below honest instead of vacuous.
	rawBoard := BuildBoard(composeSnapshot(window, extras, fixedNow), RepoContext{}, fixedNow)
	rawBoard.Counts = map[string]int{"in_progress": 3, "open": 1} // prime verbatim, pre-D124
	rawLine := ansi.Strip(momentumLine(rawBoard, st, 120))
	if !strings.Contains(rawLine, "3 in flight") || !strings.Contains(rawLine, "showing 2 of 4") {
		t.Fatalf("mutation control lost its teeth — uncollapsed counts no longer reproduce the twin-doubled lie:\n%s", rawLine)
	}

	// The collapsed path, exactly as FetchSnapshotFull merges it.
	merged, _ := mergeInflight(window, nil, inflight, nil)
	// The FETCH seam's own teeth, asserted DIRECTLY. Since D124 the board
	// re-derives in_progress from the rows it holds, so a regression in
	// countInProgress (prime's raw 3, or len(third-fetch)) would be MASKED by
	// recomputeInProgress before it ever reached the rendered line below.
	// Pin the seam's output where nothing downstream can launder it.
	if got := countInProgress(merged); got != 2 {
		t.Fatalf("countInProgress must collapse the twin-doubled 3 to the deduped union 2, got %d", got)
	}
	extras.counts["in_progress"] = countInProgress(merged)
	b := BuildBoard(composeSnapshot(merged, extras, fixedNow), RepoContext{}, fixedNow)
	line := ansi.Strip(momentumLine(b, st, 120))
	if !strings.Contains(line, "2 in flight") {
		t.Errorf("collapsed momentum should count the deduped union (2), got:\n%s", line)
	}
	if strings.Contains(line, "showing") {
		t.Errorf("nothing was clamped once the denominator collapsed — the disclosure must stay silent:\n%s", line)
	}
	// The deciding predicate directly: the union board is whole, so TaskCount
	// must not read short of the summed lifecycle counts.
	if b.TaskCount < summedLifecycleCounts(b) {
		t.Errorf("TaskCount %d < summed counts %d on a whole union board — the denominator still carries a twin double-count", b.TaskCount, summedLifecycleCounts(b))
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

func TestHeaderNamesSnapshotFailureInsteadOfCallingItOffline(t *testing.T) {
	old := Chrome
	Chrome = ChromeInfo{Server: "guerrilla"}
	t.Cleanup(func() { Chrome = old })

	st := UIState{Conn: ConnOffline, ConnProblem: "snapshot too large", LastSync: fixedNow}
	line := ansi.Strip(headerLine1(st, 100, fixedNow))
	if !strings.Contains(line, "snapshot too large") {
		t.Fatalf("header omitted the snapshot failure: %q", line)
	}
	if strings.Contains(line, "offline") {
		t.Fatalf("header mislabeled a rejected snapshot as offline: %q", line)
	}
}

func TestEmptyFailedSnapshotDoesNotClaimAllClear(t *testing.T) {
	empty := Board{Counts: map[string]int{}}
	frame := ansi.Strip(Render(empty, UIState{
		Conn: ConnOffline, ConnProblem: "server error",
	}, 80, 30, fixedNow))
	if !strings.Contains(frame, "Unable to load tasks") || !strings.Contains(frame, "server error") {
		t.Fatalf("failed cold snapshot omitted its honest empty state:\n%s", frame)
	}
	if strings.Contains(frame, "All clear") {
		t.Fatalf("failed cold snapshot falsely claimed all clear:\n%s", frame)
	}
}

// TestRenderActionStrip proves transient feedback replaces the help row rather
// than expanding the fixed three-line footer.
func TestRenderActionStrip(t *testing.T) {
	b := Board{Counts: map[string]int{}}
	st := UIState{Conn: ConnLive, LastSync: fixedNow,
		Strip: ActionStrip{Message: "claimed as tui-mbp · epoch 4", Role: RoleOK}}
	lines := strings.Split(ansi.Strip(Render(b, st, 80, 20, fixedNow)), "\n")
	if len(lines) != 20 {
		t.Fatalf("got %d lines, want 20", len(lines))
	}
	last := lines[len(lines)-1]
	if !strings.Contains(last, "claimed as tui-mbp · epoch 4") {
		t.Errorf("action feedback did not replace the help row: %q", last)
	}
	if strings.Contains(last, "jk move") {
		t.Errorf("action feedback and keyboard help collided: %q", last)
	}

	// An empty strip leaves keyboard help in the third slot.
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
		strip := lines[len(lines)-1]
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
// in place as a spinner row inside its epic (charter D56 — the pinned band is
// retired) wearing the full criteria ladder — a met ✓, a live-pulsed spinner
// rung (the claim's now-pulse names criterion 1), an honest recorded miss on
// criterion 2 — plus the now-line the pulse feeds the ticker, a just-created
// ready row and a settled (unchanged) row. motionUIState marks the claim as a
// level-2 (bright) flash and the just-created row as a level-1 (fading) flash
// at Frame 4.
func motionBoard() Board {
	claimed := fixedNow.Add(-(4*time.Minute + 30*time.Second))
	claim := &Claim{Worker: "opus-3", Epoch: 4, ClaimedAt: claimed,
		Now: &ClaimPulse{Text: "debouncing the refetch loop", At: fixedNow.Add(-90 * time.Second), Criterion: 1}}
	items := []CriterionItem{
		{Criterion: "Bridge reconnects after a drop", Met: true},
		{Criterion: "Refetch debounced to 750ms"},
		{Criterion: "Events dedup across reconnects",
			Attempts: []CriterionAttempt{{Note: "dedup flaky under load", At: fixedNow.Add(-3 * time.Minute), Worker: "opus-3"}}},
	}
	return Board{
		Now: []Task{{
			DocID: "flash-now", Title: "Ship the live bridge", Lifecycle: "in_progress",
			ParentID: "motion-epic", Criteria: &Criteria{Met: 1, Total: 3}, CriteriaItems: items,
			Claim: claim, UpdatedAt: claimed,
		}},
		Epics: []Epic{{
			Root: Task{DocID: "motion-epic", Title: "Motion epic", Lifecycle: "in_progress",
				Kind: "goal", UpdatedAt: fixedNow},
			// flash-now is claimed and renders IN PLACE as a spinner row (charter
			// D56 — the retired band was the only other home it ever had).
			Children: []Task{
				{DocID: "flash-now", Title: "Ship the live bridge", Lifecycle: "in_progress",
					ParentID: "motion-epic", Criteria: &Criteria{Met: 1, Total: 3}, CriteriaItems: items,
					Claim: claim, UpdatedAt: claimed},
				{DocID: "flash-spine", Title: "Reticulate the splines", Lifecycle: "ready",
					ParentID: "motion-epic", Priority: "P2", UpdatedAt: fixedNow.Add(-2 * time.Second)},
				{DocID: "calm-row", Title: "A settled unchanged row", Lifecycle: "ready",
					ParentID: "motion-epic", Priority: "P3", UpdatedAt: fixedNow.Add(-time.Hour)},
			},
			DoneFolded: 2,
			// Active (owns the live claim flash-now) → focus neighborhood over the
			// claim and both ready children (charter D51 / wave-11).
			FocusSet: focusOf("flash-now", "flash-spine", "calm-row"),
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

// TestRenderMotionGolden pins the visible (ANSI-stripped) in-flight frame at 60
// and 100 cols: the claimed task as an agent-attributed spinner row inside its
// epic (charter D56). The flash tint is foreground-only (decision 17) so it
// does not survive the strip — TestFlashPaintedInFrame proves it in the styled
// frame instead.
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
			// The in-flight claim must render in place, agent-attributed.
			if !strings.Contains(got, "Ship the live bridge") {
				t.Errorf("width %d: motion frame missing the claimed row:\n%s", width, got)
			}
		})
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

// --- wave 16 slice 3: mouse hover tint --------------------------------------

// firstSelectableTask returns the Ref and selectable-index of the first spine
// TASK row in a board — the row a hover test paints. selectable-index counts
// only Selectable rows (headers included), matching the cursor index space.
func firstSelectableTask(b Board, st UIState) (ref string, selIdx int) {
	i := 0
	for _, sr := range spineRows(b, st) {
		if !sr.Selectable {
			continue
		}
		if sr.Kind == spineTask {
			return sr.Ref, i
		}
		i++
	}
	return "", -1
}

// TestHoverPaintedInFrame proves the hover highlight in the STYLED frame (a
// forced truecolor profile, since the runner's default drops ANSI): a live
// hover changes the frame, EXACTLY the hovered task card re-renders in the accent
// foreground (the chat Phases-pane selection grammar — no background bar), every
// OTHER line is byte-identical (siblings never recede), and the change is
// styling ONLY — the ansi-stripped text is unchanged. The cursor is parked on
// the hovered row so it is guaranteed inside the viewport window; both renders
// share that cursor, so the selection marker is identical.
func TestHoverPaintedInFrame(t *testing.T) {
	oldp := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() { lipgloss.SetColorProfile(oldp) })

	b := motionBoard()
	st := motionUIState()
	st.Flashes = nil // isolate the hover paint from the flash motion

	ref, selIdx := firstSelectableTask(b, st)
	if ref == "" {
		t.Fatal("fixture has no selectable spine task to hover")
	}
	st.Cursor = selIdx // keep the hovered row inside the window in both renders

	without := Render(b, st, 100, goldenHeight, fixedNow)

	hov := st
	hov.HoverTarget = ref
	with := Render(b, hov, 100, goldenHeight, fixedNow)

	if with == without {
		t.Fatalf("a hover target produced NO visible change in the styled frame")
	}

	wl := strings.Split(with, "\n")
	ol := strings.Split(without, "\n")
	if len(wl) != len(ol) {
		t.Fatalf("hover changed the line count: %d vs %d", len(wl), len(ol))
	}

	// Probe the live SGR open sequences the two paints emit under this profile.
	probeOpen := func(s lipgloss.Style) string {
		rendered := s.Render("\x00\x00")
		i := strings.Index(rendered, "\x00\x00")
		if i <= 0 {
			t.Fatalf("style rendered no open sequence under truecolor: %q", rendered)
		}
		return rendered[:i]
	}
	hoverOpen := probeOpen(hoverStyle)

	hoveredLines := 0
	for i := range wl {
		// Styling only: the visible text is equal.
		if ansi.Strip(wl[i]) != ansi.Strip(ol[i]) {
			t.Errorf("line %d: hover changed the VISIBLE text (must be styling only)\n got: %q\nwant: %q",
				i, ansi.Strip(wl[i]), ansi.Strip(ol[i]))
		}
		if wl[i] == ol[i] {
			continue
		}
		if !strings.Contains(wl[i], hoverOpen) {
			t.Errorf("line %d changed without the accent hover restyle (siblings must stay untouched):\n%q", i, wl[i])
			continue
		}
		hoveredLines++
	}
	if hoveredLines != 2 {
		t.Errorf("hover restyled %d lines, want exactly 2 (both lines of the active task card)", hoveredLines)
	}

	// The hover is a FOREGROUND restyle (the chat Phases-pane grammar), never a
	// background bar: hoverStyle must carry the accent foreground and no
	// background, so the highlight reads as accent text, not an inverted row.
	if hoverStyle.GetForeground() == (lipgloss.NoColor{}) {
		t.Errorf("hoverStyle has no foreground — the accent highlight would be invisible")
	}
	if hoverStyle.GetBackground() != (lipgloss.NoColor{}) {
		t.Errorf("hoverStyle set a background — hover is a foreground restyle, never a background bar")
	}
}

// deadEpicHoverBoard carries a live epic (selectable task rows) plus a
// cancelled-root epic that folds to a non-selectable tombstone line whose Ref is
// a real doc_id — the exact shape that proves hover NEVER tints a row just
// because its Ref matches, only a SELECTABLE one.
func deadEpicHoverBoard() Board {
	return Board{
		Epics: []Epic{
			{
				Root: Task{DocID: "live-epic", Title: "Live epic", Lifecycle: "in_progress",
					Kind: "goal", UpdatedAt: fixedNow},
				Children: []Task{
					{DocID: "row-a", Title: "First real task", Lifecycle: "ready",
						ParentID: "live-epic", Priority: "P2", UpdatedAt: fixedNow},
					{DocID: "row-b", Title: "Second real task", Lifecycle: "open",
						ParentID: "live-epic", Priority: "P3", UpdatedAt: fixedNow.Add(-time.Hour)},
				},
				FocusSet: focusOf("row-a", "row-b"),
			},
			{
				Root: Task{DocID: "dead-epic", Title: "Abandoned initiative", Lifecycle: "cancelled",
					Kind: "goal", UpdatedAt: fixedNow.Add(-30 * 24 * time.Hour)},
			},
		},
		Counts: map[string]int{"in_progress": 0, "ready": 1, "open": 1},
	}
}

// TestHoverOnlyTintsSelectableRows proves criterion 3: the tint lands on a
// selectable spine row ONLY. Every NON-selectable row carrying a real Ref (a
// cancelled-epic tombstone) is un-tintable — hovering its Ref leaves the frame
// byte-identical — while a real task Ref does tint (guarding against a vacuous
// all-pass). Separators and phase bands carry an empty Ref, so the `!= ""` guard
// makes them structurally unhoverable; the loop asserts the same for any
// non-selectable row that DOES carry a Ref.
func TestHoverOnlyTintsSelectableRows(t *testing.T) {
	oldp := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() { lipgloss.SetColorProfile(oldp) })

	b := deadEpicHoverBoard()
	st := motionUIState()
	st.Flashes = nil

	without := Render(b, st, 80, goldenHeight, fixedNow)

	sawNonSelectableRef := false
	for _, sr := range spineRows(b, st) {
		if sr.Selectable || sr.Ref == "" {
			continue
		}
		sawNonSelectableRef = true
		hov := st
		hov.HoverTarget = sr.Ref
		if got := Render(b, hov, 80, goldenHeight, fixedNow); got != without {
			t.Errorf("hovering non-selectable row (kind %v, ref %q) tinted the frame — only selectable rows may hover",
				sr.Kind, sr.Ref)
		}
	}
	if !sawNonSelectableRef {
		t.Fatal("fixture produced no non-selectable row with a Ref — the guard is untested")
	}

	// Non-vacuous: a selectable task Ref DOES tint, so the pass above is real.
	ref, _ := firstSelectableTask(b, st)
	if ref == "" {
		t.Fatal("fixture has no selectable task")
	}
	hov := st
	hov.HoverTarget = ref
	if Render(b, hov, 80, goldenHeight, fixedNow) == without {
		t.Fatalf("hovering a selectable task ref %q did not tint — the criterion-3 test would be vacuous", ref)
	}
}

// TestHoverFlickerDiscipline proves the never-flickers law (charter D95): the
// hover-changed guard IS the debounce. A Motion resolving to the SAME target
// returns changed=false and leaves the state — and therefore the View — byte
// identical; a Motion to a NEW target flips changed and mutates ONLY HoverTarget;
// and a "" target (pointer left every selectable row, or a key was pressed)
// clears the tint. No timer, no wall-clock — the guard is the whole cadence.
func TestHoverFlickerDiscipline(t *testing.T) {
	b := motionBoard()
	base := motionUIState()
	base.HoverTarget = ""

	// Motion onto a target sets it and reports the change.
	st1, ch1 := setHoverTarget(base, "flash-spine")
	if !ch1 || st1.HoverTarget != "flash-spine" {
		t.Fatalf("first hover: changed=%v target=%q, want true/\"flash-spine\"", ch1, st1.HoverTarget)
	}

	// A Motion resolving to the SAME target is the debounce: unchanged, and the
	// rendered frame is byte-identical (nothing to re-render).
	st2, ch2 := setHoverTarget(st1, "flash-spine")
	if ch2 {
		t.Errorf("a Motion onto the same target reported a change — the guard is not the debounce")
	}
	if Render(b, st1, 100, goldenHeight, fixedNow) != Render(b, st2, 100, goldenHeight, fixedNow) {
		t.Errorf("same-target Motion changed the View — the never-flickers law is broken")
	}

	// A Motion to a NEW target flips changed and mutates ONLY HoverTarget.
	st3, ch3 := setHoverTarget(st1, "calm-row")
	if !ch3 || st3.HoverTarget != "calm-row" {
		t.Fatalf("new target: changed=%v target=%q, want true/\"calm-row\"", ch3, st3.HoverTarget)
	}
	if st3.Cursor != st1.Cursor || st3.Frame != st1.Frame || st3.SpineScroll != st1.SpineScroll || st3.Conn != st1.Conn {
		t.Errorf("new-target Motion mutated more than HoverTarget: %+v vs %+v", st3, st1)
	}

	// Leaving every selectable row (or pressing a key) clears the tint.
	st4, ch4 := setHoverTarget(st3, "")
	if !ch4 || st4.HoverTarget != "" {
		t.Fatalf("clear: changed=%v target=%q, want true/\"\"", ch4, st4.HoverTarget)
	}
}

// TestHoverClearsOnKeyInput proves the tint yields to the keyboard: with a hover
// target armed, any keypress clears it, so the mouse highlight never lingers into
// keyboard navigation (charter D95). The keyboard flow is otherwise untouched —
// the cursor still moves.
func TestHoverClearsOnKeyInput(t *testing.T) {
	m := testModel(motionBoard())
	m.ui.HoverTarget = "flash-spine"
	m.ui.Cursor = 1

	nm, _ := m.handleKey(runes("j"))
	mm, ok := nm.(Model)
	if !ok {
		t.Fatalf("handleKey returned %T, want Model", nm)
	}
	if mm.ui.HoverTarget != "" {
		t.Errorf("a keypress did not clear the hover tint: HoverTarget=%q", mm.ui.HoverTarget)
	}
	if mm.ui.Cursor == m.ui.Cursor {
		t.Errorf("the keyboard flow was broken — the cursor did not move on 'j'")
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
// the goldens show the full header + spine a first launch presents.
const firstPaintHeight = 24

// firstPaintBoard is the modest board a fresh launch paints from its cache: one
// in-progress claim rendering in place inside its epic (charter D56) beside a
// ready + a blocked sibling. It is a hand-built Board (not a BuildBoard result)
// so these goldens stay pinned to the RENDER, independent of any later
// re-tuning of the board policy — the same discipline as board_fixture.json.
func firstPaintBoard() Board {
	claim := Task{
		DocID: "sse-loop", Title: "SSE reconnect backoff", Lifecycle: lifeInProgress,
		Claim:    &Claim{Worker: "opus-3", Epoch: 2, ClaimedAt: fixedNow.Add(-12 * time.Minute)},
		Criteria: &Criteria{Met: 1, Total: 3},
		ParentID: "cloud",
	}
	return Board{
		Counts: map[string]int{"in_progress": 1, "blocked": 1, "done": 5},
		Now:    []Task{claim},
		Epics: []Epic{{
			Root: Task{DocID: "cloud", Title: "Cloud GUI epic", Lifecycle: lifeInProgress},
			Children: []Task{
				claim,
				{DocID: "role-seam", Title: "Reconcile the #979 role seam", Lifecycle: lifeReady, UpdatedAt: fixedNow.Add(-20 * time.Minute)},
				{DocID: "banner", Title: "Ship the offline banner", Lifecycle: lifeBlocked, DependencyCount: 1, UpdatedAt: fixedNow.Add(-40 * time.Minute)},
			},
			// Active (owns the live claim) with a focus neighborhood over all three
			// children (charter D51 / wave-11), so the epic renders its context.
			Active:   true,
			FocusSet: focusOf("sse-loop", "role-seam", "banner"),
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

// TestSlideTopMinimalScroll pins the Amendment 8 windowing math: inside the
// window the top never moves; at an edge it follows the cursor 1:1; jumps land
// with the one-line affordance margin; and a cursor-less body just clamps.
func TestSlideTopMinimalScroll(t *testing.T) {
	cases := []struct {
		name                       string
		prev, cursorLine, avail, n int
		want                       int
	}{
		{"fits whole", 5, 3, 20, 10, 0},
		{"inside window holds still", 10, 15, 10, 100, 10},
		{"at bottom margin holds", 10, 18, 10, 100, 10},
		{"one past bottom margin slides one", 10, 19, 10, 100, 11},
		{"two past bottom margin slides two", 10, 20, 10, 100, 12},
		{"one above top margin slides one", 10, 10, 10, 100, 9},
		{"at top margin holds", 10, 11, 10, 100, 10},
		{"jump far below lands cursor above the ↓ margin", 0, 50, 10, 100, 42},
		{"jump to line 0 unclamps fully", 43, 0, 10, 100, 0},
		{"prev clamped when rows shrank", 95, -1, 10, 100, 90},
		{"no cursor keeps prev", 7, -1, 10, 100, 7},
		{"tiny viewport drops the margin", 5, 7, 3, 100, 5},
	}
	for _, tc := range cases {
		if got := slideTop(tc.prev, tc.cursorLine, tc.avail, tc.n); got != tc.want {
			t.Errorf("%s: slideTop(%d,%d,%d,%d) = %d, want %d",
				tc.name, tc.prev, tc.cursorLine, tc.avail, tc.n, got, tc.want)
		}
	}
}

// --- expressive-agent-loops: the now-line + criteria momentum (D9/D11) -------

// pulseBoard is a minimal board with one live claim carrying a now-pulse dated
// `at`, for the ticker decay tests.
func pulseBoard(at time.Time) Board {
	return Board{
		Now: []Task{{
			DocID: "pulse-task", Title: "Pulse task", Lifecycle: "in_progress",
			Claim: &Claim{Worker: "opus-7", Epoch: 3, ClaimedAt: at,
				Now: &ClaimPulse{Text: "wiring the decoder", At: at, Criterion: 0}},
			UpdatedAt: at,
		}},
		Counts: map[string]int{"in_progress": 1},
		Events: []Event{{Mutation: "task.claimed", DocID: "pulse-task", At: at}},
	}
}

// TestPulseLineDecay pins "stale never lies fresh" (charter D9): a
// fresh pulse wears the live spinner; once the pulse outlives the lease TTL
// the spinner is withheld, the line dims and says "stale" outright — visible
// even ANSI-stripped, so no terminal can render a dead pulse as current.
func TestPulseLineDecay(t *testing.T) {
	freshBoard := pulseBoard(fixedNow.Add(-time.Minute))
	freshTask := freshBoard.Now[0]
	fresh := ansi.Strip(pulseLine(freshTask, freshTask.Claim.Now, 0, 80, fixedNow))
	if !strings.Contains(fresh, "⠋ opus-7 · wiring the decoder") {
		t.Errorf("fresh pulse missing its live spinner:\n%s", fresh)
	}
	if strings.Contains(fresh, "stale") {
		t.Errorf("fresh pulse dishonestly reads stale:\n%s", fresh)
	}

	staleBoard := pulseBoard(fixedNow.Add(-12 * time.Minute))
	staleTask := staleBoard.Now[0]
	stale := ansi.Strip(pulseLine(staleTask, staleTask.Claim.Now, 0, 80, fixedNow))
	if !strings.Contains(stale, "· opus-7 · wiring the decoder · stale 12m") {
		t.Errorf("stale pulse missing the explicit decay:\n%s", stale)
	}
	if strings.Contains(stale, "⠋ opus-7") {
		t.Errorf("stale pulse still wears the live spinner — motion is liveness:\n%s", stale)
	}

	// The styled frame grades the decay by the SAME lease arithmetic as claim
	// tints: fresh spins blue (info), a leaning pulse (past 70% of the lease)
	// amber (warn), and a stale one is dim end to end.
	oldp := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() { lipgloss.SetColorProfile(oldp) })
	leanBoard := pulseBoard(fixedNow.Add(-4 * time.Minute))
	leanTask := leanBoard.Now[0]
	leanFrame := pulseLine(leanTask, leanTask.Claim.Now, 0, 80, fixedNow)
	if !strings.Contains(leanFrame, warnStyle.Render(spinnerGlyph(0))) {
		t.Errorf("a leaning pulse (4m of a 5m lease) should wear the warn spinner")
	}
	freshFrame := pulseLine(freshTask, freshTask.Claim.Now, 0, 80, fixedNow)
	if !strings.Contains(freshFrame, infoStyle.Render(spinnerGlyph(0))) {
		t.Errorf("a fresh pulse should wear the info (blue) spinner")
	}
}

// TestMomentumCountsCriteria — the momentum header carries the corpus criteria
// tally (charter D11), sheds it FIRST on a tight pane (the task counts + % are
// the primary instruments), and omits it entirely when the corpus has no
// criteria.
func TestMomentumCountsCriteria(t *testing.T) {
	b := Board{
		Counts:        map[string]int{"in_progress": 2, "done": 5},
		CriteriaMet:   7,
		CriteriaTotal: 19,
	}
	st := UIState{Conn: ConnLive, LastSync: fixedNow}
	frame := ansi.Strip(Render(b, st, 80, 20, fixedNow))
	if !strings.Contains(frame, "7/19 criteria") {
		t.Errorf("momentum header missing the criteria tally:\n%s", frame)
	}

	// Tight pane: the tally sheds whole, never mid-token truncates.
	narrow := ansi.Strip(momentumLine(b, st, 46))
	if strings.Contains(narrow, "criteria") || strings.Contains(narrow, "7/19") {
		t.Errorf("a tight momentum line should shed the criteria tally whole: %q", narrow)
	}
	if !strings.Contains(narrow, "in flight") {
		t.Errorf("the primary instruments must survive the shed: %q", narrow)
	}

	// No criteria in the corpus: no segment at all.
	b.CriteriaMet, b.CriteriaTotal = 0, 0
	if f := ansi.Strip(Render(b, st, 80, 20, fixedNow)); strings.Contains(f, "criteria") {
		t.Errorf("criteria-less corpus still shows a tally:\n%s", f)
	}
}

// TestBuildBoardCriteriaTally — BuildBoard sums criteria_progress across the
// fetched corpus, excluding cancelled work (the progressPct denominator law).
func TestBuildBoardCriteriaTally(t *testing.T) {
	s := Snapshot{Tasks: []Task{
		{DocID: "a", Lifecycle: "in_progress", Criteria: &Criteria{Met: 2, Total: 5}},
		{DocID: "b", Lifecycle: "done", Criteria: &Criteria{Met: 3, Total: 3}},
		{DocID: "c", Lifecycle: "cancelled", Criteria: &Criteria{Met: 1, Total: 4}}, // excluded
		{DocID: "d", Lifecycle: "open"},                                             // no criteria — costs nothing
	}}
	b := BuildBoard(s, RepoContext{}, fixedNow)
	if b.CriteriaMet != 5 || b.CriteriaTotal != 8 {
		t.Errorf("criteria tally = %d/%d, want 5/8 (cancelled excluded)", b.CriteriaMet, b.CriteriaTotal)
	}
}
