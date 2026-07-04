package taskboard

// detail_render_test.go — full-frame goldens + stop-index contract tests for
// RenderTaskDetail (charter D15/D16/D24). Goldens are ANSI-stripped WHOLE
// frames (never substrings) at 60/80/100 cols. Each width golden concatenates
// THREE fixtures — RICH (every section, real mdlite headings/bullets/code),
// THIN (title+meta only — proves conditional sections), and BLOCKED (reason
// strip + a single paper stop) — so one file per width shows the reader the
// whole vocabulary at once. The DONE fixture drives targeted behavioral tests
// (lease-alarm suppression, inline close_reason) without a golden. Deterministic
// fixed clock; reuses the package's shared -update flag.

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"github.com/muesli/termenv"
)

// detailNow is the injected clock all detail goldens render against.
var detailNow = time.Date(2026, 7, 4, 17, 30, 0, 0, time.UTC)

func at(s string) time.Time {
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		panic(err)
	}
	return t
}

// richDetail exercises EVERY conditional section at once.
func richDetail() (TaskDetail, []Task) {
	d := TaskDetail{
		Task: Task{
			DocID:     "wire-sse-bridge",
			Title:     "Wire the SSE live bridge to the task board pane so every claim tick paints honestly",
			Lifecycle: "in_progress",
			Kind:      "task",
			ParentID:  "task-tui-epic",
			Priority:  "1",
			Labels:    []string{"proj:task-tui", "area:live", "wave:5"},
			Claim: &Claim{
				Worker:    "fable-3",
				Epoch:     4,
				ClaimedAt: at("2026-07-04T17:26:00Z"),
			},
			Criteria: &Criteria{Met: 2, Total: 3},
			CriteriaItems: []CriterionItem{
				{Criterion: "SSE dirty-bit triggers a debounced full snapshot refetch within 750ms", Met: true},
				{Criterion: "Connection dot renders live/polling/offline honestly", Met: true},
				{Criterion: "A stuck reconnect can never keep reading ConnLive", Met: false},
			},
			TwinOf:          "sse-bridge-dup",
			TwinTitle:       "Wire the SSE bridge (duplicate filing)",
			DependencyCount: 1,
			DependentCount:  2,
			InsertedAt:      at("2026-07-02T09:12:00Z"),
			UpdatedAt:       at("2026-07-04T17:22:00Z"),
		},
		Description: "The board must repaint the moment the queue moves. Events only say " +
			"that something moved; the refetch says what is true — never incremental " +
			"event application, so no drift and no ghost rows.\n\n" +
			"## Approach\n\n" +
			"Reuse internal/apiclient's StartSSE and pollOnce seams; the tea shell " +
			"stays a shell and every layout decision lives in a pure renderer.\n\n" +
			"- one dirty bit signals the refetch\n" +
			"- one debounce coalesces bursts\n" +
			"- one snapshot is the single source of truth\n\n" +
			"```go\nselect {\ncase <-dirty:\n    snap = refetch()\n}\n```",
		Design:         "One dirty bit, one debounce, one snapshot. The poll fallback must fire the same code path as real SSE so the two modes cannot drift apart.",
		DesignDoc:      "task-tui-wave5-charter",
		Papers:         []string{"doey-ui-lessons", "task-tui-wave5-charter"},
		Evidence:       []string{"internal/taskboard/live.go:42", "", ""},
		CodeRefs:       []string{"internal/taskboard/live.go", "internal/apiclient/change.go"},
		PreviousWorker: "opus-2",
		ClaimExpiredAt: at("2026-07-04T17:31:00Z"), // 1m out on a 5m lease → warn
		LastWorkedAt:   at("2026-07-04T17:20:00Z"),
	}
	children := []Task{
		{
			DocID: "sse-decode", Title: "Decode the change feed envelope",
			Lifecycle: "done", UpdatedAt: at("2026-07-03T10:00:00Z"),
		},
		{
			DocID: "sse-debounce", Title: "Debounce the refetch at 750ms",
			Lifecycle: "in_progress", UpdatedAt: at("2026-07-04T17:00:00Z"),
			Claim: &Claim{Worker: "fable-3", ClaimedAt: at("2026-07-04T17:26:00Z")},
		},
		{
			DocID: "sse-conn-dot", Title: "Honest connection dot states",
			Lifecycle: "ready", UpdatedAt: at("2026-07-04T12:00:00Z"),
		},
	}
	return d, children
}

// thinDetail proves the conditional sections: title + meta ONLY.
func thinDetail() (TaskDetail, []Task) {
	return TaskDetail{
		Task: Task{
			DocID:     "sketch-idea",
			Title:     "Sketch the paper rail interaction",
			Lifecycle: "open",
		},
	}, nil
}

func blockedDetail() (TaskDetail, []Task) {
	d := TaskDetail{
		Task: Task{
			DocID:           "role-seam",
			Title:           "Reconcile the #979 statusRole seam",
			Lifecycle:       "blocked",
			Kind:            "task",
			Priority:        "2",
			Labels:          []string{"proj:task-tui"},
			DependencyCount: 1,
			InsertedAt:      at("2026-06-30T08:00:00Z"),
			UpdatedAt:       at("2026-07-01T09:00:00Z"),
		},
		Description:   "Extract the four role names to a shared internal package and import them from both the CLI tables and the board theme.",
		BlockedReason: "waiting on the shared-package extraction to land before touching table.go",
		DesignDoc:     "task-tui-wave5-charter",
	}
	return d, nil
}

func doneDetail() (TaskDetail, []Task) {
	d := TaskDetail{
		Task: Task{
			DocID:     "heartbeat-tick",
			Title:     "Heartbeat: the NOW band ticks once a second while work is live",
			Lifecycle: "done",
			Kind:      "task",
			Priority:  "1",
			Labels:    []string{"proj:task-tui", "wave:4"},
			Claim: &Claim{
				Worker:    "fable-1",
				Epoch:     2,
				ClaimedAt: at("2026-07-03T09:00:00Z"),
			},
			Criteria: &Criteria{Met: 2, Total: 2},
			CriteriaItems: []CriterionItem{
				{Criterion: "Claim age ticks without a server round-trip", Met: true},
				{Criterion: "At rest the pane is perfectly still", Met: true},
			},
			InsertedAt: at("2026-07-02T14:00:00Z"),
			UpdatedAt:  at("2026-07-03T16:45:00Z"),
		},
		CloseReason:    "shipped in #1067",
		ResolutionNote: "Aliveness budget capped at one tick per second; flicker fix followed in #1100.",
		ClaimExpiredAt: at("2026-07-03T09:05:00Z"), // long spent — but done: no alarm
		Papers:         []string{"doey-ui-lessons"},
	}
	children := []Task{
		{DocID: "tick-budget", Title: "Cap the tick budget", Lifecycle: "done", UpdatedAt: at("2026-07-03T15:00:00Z")},
		{DocID: "flicker-fix", Title: "Kill the full-frame flicker", Lifecycle: "done", UpdatedAt: at("2026-07-03T16:40:00Z")},
	}
	return d, children
}

type detailFixture struct {
	name     string
	detail   TaskDetail
	children []Task
	cursor   int
}

func detailFixtures() []detailFixture {
	rd, rc := richDetail()
	td, tc := thinDetail()
	bd, bc := blockedDetail()
	dd, dc := doneDetail()
	return []detailFixture{
		{"rich", rd, rc, 1},    // cursor on the second child
		{"thin", td, tc, 0},    // no stops at all
		{"blocked", bd, bc, 0}, // cursor on the single paper stop
		{"done", dd, dc, 2},    // cursor on the paper after two children
	}
}

// plainDetailFrame renders and ANSI-strips the FULL frame — goldens compare
// the whole string, never substrings.
func plainDetailFrame(f detailFixture, width int) string {
	lines, _ := RenderTaskDetail(f.detail, f.children, f.cursor, width, detailNow)
	return ansi.Strip(strings.Join(lines, "\n"))
}

// goldenFixtures are the three frames each width golden concatenates: a rich
// task, a thin task, and a blocked task.
func goldenFixtures() []detailFixture {
	all := detailFixtures()
	return []detailFixture{all[0], all[1], all[2]} // rich, thin, blocked
}

// combinedGolden joins the three golden fixtures' whole frames under labeled
// separators so one file per width holds the full vocabulary a reviewer eyeballs.
func combinedGolden(width int) string {
	var b strings.Builder
	for i, f := range goldenFixtures() {
		if i > 0 {
			b.WriteString("\n")
		}
		b.WriteString(fmt.Sprintf("═══ %s @ %d ═══\n", f.name, width))
		b.WriteString(plainDetailFrame(f, width))
		b.WriteString("\n")
	}
	return b.String()
}

func TestRenderTaskDetailGoldens(t *testing.T) {
	oldp := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() { lipgloss.SetColorProfile(oldp) })

	for _, width := range []int{60, 80, 100} {
		width := width
		t.Run(fmt.Sprintf("detail_%d", width), func(t *testing.T) {
			got := combinedGolden(width)
			path := filepath.Join("testdata", fmt.Sprintf("detail_%d.txt", width))
			if *update {
				if err := os.WriteFile(path, []byte(got), 0o644); err != nil {
					t.Fatalf("write golden: %v", err)
				}
				return
			}
			want, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("read golden (run with -update to create): %v", err)
			}
			if got != string(want) {
				t.Errorf("frame mismatch at %d cols\n--- got ---\n%s\n--- want ---\n%s", width, got, string(want))
			}
		})
	}
}

// TestDetailMeasureCap pins charter D24: prose wraps at min(width-gutter, 72),
// so at a wide 100-col pane the reading measure caps at 72 and NO rendered
// prose line runs past it. The rich fixture carries multi-line prose plus a
// bulleted list, so its wrapped body lines are the real check.
func TestDetailMeasureCap(t *testing.T) {
	oldp := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() { lipgloss.SetColorProfile(oldp) })

	if got := measure(100); got != detailMeasure {
		t.Fatalf("measure(100) = %d, want %d (the 72-cell cap)", got, detailMeasure)
	}
	if got := measure(80); got != detailMeasure {
		t.Fatalf("measure(80) = %d, want %d", got, detailMeasure)
	}
	if got := measure(60); got != 60-proseGutter {
		t.Fatalf("measure(60) = %d, want %d (below the cap: width-gutter)", got, 60-proseGutter)
	}

	// The rich description's typeset prose lines at a wide 100-col pane must all
	// fit within the 72-cell measure plus their left indent — extra terminal
	// width becomes margin, never an unreadable line.
	d, _ := richDetail()
	limit := detailMeasure + proseIndent
	prose := proseLines(d.Description, 100)
	if len(prose) == 0 {
		t.Fatal("rich description produced no prose lines")
	}
	widest := 0
	for _, ln := range prose {
		if w := disp(ln); w > widest {
			widest = w
		}
		if w := disp(ln); w > limit {
			t.Errorf("prose line %d cols wide (> %d, the 72-cell cap + indent): %q",
				w, limit, ansi.Strip(ln))
		}
	}
	// And the cap actually BITES: some line reaches beyond the 60-col pane's
	// narrower measure, proving 72 (not the pane width) is the ceiling at 100.
	if widest <= measure(60)+proseIndent {
		t.Errorf("widest prose line %d cols never exceeded the 60-col measure — cap not exercised", widest)
	}
}

// TestDetailStopsMatchLines is the load-bearing contract: every Stop.Line
// indexes the returned lines slice exactly, and the row it points at names
// its target.
func TestDetailStopsMatchLines(t *testing.T) {
	oldp := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() { lipgloss.SetColorProfile(oldp) })

	for _, f := range detailFixtures() {
		for _, width := range []int{60, 80, 100} {
			lines, stops := RenderTaskDetail(f.detail, f.children, f.cursor, width, detailNow)
			for i, s := range stops {
				if s.Line < 0 || s.Line >= len(lines) {
					t.Fatalf("%s@%d: stop %d line %d out of range (%d lines)", f.name, width, i, s.Line, len(lines))
				}
				row := ansi.Strip(lines[s.Line])
				// The row must name its target — match on a truncation-proof
				// prefix of the label (child title / paper slug).
				label := s.Label
				if len(label) > 8 {
					label = label[:8]
				}
				if !strings.Contains(row, label) {
					t.Errorf("%s@%d: stop %d (%q) not found on its line %d: %q", f.name, width, i, s.Label, s.Line, row)
				}
				if s.Ref == "" {
					t.Errorf("%s@%d: stop %d has empty Ref", f.name, width, i)
				}
			}
		}
	}
}

// TestDetailCursorSelection walks the cursor over every stop and asserts the
// ▎ selection bar lands on exactly that stop's line — and nowhere else.
func TestDetailCursorSelection(t *testing.T) {
	oldp := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() { lipgloss.SetColorProfile(oldp) })

	for _, f := range detailFixtures() {
		_, stops := RenderTaskDetail(f.detail, f.children, 0, 80, detailNow)
		for cur := range stops {
			lines, st2 := RenderTaskDetail(f.detail, f.children, cur, 80, detailNow)
			if len(st2) != len(stops) {
				t.Fatalf("%s: stop count changed with cursor (%d vs %d)", f.name, len(st2), len(stops))
			}
			var barLines []int
			for i, ln := range lines {
				if strings.Contains(ansi.Strip(ln), "▎") {
					barLines = append(barLines, i)
				}
			}
			if len(barLines) != 1 || barLines[0] != st2[cur].Line {
				t.Errorf("%s cursor=%d: selection bar on lines %v, want exactly [%d]", f.name, cur, barLines, st2[cur].Line)
			}
		}
		// An out-of-range cursor selects nothing.
		lines, _ := RenderTaskDetail(f.detail, f.children, len(stops)+3, 80, detailNow)
		for i, ln := range lines {
			if strings.Contains(ansi.Strip(ln), "▎") {
				t.Errorf("%s: out-of-range cursor still drew a bar on line %d", f.name, i)
			}
		}
	}
}

// TestDetailThinIsThin pins the conditional-section promise: a task with only
// a title and lifecycle renders exactly two lines and zero stops.
func TestDetailThinIsThin(t *testing.T) {
	d, children := thinDetail()
	lines, stops := RenderTaskDetail(d, children, 0, 80, detailNow)
	if len(lines) != 2 {
		t.Fatalf("thin task rendered %d lines, want 2:\n%s", len(lines), strings.Join(lines, "\n"))
	}
	if len(stops) != 0 {
		t.Fatalf("thin task produced %d stops, want 0", len(stops))
	}
	if got := ansi.Strip(lines[0]); !strings.Contains(got, "Sketch the paper rail interaction") {
		t.Errorf("line 0 is not the title: %q", got)
	}
	if got := ansi.Strip(lines[1]); !strings.Contains(got, "open") {
		t.Errorf("line 1 is not the meta line: %q", got)
	}
}

// TestDetailWidthSafety asserts no rendered line ever exceeds its width
// budget — the truncation-never-garbles bar, checked wall-to-wall.
func TestDetailWidthSafety(t *testing.T) {
	oldp := lipgloss.ColorProfile()
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() { lipgloss.SetColorProfile(oldp) })

	for _, f := range detailFixtures() {
		for _, width := range []int{24, 40, 60, 80, 100} {
			lines, _ := RenderTaskDetail(f.detail, f.children, f.cursor, width, detailNow)
			for i, ln := range lines {
				if w := disp(ln); w > width {
					t.Errorf("%s@%d: line %d is %d cols wide: %q", f.name, width, i, w, ansi.Strip(ln))
				}
			}
		}
	}
}

// TestDetailDoneSuppressesLeaseAlarm: a terminal task keeps its claim facts
// but never renders an expired-lease alarm — finished work cannot alarm.
func TestDetailDoneSuppressesLeaseAlarm(t *testing.T) {
	d, children := doneDetail()
	lines, _ := RenderTaskDetail(d, children, 0, 80, detailNow)
	frame := ansi.Strip(strings.Join(lines, "\n"))
	if !strings.Contains(frame, "fable-1") {
		t.Errorf("done task lost its claim facts:\n%s", frame)
	}
	if strings.Contains(frame, "lease expired") || strings.Contains(frame, "expires in") {
		t.Errorf("done task rendered a lease alarm:\n%s", frame)
	}
}

// TestDetailTimelineCloseReason: the done fixture's timeline carries the
// close reason inline; the blocked fixture's strip carries its reason.
func TestDetailReasons(t *testing.T) {
	d, children := doneDetail()
	lines, _ := RenderTaskDetail(d, children, 0, 100, detailNow)
	frame := ansi.Strip(strings.Join(lines, "\n"))
	if !strings.Contains(frame, "done (Jul 03) — shipped in #1067") {
		t.Errorf("timeline missing inline close_reason:\n%s", frame)
	}
	b, bc := blockedDetail()
	lines, _ = RenderTaskDetail(b, bc, 0, 100, detailNow)
	frame = ansi.Strip(strings.Join(lines, "\n"))
	if !strings.Contains(frame, "▍ blocked — waiting on the shared-package extraction") {
		t.Errorf("blocked strip missing:\n%s", frame)
	}
}

// TestDetailHybridStamp pins the shared helper's grammar.
func TestDetailHybridStamp(t *testing.T) {
	cases := []struct {
		t    time.Time
		want string
	}{
		{time.Time{}, ""},
		{detailNow.Add(-30 * time.Second), "just now (Jul 04, 17:29)"},
		{detailNow.Add(-2 * time.Hour), "2h ago (Jul 04, 15:30)"},
		{detailNow.Add(-49 * time.Hour), "2d ago (Jul 02, 16:30)"},
	}
	for _, c := range cases {
		if got := hybridStamp(c.t, detailNow); got != c.want {
			t.Errorf("hybridStamp(%v) = %q, want %q", c.t, got, c.want)
		}
	}
}

// TestPaperRefsContract pins the frozen semantics the stub (and later the
// substrate slice) must honor: design_doc first, ∪ papers[], deduped.
func TestPaperRefsContract(t *testing.T) {
	d := TaskDetail{
		DesignDoc: "charter",
		Papers:    []string{"lessons", "charter", "lessons", "third"},
	}
	got := d.PaperRefs()
	want := []string{"charter", "lessons", "third"}
	if len(got) != len(want) {
		t.Fatalf("PaperRefs = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("PaperRefs = %v, want %v", got, want)
		}
	}
	if refs := (TaskDetail{}).PaperRefs(); len(refs) != 0 {
		t.Fatalf("empty detail returned refs %v", refs)
	}
}

// TestDetailHonestCaps: overlong code_refs and children fold to an
// "… and N more" line instead of silently dropping.
func TestDetailHonestCaps(t *testing.T) {
	d, _ := richDetail()
	d.CodeRefs = nil
	for i := 0; i < codeRefsCap+5; i++ {
		d.CodeRefs = append(d.CodeRefs, fmt.Sprintf("internal/pkg/file_%02d.go", i))
	}
	var children []Task
	for i := 0; i < childRailCap+7; i++ {
		children = append(children, Task{
			DocID: fmt.Sprintf("child-%02d", i), Title: fmt.Sprintf("Child task %02d", i),
			Lifecycle: "ready", UpdatedAt: detailNow.Add(-time.Hour),
		})
	}
	lines, stops := RenderTaskDetail(d, children, 0, 80, detailNow)
	frame := ansi.Strip(strings.Join(lines, "\n"))
	if !strings.Contains(frame, fmt.Sprintf("… and %d more", 5)) {
		t.Errorf("code_refs fold missing:\n%s", frame)
	}
	if !strings.Contains(frame, fmt.Sprintf("… and %d more", 7)) {
		t.Errorf("children fold missing:\n%s", frame)
	}
	// Folded children emit no stops beyond the cap (+ the papers rail).
	childStops := 0
	for _, s := range stops {
		if s.Kind == FrameTask {
			childStops++
		}
	}
	if childStops != childRailCap {
		t.Errorf("child stops = %d, want %d", childStops, childRailCap)
	}
}

// TestDetailDeterministic: two renders of the same inputs are byte-identical
// (pure function, injected clock).
func TestDetailDeterministic(t *testing.T) {
	f := detailFixtures()[0]
	a, _ := RenderTaskDetail(f.detail, f.children, f.cursor, 80, detailNow)
	b, _ := RenderTaskDetail(f.detail, f.children, f.cursor, 80, detailNow)
	if strings.Join(a, "\n") != strings.Join(b, "\n") {
		t.Fatal("RenderTaskDetail is not deterministic")
	}
}
