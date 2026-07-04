package taskboard

import (
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/charmbracelet/x/ansi"
	runewidth "github.com/mattn/go-runewidth"
)

var testNow = time.Date(2026, 7, 3, 12, 0, 0, 0, time.UTC)

func TestStatusGlyph(t *testing.T) {
	// The design-language spec §1 vocabulary (charter D36): a steady in_progress
	// representative (⠋ — the board animates it), `!` blocked, ○ ready|open,
	// ✓ done|closed, ✕ cancelled, and the neutral "·" dot for an unknown state.
	cases := map[string]string{
		"in_progress": "⠋",
		"ready":       "○",
		"open":        "○",
		"blocked":     "!",
		"done":        "✓",
		"closed":      "✓",
		"cancelled":   "✕",
		"weird":       "·",
	}
	for life, want := range cases {
		if got := StatusGlyph(life); got != want {
			t.Errorf("StatusGlyph(%q) = %q, want %q", life, got, want)
		}
	}
}

// TestStatusGlyphWidth — every glyph the gutter can paint is exactly one display
// column so the fixed 2-col gutter never shifts as the lifecycle changes (the
// steady in_progress representative and every animated spinner frame are all
// single-column Braille).
func TestStatusGlyphWidth(t *testing.T) {
	for _, life := range []string{"in_progress", "ready", "open", "blocked", "done", "closed", "cancelled", "weird"} {
		if w := runewidth.StringWidth(StatusGlyph(life)); w != 1 {
			t.Errorf("StatusGlyph(%q) width = %d, want 1", life, w)
		}
	}
	for i := 0; i < 10; i++ {
		if w := runewidth.StringWidth(spinnerGlyph(i)); w != 1 {
			t.Errorf("spinnerGlyph(%d) width = %d, want 1", i, w)
		}
	}
	if w := runewidth.StringWidth(brailleStill); w != 1 {
		t.Errorf("brailleStill width = %d, want 1", w)
	}
}

// TestReducedMotionFreezesSpinner — NO_MOTION freezes the in_progress spinner on
// the single steady ⠿ frame at every frame index (spec §2), and it stays one
// display column so the gutter never shifts.
func TestReducedMotionFreezesSpinner(t *testing.T) {
	t.Setenv("NO_MOTION", "1")
	for i := 0; i < 10; i++ {
		if got := spinnerGlyph(i); got != brailleStill {
			t.Errorf("NO_MOTION spinnerGlyph(%d) = %q, want %q", i, got, brailleStill)
		}
	}
	if got := boardGlyph("in_progress", 3); got != brailleStill {
		t.Errorf("NO_MOTION boardGlyph(in_progress) = %q, want %q", got, brailleStill)
	}
}

// TestAsciiEscapeHatch — BP_TASKS_ASCII swaps the whole glyph set for 1-column
// ASCII so nothing turns to tofu (spec §3), and every glyph stays a single
// display column.
func TestAsciiEscapeHatch(t *testing.T) {
	t.Setenv("BP_TASKS_ASCII", "1")
	want := map[string]string{
		"ready": "o", "open": ".", "blocked": "!", "done": "v",
		"cancelled": "x", "weird": ".",
	}
	for life, w := range want {
		if got := StatusGlyph(life); got != w {
			t.Errorf("ASCII StatusGlyph(%q) = %q, want %q", life, got, w)
		}
	}
	for _, life := range []string{"in_progress", "ready", "open", "blocked", "done", "cancelled"} {
		if w := runewidth.StringWidth(boardGlyph(life, 2)); w != 1 {
			t.Errorf("ASCII boardGlyph(%q) width = %d, want 1", life, w)
		}
	}
}

func TestSelectionMarker(t *testing.T) {
	if SelectionMarker(true) != "▎" {
		t.Error("selected marker should be the ▎ left bar")
	}
	if SelectionMarker(false) != " " {
		t.Error("unselected marker should be a single space (keeps glyph aligned)")
	}
	// Gutter must be exactly 2 display columns whether selected or not.
	for _, sel := range []bool{true, false} {
		w := runewidth.StringWidth(SelectionMarker(sel) + StatusGlyph("in_progress"))
		if w != 2 {
			t.Errorf("gutter width with selected=%v = %d, want 2", sel, w)
		}
	}
}

func TestAgeBadge(t *testing.T) {
	cases := []struct {
		name string
		at   time.Time
		want string
	}{
		{"zero", time.Time{}, ""},
		{"seconds", testNow.Add(-30 * time.Second), "now"},
		{"minutes", testNow.Add(-4 * time.Minute), "4m"},
		{"hours", testNow.Add(-3 * time.Hour), "3h"},
		{"days", testNow.Add(-48 * time.Hour), "2d"},
		{"future-skew", testNow.Add(90 * time.Second), "now"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := AgeBadge(tc.at, testNow); got != tc.want {
				t.Errorf("AgeBadge = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestRoleForMapping(t *testing.T) {
	cases := []struct {
		name string
		task Task
		want string
	}{
		{"ready is neutral", Task{Lifecycle: "ready"}, "neutral"},
		{"open is neutral", Task{Lifecycle: "open"}, "neutral"},
		{"blocked is warn", Task{Lifecycle: "blocked"}, "warn"},
		{"done is ok", Task{Lifecycle: "done"}, "ok"},
		{"closed is ok", Task{Lifecycle: "closed"}, "ok"},
		{"in_progress no claim is info", Task{Lifecycle: "in_progress"}, "info"},
		{
			"fresh claim is info",
			Task{Lifecycle: "in_progress", Claim: &Claim{ClaimedAt: testNow.Add(-1 * time.Minute)}},
			"info",
		},
		{
			"claim past 70% lease is warn",
			Task{Lifecycle: "in_progress", Claim: &Claim{ClaimedAt: testNow.Add(-4 * time.Minute)}},
			"warn",
		},
		{
			"claim past lease is danger",
			Task{Lifecycle: "in_progress", Claim: &Claim{ClaimedAt: testNow.Add(-6 * time.Minute)}},
			"danger",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := RoleFor(tc.task, testNow).String(); got != tc.want {
				t.Errorf("RoleFor = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestConnRole(t *testing.T) {
	if connRole(ConnLive).String() != "ok" {
		t.Error("live should be ok")
	}
	if connRole(ConnPolling).String() != "warn" {
		t.Error("polling should be warn")
	}
	if connRole(ConnOffline).String() != "danger" {
		t.Error("offline should be danger")
	}
}

// TestTruncateMultibyteSafe pins the runewidth-safety invariant on the widths
// that garble naive byte-slicing: Norwegian (æøå = 1 col / 2 bytes), CJK
// (2 cols / 3 bytes), and emoji (2 cols / 4 bytes). No cut may split a rune or
// overflow the column budget.
func TestTruncateMultibyteSafe(t *testing.T) {
	cases := []struct {
		name string
		s    string
		max  int
	}{
		{"norwegian", "Håndbok for grensesnittdesign", 12},
		{"cjk", "文档任务看板视图很长的标题需要截断", 10},
		{"emoji", strings.Repeat("🚀", 20), 7},
		{"mixed", "Ship 🚀 the 看板 board", 11},
		{"tiny", "Bjørnsønn", 2},
		{"zero", "anything", 0},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := truncate(tc.s, tc.max)
			if !utf8.ValidString(got) {
				t.Errorf("truncate(%q,%d)=%q: invalid UTF-8 (rune split)", tc.s, tc.max, got)
			}
			if w := runewidth.StringWidth(got); w > tc.max {
				t.Errorf("truncate(%q,%d) width=%d exceeds budget", tc.s, tc.max, w)
			}
		})
	}
}

// TestTaskRowRightMetaNoGarbleOnMultibyte proves a right-aligned meta column
// stays within budget and readable even when the title is CJK/emoji — the
// exact case naive byte math corrupts.
func TestTaskRowRightMetaNoGarble(t *testing.T) {
	task := Task{
		DocID:     "t",
		Title:     "看板视图 🚀 a very long multibyte task title that must clip",
		Lifecycle: "in_progress",
		Claim:     &Claim{Worker: "opus-3", ClaimedAt: testNow.Add(-2 * time.Minute)},
		Criteria:  &Criteria{Met: 1, Total: 2},
	}
	for _, width := range []int{60, 72, 100} {
		rows := TaskRow(task, false, 0, width, 0, testNow)
		if len(rows) != 1 {
			t.Fatalf("collapsed row should be 1 line, got %d", len(rows))
		}
		line := ansi.Strip(rows[0])
		if w := runewidth.StringWidth(line); w > width {
			t.Errorf("width %d: row is %d cols: %q", width, w, line)
		}
		if !strings.Contains(line, "opus-3") {
			t.Errorf("width %d: worker meta dropped unexpectedly: %q", width, line)
		}
	}
}

// TestTaskRowDegradesBelow60 proves rows shed right-meta but keep glyph+title
// on a narrow pane.
func TestTaskRowDegradesBelow60(t *testing.T) {
	task := Task{
		DocID:     "t",
		Title:     "Wire the bridge",
		Lifecycle: "in_progress",
		Claim:     &Claim{Worker: "opus-3", ClaimedAt: testNow.Add(-2 * time.Minute)},
	}
	line := ansi.Strip(TaskRow(task, false, 0, 40, 0, testNow)[0])
	if strings.Contains(line, "opus-3") {
		t.Errorf("below 60 cols meta should be dropped: %q", line)
	}
	if !strings.Contains(line, "Wire the bridge") && !strings.Contains(line, "Wire") {
		t.Errorf("title must survive the degrade: %q", line)
	}
}

// TestTaskRowUnclaimedInProgressWearsStaleness — an in_progress row WITHOUT a
// claim has no claim-age tint, so the day-scale stale badge must step in: an
// 8-day-idle unclaimed in_progress task may not render alarm-free.
func TestTaskRowUnclaimedInProgressWearsStaleness(t *testing.T) {
	task := Task{
		DocID:     "t",
		Title:     "Wire the bridge",
		Lifecycle: "in_progress",
		UpdatedAt: testNow.Add(-8 * 24 * time.Hour),
	}
	line := ansi.Strip(TaskRow(task, false, 0, 80, 0, testNow)[0])
	if !strings.Contains(line, "8d") {
		t.Errorf("unclaimed stale in_progress row must wear its age badge: %q", line)
	}
}

// TestEpicHeaderShowsPhaseRollup — the design-language header rail (charter D41)
// is a `done/total` completion rollup with a dotted leader. Here: 1 ready + 1
// in_progress (open) + 7 folded done = 7/9.
func TestEpicHeaderShowsPhaseRollup(t *testing.T) {
	e := Epic{
		Root:       Task{Title: "Cloud GUI epic"},
		Children:   []Task{{Lifecycle: "ready"}, {Lifecycle: "in_progress"}},
		DoneFolded: 7,
	}
	line := ansi.Strip(EpicHeader(e, 80))
	if !strings.Contains(line, "Cloud GUI epic") {
		t.Errorf("header missing title: %q", line)
	}
	if !strings.Contains(line, "7/9") {
		t.Errorf("header should show the done/total rollup 7/9: %q", line)
	}
	if !strings.Contains(line, "·") {
		t.Errorf("header should carry a dotted leader: %q", line)
	}
	if runewidth.StringWidth(line) > 80 {
		t.Errorf("header over width: %q", line)
	}
}

// TestTruncateMiddleKeepsBothEnds proves the middle-out clip the action strip
// uses for Studio deep links keeps the load-bearing doc-id tail (a tail-first
// clip would drop it). Width-safe and idempotent when it already fits.
func TestTruncateMiddleKeepsBothEnds(t *testing.T) {
	url := "opening https://guerrilla.barkpark.cloud/studio/production/task/drafts.abc-123"
	got := truncateMiddle(url, 50, len("/drafts.abc-123"))
	if runewidth.StringWidth(got) > 50 {
		t.Fatalf("over width: %d cols %q", runewidth.StringWidth(got), got)
	}
	if !strings.HasPrefix(got, "opening https://") {
		t.Errorf("lost the head: %q", got)
	}
	if !strings.HasSuffix(got, "drafts.abc-123") {
		t.Errorf("lost the doc-id tail: %q", got)
	}
	if !strings.Contains(got, "…") {
		t.Errorf("no elision marker: %q", got)
	}
	// Fits already -> returned verbatim.
	short := "opening https://x/task/a"
	if truncateMiddle(short, 40, 7) != short {
		t.Errorf("mangled a string that already fits: %q", truncateMiddle(short, 40, 7))
	}
	// Degenerate widths never panic (any wantTail, honorable or not).
	for _, w := range []int{0, 1, 2, 3} {
		for _, wt := range []int{0, 5, 40} {
			if runewidth.StringWidth(truncateMiddle(url, w, wt)) > w {
				t.Errorf("width %d wantTail %d overran: %q", w, wt, truncateMiddle(url, w, wt))
			}
		}
	}
}

// TestTruncateMiddleHonorsWantTailForRealUUIDs pins the reason wantTail exists:
// live doc ids are 36-col UUIDs, so on a 60-col pane a balanced split keeps
// only 29 tail columns and shaves the UUID's leading chars — a lookalike id
// that resolves to nothing. The measured-tail ask must bring the id through
// WHOLE at every charter width, and fall back to balanced when the pane truly
// cannot hold minMiddleHead + the id.
func TestTruncateMiddleHonorsWantTailForRealUUIDs(t *testing.T) {
	const id = "35578fb4-079f-43bc-b232-ee2454eec867" // real live shape, 36 cols
	url := "opening https://guerrilla.barkpark.cloud/studio/production/task/" + id
	want := len("/" + id)
	for _, w := range []int{60, 70, 80} {
		got := truncateMiddle(url, w, want)
		if runewidth.StringWidth(got) > w {
			t.Errorf("width %d: over budget: %q", w, got)
		}
		if !strings.HasSuffix(got, "/"+id) {
			t.Errorf("width %d: UUID did not survive whole: %q", w, got)
		}
		if !strings.HasPrefix(got, "opening http") {
			t.Errorf("width %d: preamble unreadable: %q", w, got)
		}
	}
	// Unhonorable ask (pane too narrow for head+tail) -> balanced, still safe.
	got := truncateMiddle(url, 40, want)
	if runewidth.StringWidth(got) > 40 {
		t.Errorf("fallback over budget: %q", got)
	}
	if !strings.Contains(got, "…") {
		t.Errorf("fallback lost the elision marker: %q", got)
	}
}
