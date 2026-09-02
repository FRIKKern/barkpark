package chat

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

// fold_test.go — the turn fold, `bp chat` half (task-8f904a88b9bc3d59).
//
// A settled turn's tool rows collapse under ONE header row reading "Worked for
// 3m 12s" (or "You stopped after 42s"); ctrl+f expands them. Every fact the
// fold uses is SERVER-stamped onto the row envelope by
// StudioChat.settle_tool_rows/2 — nothing here derives a duration, an outcome,
// or a turn identity, which is what keeps this surface byte-identical to
// Studio's.

// toolRow is one settled tool row of the named turn. An empty settledAt is a
// LIVE row: the server has not settled the turn, so nothing may fold it.
func toolRow(seq int, label, settledAt, outcome string, durationMS int) Message {
	meta := map[string]any{"output": "ok"}
	if settledAt != "" {
		meta["turn_settled"] = true
		meta["turn_settled_at"] = settledAt
		meta["turn_outcome"] = outcome
		meta["turn_duration_ms"] = durationMS
	}
	return Message{Seq: seq, Role: "tool", SourceMarkdown: label, Metadata: meta}
}

func foldModel(msgs ...Message) Model {
	return Model{width: 80, height: 24, screen: screenChat, st: State{Messages: msgs}}
}

// ── the shared label fixture ────────────────────────────────────────────────

type foldLabelCase struct {
	DurationMS int    `json:"duration_ms"`
	Outcome    string `json:"outcome"`
	Label      string `json:"label"`
}

// TestFoldLabelMatchesTheSharedFixture is the CROSS-SURFACE byte lock. The same
// api/test/support/fixtures/chat_fold_labels.json is read by the Elixir suite
// (chat_fold_on_settle_test.exs) against ChatToolRenderer.fold_label/2, so a
// formatter edit on either surface reds the other one's test — the two
// transcripts cannot drift a single byte apart.
func TestFoldLabelMatchesTheSharedFixture(t *testing.T) {
	path := filepath.Join("..", "..", "api", "test", "support", "fixtures", "chat_fold_labels.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read the shared label fixture: %v", err)
	}
	var fixture struct {
		Cases []foldLabelCase `json:"cases"`
	}
	if err := json.Unmarshal(raw, &fixture); err != nil {
		t.Fatalf("decode the shared label fixture: %v", err)
	}
	if len(fixture.Cases) == 0 {
		t.Fatal("the shared fixture carries no cases — a vacuous lock proves nothing")
	}
	for _, c := range fixture.Cases {
		if got := foldLabelOf(c.Outcome, c.DurationMS); got != c.Label {
			t.Errorf("foldLabelOf(%q, %d) = %q, fixture says %q", c.Outcome, c.DurationMS, got, c.Label)
		}
	}
}

// TestFoldLabelReadsTheEnvelopeNeverTheClock proves the label comes off the
// row's own metadata — the MUTATION target for the duration stamp. Drop
// turn_duration_ms from the server stamp and this test reads "Worked for 0s".
func TestFoldLabelReadsTheEnvelopeNeverTheClock(t *testing.T) {
	settled := toolRow(1, "Read — a.txt", "2026-09-02T10:00:00Z", "settled", 192_000)
	if got := foldLabel(settled); got != "Worked for 3m 12s" {
		t.Fatalf("settled turn label = %q, want %q", got, "Worked for 3m 12s")
	}
	stopped := toolRow(2, "Bash — sleep", "2026-09-02T10:05:00Z", "interrupted", 42_000)
	if got := foldLabel(stopped); got != "You stopped after 42s" {
		t.Fatalf("interrupted turn label = %q, want %q", got, "You stopped after 42s")
	}
	// A server too old to stamp the duration degrades to an honest zero, never a
	// blank header and never a crash.
	thin := Message{Role: "tool", Metadata: map[string]any{"turn_settled": true, "turn_settled_at": "t"}}
	if got := foldLabel(thin); got != "Worked for 0s" {
		t.Fatalf("unstamped duration = %q, want %q", got, "Worked for 0s")
	}
}

// ── the settle gate ─────────────────────────────────────────────────────────

// TestLiveTurnNeverFolds is the SETTLE GATE's named test on this surface: while
// the turn runs, its tool rows never wear a DURATION header. Delete the settle
// gate (fold before settle) and this test reds — the rows vanish behind a
// "Worked for 0s" header mid-turn.
//
// A live turn is no longer rendered flat: show-active-only
// (task-b66928b2958c8cfa) folds the rows BEFORE the active one behind a
// "+N previous" control. That is a DIFFERENT fold with a different header, and
// this test now pins the boundary between the two — a live turn wears the
// running control and never the settled one.
func TestLiveTurnNeverFolds(t *testing.T) {
	m := foldModel(
		toolRow(1, "Read — a.txt", "", "", 0),
		toolRow(2, "Edit — b.txt", "", "", 0),
	)
	lines, _, _ := m.transcriptAnchored(m.width, "")
	out := strings.Join(lines, "\n")
	if strings.Contains(out, "Worked for") || strings.Contains(out, "You stopped after") {
		t.Fatalf("a LIVE turn must never wear a SETTLED fold header:\n%s", out)
	}
	if !strings.Contains(out, "+1 previous") {
		t.Fatalf("a live turn wears the RUNNING control instead:\n%s", out)
	}
	// ctrl+o opens the running control, and the flat transcript it has always
	// shown is still exactly one block per row underneath it.
	nm, _ := m.handleChatKey(tea.KeyMsg{Type: tea.KeyCtrlO})
	m = nm.(Model)
	lines, _, starts := m.transcriptAnchored(m.width, "")
	out = strings.Join(lines, "\n")
	if !strings.Contains(out, "a.txt") || !strings.Contains(out, "b.txt") {
		t.Fatalf("an expanded live turn renders every row:\n%s", out)
	}
	// control + 2 rows
	if len(starts) != 3 {
		t.Fatalf("control + two rows is 3 blocks, got %d", len(starts))
	}
}

// TestSettledTurnFoldsUnderOneHeader is the fold itself: N tool rows of ONE
// settled turn become ONE header block, and the rows are gone from the paint.
func TestSettledTurnFoldsUnderOneHeader(t *testing.T) {
	at := "2026-09-02T10:00:00Z"
	m := foldModel(
		toolRow(1, "Read — a.txt", at, "settled", 192_000),
		toolRow(2, "Edit — b.txt", at, "settled", 192_000),
		toolRow(3, "Bash — make", at, "settled", 192_000),
	)
	lines, _, starts := m.transcriptAnchored(m.width, "")
	out := strings.Join(lines, "\n")
	if !strings.Contains(out, "Worked for 3m 12s") {
		t.Fatalf("the settled turn must fold under its header:\n%s", out)
	}
	if !strings.Contains(out, "3 steps") {
		t.Fatalf("the header must say how many rows it stands for:\n%s", out)
	}
	for _, gone := range []string{"a.txt", "b.txt", "make"} {
		if strings.Contains(out, gone) {
			t.Fatalf("a folded row must not paint (%q survived):\n%s", gone, out)
		}
	}
	if len(starts) != 1 {
		t.Fatalf("a folded turn is ONE block (D80), got %d", len(starts))
	}
}

// TestTwoTurnsFoldSeparately proves the group key is the turn, not "tool rows":
// two settled turns are two headers with their own labels, never one merged
// fold — which is exactly what a per-turn turn_settled_at buys.
func TestTwoTurnsFoldSeparately(t *testing.T) {
	m := foldModel(
		toolRow(1, "Read — a.txt", "2026-09-02T10:00:00Z", "settled", 192_000),
		toolRow(2, "Edit — b.txt", "2026-09-02T10:00:00Z", "settled", 192_000),
		Message{Seq: 3, Role: "user", SourceMarkdown: "and again"},
		toolRow(4, "Bash — make", "2026-09-02T10:30:00Z", "interrupted", 42_000),
	)
	lines, _, starts := m.transcriptAnchored(m.width, "")
	out := strings.Join(lines, "\n")
	if !strings.Contains(out, "Worked for 3m 12s") || !strings.Contains(out, "You stopped after 42s") {
		t.Fatalf("each turn keeps its own header:\n%s", out)
	}
	if !strings.Contains(out, "2 steps") || !strings.Contains(out, "1 step") {
		t.Fatalf("each header counts its OWN rows (and 1 is singular):\n%s", out)
	}
	// fold · user row · fold
	if len(starts) != 3 {
		t.Fatalf("two folds around one user row is 3 blocks, got %d", len(starts))
	}
}

// ── the expand key ──────────────────────────────────────────────────────────

// TestCtrlFExpandsTheFolds pins the expand key: ctrl+f opens every fold (header
// kept, marker flipped, rows back), and a second press closes them again. The
// composer is untouched by either press — ctrl+f is non-printable for exactly
// that reason (the D14 typability law).
func TestCtrlFExpandsTheFolds(t *testing.T) {
	at := "2026-09-02T10:00:00Z"
	m := foldModel(
		toolRow(1, "Read — a.txt", at, "settled", 192_000),
		toolRow(2, "Edit — b.txt", at, "settled", 192_000),
	)
	m.input = "draft survives"

	nm, _ := m.handleChatKey(tea.KeyMsg{Type: tea.KeyCtrlF})
	m = nm.(Model)
	if !m.foldsExpanded {
		t.Fatal("ctrl+f must open the folds")
	}
	if m.input != "draft survives" {
		t.Fatalf("ctrl+f must not touch the composer, got %q", m.input)
	}
	lines, _, starts := m.transcriptAnchored(m.width, "")
	out := strings.Join(lines, "\n")
	if !strings.Contains(out, "Worked for 3m 12s") {
		t.Fatalf("an expanded fold keeps its header:\n%s", out)
	}
	if !strings.Contains(out, "a.txt") || !strings.Contains(out, "b.txt") {
		t.Fatalf("an expanded fold paints its rows:\n%s", out)
	}
	// header + 2 rows, each pushed as its own block so the D80 anchor keeps
	// counting the same units it always did.
	if len(starts) != 3 {
		t.Fatalf("an expanded fold is header+rows = 3 blocks, got %d", len(starts))
	}

	nm, _ = m.handleChatKey(tea.KeyMsg{Type: tea.KeyCtrlF})
	m = nm.(Model)
	if m.foldsExpanded {
		t.Fatal("ctrl+f must close the folds again")
	}
	if strings.Contains(strings.Join(mustLines(m), "\n"), "a.txt") {
		t.Fatal("a re-collapsed fold must hide its rows again")
	}
}

func mustLines(m Model) []string {
	lines, _, _ := m.transcriptAnchored(m.width, "")
	return lines
}
