package taskboard

import (
	"fmt"
	"strings"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	runewidth "github.com/mattn/go-runewidth"
	"github.com/muesli/termenv"
)

var testNow = time.Date(2026, 7, 3, 12, 0, 0, 0, time.UTC)

func TestStatusGlyph(t *testing.T) {
	// The calm-board steady 4-glyph vocabulary (charter D14): ● in_progress,
	// ◐ blocked, ○ ready|open, ✓ done|closed — no animation, an unknown lifecycle
	// degrades to the neutral "·" dot.
	cases := map[string]string{
		"in_progress": "●",
		"ready":       "○",
		"open":        "○",
		"blocked":     "◐",
		"done":        "✓",
		"closed":      "✓",
		"weird":       "·",
	}
	for life, want := range cases {
		if got := StatusGlyph(life); got != want {
			t.Errorf("StatusGlyph(%q) = %q, want %q", life, got, want)
		}
	}
}

// TestStatusGlyphWidth — every glyph the gutter can paint is exactly one display
// column so the fixed 2-col gutter never shifts as the lifecycle changes. There
// is no longer any frame-driven animation to test (the spinner was retired).
func TestStatusGlyphWidth(t *testing.T) {
	for _, life := range []string{"in_progress", "ready", "open", "blocked", "done", "closed", "weird"} {
		if w := runewidth.StringWidth(StatusGlyph(life)); w != 1 {
			t.Errorf("StatusGlyph(%q) width = %d, want 1", life, w)
		}
	}
}

// TestCriteriaChecklistStates proves the ○/✓ grammar: a met entry renders ✓ +
// text, an unmet entry ○ + text, and a textless (malformed) slot a bare ○ with
// no trailing space — honest that an Nth criterion exists even when its text
// did not decode.
func TestCriteriaChecklistStates(t *testing.T) {
	items := []CriterionItem{
		{Criterion: "first done", Met: true},
		{Criterion: "second todo", Met: false},
		{Criterion: "", Met: false},
	}
	lines := CriteriaChecklist(items, &Criteria{Met: 1, Total: 3}, childIndent, 80)
	if len(lines) != 3 {
		t.Fatalf("want 3 checklist lines, got %d", len(lines))
	}
	p0, p1, p2 := ansi.Strip(lines[0]), ansi.Strip(lines[1]), ansi.Strip(lines[2])
	if !strings.HasSuffix(p0, "✓ first done") {
		t.Errorf("met item = %q, want ✓ + text", p0)
	}
	if !strings.HasSuffix(p1, "○ second todo") {
		t.Errorf("unmet item = %q, want ○ + text", p1)
	}
	if !strings.HasSuffix(p2, "○") || strings.HasSuffix(p2, " ") {
		t.Errorf("textless slot = %q, want a bare ○ with no trailing space", p2)
	}
	// Met and unmet lines must be styled DIFFERENTLY (ok-tint vs dim) so the
	// checkbox state is legible on a color terminal, not just via the glyph.
	oldp := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() { lipgloss.SetColorProfile(oldp) })
	styled := CriteriaChecklist(items, nil, childIndent, 80)
	if styled[0] == ansi.Strip(styled[0]) {
		t.Errorf("met line should carry an ok tint, got unstyled %q", styled[0])
	}
	if strings.TrimPrefix(styled[0], "\x1b") == styled[0] {
		t.Errorf("met line should begin with an SGR escape: %q", styled[0])
	}
}

// TestCriteriaChecklistCapsAndFolds — more than criteriaCap items fold the tail
// into a dim "… +N more" line so a 30-criterion goal cannot push the spine off
// the pane.
func TestCriteriaChecklistCapsAndFolds(t *testing.T) {
	items := make([]CriterionItem, criteriaCap+3)
	for i := range items {
		items[i] = CriterionItem{Criterion: fmt.Sprintf("criterion %d", i), Met: i%2 == 0}
	}
	lines := CriteriaChecklist(items, nil, childIndent, 80)
	if len(lines) != criteriaCap+1 {
		t.Fatalf("want %d lines (cap + fold tail), got %d", criteriaCap+1, len(lines))
	}
	if last := ansi.Strip(lines[len(lines)-1]); !strings.Contains(last, "… +3 more") {
		t.Errorf("fold tail = %q, want \"… +3 more\"", last)
	}
	// At exactly cap+1 the fold would spend its line hiding ONE item — same
	// height, less truth — so all cap+1 items paint and no tail appears.
	edge := CriteriaChecklist(items[:criteriaCap+1], nil, childIndent, 80)
	if len(edge) != criteriaCap+1 {
		t.Fatalf("cap+1 items: want %d unfolded lines, got %d", criteriaCap+1, len(edge))
	}
	if last := ansi.Strip(edge[len(edge)-1]); strings.Contains(last, "more") {
		t.Errorf("cap+1 items should not fold, got tail %q", last)
	}
}

// TestCriteriaChecklistMeterFallback — with no decoded items but a live counter,
// the detail falls back to the compact meter line (never emptier than before);
// with nothing at all it renders nothing.
func TestCriteriaChecklistMeterFallback(t *testing.T) {
	lines := CriteriaChecklist(nil, &Criteria{Met: 2, Total: 3}, childIndent, 80)
	if len(lines) != 1 || !strings.Contains(ansi.Strip(lines[0]), "criteria ▰▰▱ 2/3") {
		t.Fatalf("fallback = %v, want one compact meter line", lines)
	}
	for _, c := range []*Criteria{nil, {}, {Total: 0}} {
		if got := CriteriaChecklist(nil, c, childIndent, 80); got != nil {
			t.Errorf("empty items + %+v criteria should render nothing, got %v", c, got)
		}
	}
}

// TestCriteriaChecklistWidthSafe — every checklist line stays within the pane on
// a multibyte, over-long criterion set (the truncate budget is display-column,
// not byte, aware).
func TestCriteriaChecklistWidthSafe(t *testing.T) {
	items := []CriterionItem{
		{Criterion: strings.Repeat("看板 ", 30), Met: true},
		{Criterion: "a normal criterion that is also quite long and needs clipping on a narrow pane", Met: false},
	}
	for _, width := range []int{40, 60, 80, 100} {
		for i, ln := range CriteriaChecklist(items, nil, childIndent, width) {
			if w := ansi.StringWidth(ln); w > width {
				t.Errorf("width %d: line %d is %d cols: %q", width, i, w, ansi.Strip(ln))
			}
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

func TestMeter(t *testing.T) {
	if Meter(nil) != "" {
		t.Error("nil criteria must render nothing, never 0/0")
	}
	if Meter(&Criteria{Met: 0, Total: 0}) != "" {
		t.Error("zero-total criteria must render nothing, never 0/0")
	}
	if got := Meter(&Criteria{Met: 2, Total: 3}); got != "▰▰▱ 2/3" {
		t.Errorf("Meter(2/3) = %q", got)
	}
	if got := Meter(&Criteria{Met: 3, Total: 3}); got != "▰▰▱ 3/3" {
		// total==3 => 3 cells, all filled
		if got != "▰▰▰ 3/3" {
			t.Errorf("Meter(3/3) = %q, want all filled", got)
		}
	}
	// A large criteria set scales to the fixed 5-cell bar but keeps the true m/t.
	got := Meter(&Criteria{Met: 5, Total: 10})
	if !strings.HasSuffix(got, " 5/10") {
		t.Errorf("Meter(5/10) should keep true count: %q", got)
	}
	if cells := runewidth.StringWidth(strings.Fields(got)[0]); cells != meterCells {
		t.Errorf("large meter bar = %d cells, want %d", cells, meterCells)
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
		rows := TaskRow(task, false, false, childIndent, width, testNow)
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
	line := ansi.Strip(TaskRow(task, false, false, childIndent, 40, testNow)[0])
	if strings.Contains(line, "opus-3") {
		t.Errorf("below 60 cols meta should be dropped: %q", line)
	}
	if !strings.Contains(line, "Wire the bridge") && !strings.Contains(line, "Wire") {
		t.Errorf("title must survive the degrade: %q", line)
	}
}

// TestTaskRowExpandedHasHangingDetail proves the SHRUNK inline expand (charter
// D23) adds an indented criteria stub under the row — and that the density that
// left the list (labels, twin naming, dependency prose) does NOT reappear here;
// it lives in the detail view now. The criteria stub is the checklist (met/total
// digits when the item text did not decode).
func TestTaskRowExpandedHasHangingDetail(t *testing.T) {
	task := Task{
		DocID:          "t",
		Title:          "Wire the bridge",
		Lifecycle:      "in_progress",
		Labels:         []string{"live", "sse"},
		Criteria:       &Criteria{Met: 2, Total: 3},
		DependentCount: 2,
		Claim:          &Claim{Worker: "opus-3", ClaimedAt: testNow.Add(-1 * time.Minute)},
	}
	rows := TaskRow(task, true, true, childIndent, 80, testNow)
	if len(rows) < 2 {
		t.Fatalf("expanded row should have a criteria stub, got %d", len(rows))
	}
	body := ansi.Strip(strings.Join(rows[1:], "\n"))
	if !strings.Contains(body, "criteria") {
		t.Errorf("expanded body missing the criteria stub:\n%s", body)
	}
	// The retired density must NOT reappear in the shrunk stub.
	for _, gone := range []string{"labels", "live", "sse", "dependent"} {
		if strings.Contains(body, gone) {
			t.Errorf("shrunk expand should not carry %q (it moved to the detail view):\n%s", gone, body)
		}
	}
}

// TestTaskRowExpandedCriteriaChecklist proves the shrunk stub renders a real ○/✓
// checklist when the per-item text decoded, and stays width-safe.
func TestTaskRowExpandedCriteriaChecklist(t *testing.T) {
	task := Task{
		DocID:     "t",
		Title:     "Wire the bridge",
		Lifecycle: "ready",
		Priority:  "P2",
		Criteria:  &Criteria{Met: 1, Total: 2},
		CriteriaItems: []CriterionItem{
			{Criterion: "reconnect after a dropped stream", Met: true},
			{Criterion: "debounce the refetch", Met: false},
		},
		UpdatedAt: testNow.Add(-time.Hour),
	}
	for _, width := range []int{60, 80, 100} {
		rows := TaskRow(task, false, true, childIndent, width, testNow)
		body := ansi.Strip(strings.Join(rows[1:], "\n"))
		if !strings.Contains(body, "✓") || !strings.Contains(body, "○") {
			t.Errorf("width %d: expected a ○/✓ checklist stub:\n%s", width, body)
		}
		for i, ln := range rows {
			if w := ansi.StringWidth(ln); w > width {
				t.Errorf("width %d: expanded line %d is %d cols: %q", width, i, w, ansi.Strip(ln))
			}
		}
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
	line := ansi.Strip(TaskRow(task, false, false, childIndent, 80, testNow)[0])
	if !strings.Contains(line, "8d") {
		t.Errorf("unclaimed stale in_progress row must wear its age badge: %q", line)
	}
}

func TestEpicHeaderShowsProgress(t *testing.T) {
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
		t.Errorf("header should show 7/9 (7 folded done of 9 total): %q", line)
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
