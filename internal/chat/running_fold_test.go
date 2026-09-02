package chat

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

// running_fold_test.go — SHOW-ACTIVE-ONLY, the `bp chat` half
// (task-b66928b2958c8cfa).
//
// While a turn RUNS the transcript keeps the ACTIVE tool row and folds the rows
// BEFORE it behind one "+N previous" control; ctrl+o expands and re-collapses
// it. Nothing here derives a count or spells a label of its own: the shared
// fixture api/test/support/fixtures/chat_fold_labels.json pins both, and
// chat_fold_on_settle_test.exs drives the Elixir twin off the SAME cases.

// liveRow is one tool row of a RUNNING turn (no settle stamp — so it can never
// wear U1's fold). An empty `output` is a row whose tool_result has not landed:
// still executing.
func liveRow(seq int, label, output string) Message {
	return Message{
		Seq:            seq,
		Role:           "tool",
		SourceMarkdown: label,
		Metadata:       map[string]any{"output": output},
	}
}

// ── the shared count + label fixture ────────────────────────────────────────

type runningCase struct {
	Case       string   `json:"case"`
	RowOutputs []string `json:"row_outputs"`
	Hidden     int      `json:"hidden"`
	Control    *string  `json:"control"`
}

func loadRunningCases(t *testing.T) []runningCase {
	t.Helper()
	path := filepath.Join("..", "..", "api", "test", "support", "fixtures", "chat_fold_labels.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read the shared label fixture: %v", err)
	}
	var fixture struct {
		RunningCases []runningCase `json:"running_cases"`
	}
	if err := json.Unmarshal(raw, &fixture); err != nil {
		t.Fatalf("decode the shared label fixture: %v", err)
	}
	if len(fixture.RunningCases) == 0 {
		t.Fatal("the shared fixture carries no running cases — a vacuous lock proves nothing")
	}
	return fixture.RunningCases
}

// TestRunningHiddenCountMatchesTheSharedFixture is the CROSS-SURFACE lock on N
// AND on the control's wording. The fixture's running_cases carry a 1-row turn
// (N=0, no control), a 4-row turn whose last row still runs (N=3), and a turn
// of parallel calls whose ACTIVE row is the FIRST row (N=0, no control) — the
// three shapes the acceptance criterion names. chat_fold_on_settle_test.exs
// reads the same cases, so a counter or wording change on either surface reds
// the other one's test.
func TestRunningHiddenCountMatchesTheSharedFixture(t *testing.T) {
	sawZero, sawThree := false, false
	for _, c := range loadRunningCases(t) {
		run := make([]Message, 0, len(c.RowOutputs))
		for i, out := range c.RowOutputs {
			run = append(run, liveRow(i+1, "Bash — step", out))
		}
		got := runningHiddenCount(run)
		if got != c.Hidden {
			t.Errorf("%s: runningHiddenCount = %d, fixture says %d", c.Case, got, c.Hidden)
			continue
		}
		switch {
		case c.Control == nil:
			if got != 0 {
				t.Errorf("%s: a fixture case with no control must hide nothing, got N=%d", c.Case, got)
			}
			sawZero = true
		default:
			if label := runningFoldLabel(got); label != *c.Control {
				t.Errorf("%s: runningFoldLabel(%d) = %q, fixture says %q", c.Case, got, label, *c.Control)
			}
			if got == 3 {
				sawThree = true
			}
		}
	}
	// Non-vacuity: the fixture must actually still carry the shapes the
	// criterion names, so a future edit cannot quietly delete them.
	if !sawZero || !sawThree {
		t.Fatalf("the fixture must keep an N=0 case and an N=3 case (saw zero=%v three=%v)", sawZero, sawThree)
	}
}

// TestActiveRowIsTheFirstRowStillAwaitingItsResult pins the RULE the count is
// built on, in all three shapes, off the row envelope and nothing else.
func TestActiveRowIsTheFirstRowStillAwaitingItsResult(t *testing.T) {
	// Sequential: three finished, the fourth in flight.
	run := []Message{
		liveRow(1, "Read — a", "ok"),
		liveRow(2, "Read — b", "ok"),
		liveRow(3, "Read — c", "ok"),
		liveRow(4, "Bash — make", ""),
	}
	if got := runningActiveIndex(run); got != 3 {
		t.Fatalf("the in-flight row is active, got index %d", got)
	}
	// Parallel: nothing has landed, so the FIRST row is the active one.
	parallel := []Message{
		liveRow(1, "Read — a", ""),
		liveRow(2, "Read — b", ""),
		liveRow(3, "Read — c", ""),
	}
	if got := runningActiveIndex(parallel); got != 0 {
		t.Fatalf("with nothing landed the first row is active, got index %d", got)
	}
	if got := runningHiddenCount(parallel); got != 0 {
		t.Fatalf("an active FIRST row hides nothing, got N=%d", got)
	}
	// Every result landed, the turn is still running: the last row is what the
	// reader is watching.
	done := []Message{liveRow(1, "Read — a", "ok"), liveRow(2, "Read — b", "ok")}
	if got := runningActiveIndex(done); got != 1 {
		t.Fatalf("with every result landed the last row is active, got index %d", got)
	}
	// An empty run has no active row and must not index off the end.
	if got := runningActiveIndex(nil); got != 0 {
		t.Fatalf("an empty run answers 0, got %d", got)
	}
}

// ── the render ──────────────────────────────────────────────────────────────

// TestRunningTurnKeepsOnlyTheActiveRow is the paint: three finished rows vanish
// behind ONE "+3 previous" control and the row in flight stays on screen.
func TestRunningTurnKeepsOnlyTheActiveRow(t *testing.T) {
	m := foldModel(
		liveRow(1, "Read — a.txt", "ok"),
		liveRow(2, "Edit — b.txt", "ok"),
		liveRow(3, "Read — c.txt", "ok"),
		liveRow(4, "Bash — make", ""),
	)
	lines, _, starts := m.transcriptAnchored(m.width, "")
	out := strings.Join(lines, "\n")
	if !strings.Contains(out, "+3 previous") {
		t.Fatalf("the running turn must wear its control:\n%s", out)
	}
	if !strings.Contains(out, "make") {
		t.Fatalf("the ACTIVE row must stay on screen:\n%s", out)
	}
	for _, gone := range []string{"a.txt", "b.txt", "c.txt"} {
		if strings.Contains(out, gone) {
			t.Fatalf("an earlier row must not paint (%q survived):\n%s", gone, out)
		}
	}
	// control + the active row
	if len(starts) != 2 {
		t.Fatalf("a collapsed running turn is control+active = 2 blocks, got %d", len(starts))
	}
}

// TestSettledTurnIsNotTouchedByTheRunningFold is the MUTATION target for the
// running GATE. Remove the "this turn has not settled" condition and a settled
// turn collapses to its active row too — losing U1's "Worked for …" header,
// which this test names.
func TestSettledTurnIsNotTouchedByTheRunningFold(t *testing.T) {
	at := "2026-09-02T10:00:00Z"
	m := foldModel(
		toolRow(1, "Read — a.txt", at, "settled", 192_000),
		toolRow(2, "Edit — b.txt", at, "settled", 192_000),
		toolRow(3, "Bash — make", at, "settled", 192_000),
	)
	lines, _, _ := m.transcriptAnchored(m.width, "")
	out := strings.Join(lines, "\n")
	if !strings.Contains(out, "Worked for 3m 12s") {
		t.Fatalf("a SETTLED turn keeps U1's header — the running fold is not its owner:\n%s", out)
	}
	if strings.Contains(out, " previous") {
		t.Fatalf("a SETTLED turn must never wear the running control:\n%s", out)
	}
}

// TestSettledButUnstampedRowStaysFlat is U1's forward-compatible degrade, held
// from this side: a row a server too old to stamp the fold facts settled has no
// fold key, so U1 leaves it FLAT — and it must not fall through to the RUNNING
// collapse instead. The gate is `turn_settled`, never the fold key.
func TestSettledButUnstampedRowStaysFlat(t *testing.T) {
	thin := func(seq int, label, output string) Message {
		return Message{Seq: seq, Role: "tool", SourceMarkdown: label,
			Metadata: map[string]any{"turn_settled": true, "output": output}}
	}
	m := foldModel(thin(1, "Read — a.txt", "ok"), thin(2, "Edit — b.txt", "ok"), thin(3, "Bash — make", ""))
	lines, _, starts := m.transcriptAnchored(m.width, "")
	out := strings.Join(lines, "\n")
	if strings.Contains(out, "previous") || strings.Contains(out, "Worked for") {
		t.Fatalf("an unstamped settled turn wears NO header of either kind:\n%s", out)
	}
	for _, want := range []string{"a.txt", "b.txt", "make"} {
		if !strings.Contains(out, want) {
			t.Fatalf("every row of an unstamped settled turn paints (%q missing):\n%s", want, out)
		}
	}
	if len(starts) != 3 {
		t.Fatalf("three flat rows is 3 blocks, got %d", len(starts))
	}
}

// TestOneRowRunningTurnDrawsNoControl — nothing is hidden, so nothing is drawn.
func TestOneRowRunningTurnDrawsNoControl(t *testing.T) {
	m := foldModel(liveRow(1, "Bash — make", ""))
	lines, _, starts := m.transcriptAnchored(m.width, "")
	out := strings.Join(lines, "\n")
	if strings.Contains(out, "previous") {
		t.Fatalf("a one-row turn hides nothing and draws no control:\n%s", out)
	}
	if !strings.Contains(out, "make") {
		t.Fatalf("the only row must paint:\n%s", out)
	}
	if len(starts) != 1 {
		t.Fatalf("one unfolded row is one block, got %d", len(starts))
	}
}

// TestCtrlOExpandsTheRunningFold pins the expand key: ctrl+o shows every row of
// the running turn (control kept, marker flipped), a second press re-collapses,
// and the composer is untouched by either press (the D14 typability law).
func TestCtrlOExpandsTheRunningFold(t *testing.T) {
	m := foldModel(
		liveRow(1, "Read — a.txt", "ok"),
		liveRow(2, "Edit — b.txt", "ok"),
		liveRow(3, "Bash — make", ""),
	)
	m.input = "draft survives"

	nm, _ := m.handleChatKey(tea.KeyMsg{Type: tea.KeyCtrlO})
	m = nm.(Model)
	if !m.runningFoldExpanded {
		t.Fatal("ctrl+o must open the running fold")
	}
	if m.input != "draft survives" {
		t.Fatalf("ctrl+o must not touch the composer, got %q", m.input)
	}
	lines, _, starts := m.transcriptAnchored(m.width, "")
	out := strings.Join(lines, "\n")
	if !strings.Contains(out, "+2 previous") {
		t.Fatalf("an expanded running fold keeps its control:\n%s", out)
	}
	for _, want := range []string{"a.txt", "b.txt", "make"} {
		if !strings.Contains(out, want) {
			t.Fatalf("an expanded running fold paints every row (%q missing):\n%s", want, out)
		}
	}
	// control + 3 rows, each its own block so the D80 anchor keeps counting the
	// same units it always did.
	if len(starts) != 4 {
		t.Fatalf("an expanded running fold is control+rows = 4 blocks, got %d", len(starts))
	}

	nm, _ = m.handleChatKey(tea.KeyMsg{Type: tea.KeyCtrlO})
	m = nm.(Model)
	if m.runningFoldExpanded {
		t.Fatal("ctrl+o must close the running fold again")
	}
	out = strings.Join(mustLines(m), "\n")
	if strings.Contains(out, "a.txt") {
		t.Fatalf("a re-collapsed running fold hides its earlier rows again:\n%s", out)
	}
	if !strings.Contains(out, "make") {
		t.Fatalf("a re-collapsed running fold still shows the ACTIVE row:\n%s", out)
	}
}
