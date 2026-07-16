package chat

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/pdrender"
)

// render_test.go — the projection proofs. The load-bearing one is D10: each
// settled assistant message renders as its OWN document (one RenderDoc call), so
// "Figure N." numbering RESETS per message. The golden-parity harness diffs
// exactly this assistant-body projection; cards/tail/user echoes are out of
// scope and only proven not to crash or scope-creep.

// figureDoc is a one-figure document (an ascii diagram, which carries a
// "Figure N." caption). Two of these rendered as separate messages must BOTH
// caption "Figure 1." — the per-message reset.
func figureBlocks(caption string) json.RawMessage {
	doc := map[string]any{
		"blocks": []any{
			map[string]any{
				"type":    "figure",
				"caption": caption,
				"child":   map[string]any{"type": "paragraph", "content": []any{map[string]any{"type": "text", "value": "body"}}},
			},
		},
	}
	raw, _ := json.Marshal(doc)
	return raw
}

// TestFigureNumberingResetsPerMessage is the D10 proof: two assistant messages
// each rendered via their own RenderDoc call both start at "Figure 1.", instead
// of the second continuing to "Figure 2." as it would in one shared document.
func TestFigureNumberingResetsPerMessage(t *testing.T) {
	reg := pdrender.DefaultRegistry(pdrender.DarkTheme())
	m1 := Message{Role: "assistant", Blocks: figureBlocks("first")}
	m2 := Message{Role: "assistant", Blocks: figureBlocks("second")}

	out1 := strings.Join(renderAssistantDoc(reg, 80, m1), "\n")
	out2 := strings.Join(renderAssistantDoc(reg, 80, m2), "\n")

	if !strings.Contains(out1, "Figure 1.") {
		t.Fatalf("first message should caption Figure 1., got:\n%s", out1)
	}
	if !strings.Contains(out2, "Figure 1.") {
		t.Fatalf("second message must RESET to Figure 1. (per-message document, D10), got:\n%s", out2)
	}
	if strings.Contains(out2, "Figure 2.") {
		t.Fatal("figure numbering must NOT continue across messages (D10 per-message reset)")
	}
}

// TestAssistantEmptyBlocksFallBackToSource proves a mid-persist assistant row
// (blocks not yet computed) renders its source_markdown instead of a blank.
func TestAssistantEmptyBlocksFallBackToSource(t *testing.T) {
	m := Message{Role: "assistant", SourceMarkdown: "raw reply text"}
	out := strings.Join(renderAssistantDoc(chatRegistry, 80, m), "\n")
	if !strings.Contains(out, "raw reply") {
		t.Fatalf("empty-blocks assistant must fall back to source markdown, got:\n%s", out)
	}
}

// TestCardRolesRenderLabels proves the approval/question/plan rows carry their
// card label. A row with no request_id is not answerable and honestly reads
// read-only (the malformed/legacy fallback).
func TestCardRolesRenderLabels(t *testing.T) {
	for role, label := range cardRoles {
		m := Message{Role: role, SourceMarkdown: "please approve running rm -rf"}
		out := strings.Join(renderMessage(80, m, false, ""), "\n")
		if !strings.Contains(out, label) {
			t.Fatalf("%s row must carry its card label %q, got:\n%s", role, label, out)
		}
		if !strings.Contains(out, "read-only") {
			t.Fatalf("%s card with no request_id must read read-only, got:\n%s", role, out)
		}
	}
}

// pendingCard is a pending, answerable card fixture (request_id + pending status
// in metadata — the shape the Recorder persists via persist_approval_ask).
func pendingCard(role string) Message {
	return Message{
		Seq:            7,
		Role:           role,
		SourceMarkdown: "run `rm -rf build`?",
		Metadata: map[string]any{
			"request_id":      "req-1",
			"approval_status": "pending",
		},
	}
}

// TestPendingCardShowsAnswerAffordance proves a pending card advertises the
// answer keys, and a FOCUSED one is marked so the operator sees which card a
// keystroke acts on. Plan cards read approve/keep-planning; the others allow/deny.
func TestPendingCardShowsAnswerAffordance(t *testing.T) {
	for role := range cardRoles {
		out := strings.Join(renderMessage(80, pendingCard(role), false, ""), "\n")
		if !strings.Contains(out, "ctrl+a") || !strings.Contains(out, "ctrl+r") {
			t.Fatalf("%s pending card must advertise the answer keys, got:\n%s", role, out)
		}
		if strings.Contains(out, "read-only") {
			t.Fatalf("%s pending card must NOT read read-only (it is answerable), got:\n%s", role, out)
		}
		allow, deny := cardVerbs(role)
		if !strings.Contains(out, allow) || !strings.Contains(out, deny) {
			t.Fatalf("%s card must name its verbs %q/%q, got:\n%s", role, allow, deny, out)
		}
		// A focused card is visibly marked.
		fout := strings.Join(renderMessage(80, pendingCard(role), true, ""), "\n")
		if !strings.Contains(fout, "focused") {
			t.Fatalf("%s focused card must be marked focused, got:\n%s", role, fout)
		}
	}
	// Plan cards specifically read approve / keep planning (charter D27).
	plan := strings.Join(renderMessage(80, pendingCard("plan"), true, ""), "\n")
	if !strings.Contains(plan, "approve") || !strings.Contains(plan, "keep planning") {
		t.Fatalf("plan card must read approve/keep-planning, got:\n%s", plan)
	}
}

// TestResolvedCardShowsBadge proves a card whose approval_status flipped to a
// terminal state (a Studio answer, or this TUI's own answer landing on refetch)
// shows the resolution badge instead of the answer affordance — one Postgres
// truth, both surfaces (Law-2).
func TestResolvedCardShowsBadge(t *testing.T) {
	cases := map[string]string{"allowed": "allowed", "denied": "denied", "canceled": "canceled"}
	for status, want := range cases {
		m := pendingCard("approval")
		m.Metadata["approval_status"] = status
		out := strings.Join(renderMessage(80, m, false, ""), "\n")
		if !strings.Contains(out, want) {
			t.Fatalf("a %s card must show its resolution badge, got:\n%s", status, out)
		}
		if strings.Contains(out, "ctrl+a") {
			t.Fatalf("a resolved (%s) card must NOT offer the answer keys, got:\n%s", status, out)
		}
	}
}

// TestInFlightCardShowsAnsweringState proves the immediate-feedback layer: a card
// whose answer is POSTed but not yet confirmed reads "answering…" rather than the
// affordance or a premature terminal badge.
func TestInFlightCardShowsAnsweringState(t *testing.T) {
	out := strings.Join(renderMessage(80, pendingCard("approval"), true, "allow"), "\n")
	if !strings.Contains(out, "allowing") {
		t.Fatalf("an in-flight allow must read 'allowing…', got:\n%s", out)
	}
}

// TestQueuedLocalSendBadged proves the ⧗ queued badge on an optimistic mid-turn
// send (D12 render side).
func TestQueuedLocalSendBadged(t *testing.T) {
	out := strings.Join(renderLocalSend(40, LocalSend{Content: "later", Queued: true}), "\n")
	if !strings.Contains(out, "⧗ queued") {
		t.Fatalf("a queued local send must show the badge, got:\n%s", out)
	}
	out = strings.Join(renderLocalSend(40, LocalSend{Content: "now", Queued: false}), "\n")
	if strings.Contains(out, "queued") {
		t.Fatalf("an un-queued send must NOT show the badge, got:\n%s", out)
	}
}

// TestWindowFollowsBottom proves the manual line-slice viewport: follow mode
// (scroll<0) pins the last `height` lines; a pinned top shows from that index.
func TestWindowFollowsBottom(t *testing.T) {
	lines := []string{"0", "1", "2", "3", "4", "5"}

	// follow → the last 3 lines.
	got := window(lines, 3, -1)
	if strings.Join(got, ",") != "3,4,5" {
		t.Fatalf("follow mode must pin to the bottom, got %v", got)
	}
	// pinned top at 1 → lines 1..3.
	got = window(lines, 3, 1)
	if strings.Join(got, ",") != "1,2,3" {
		t.Fatalf("pinned scroll must window from the top index, got %v", got)
	}
	// an over-large top clamps to the bottom (follow).
	got = window(lines, 3, 99)
	if strings.Join(got, ",") != "3,4,5" {
		t.Fatalf("an over-large scroll must clamp to the bottom, got %v", got)
	}
	// fewer lines than the viewport → all of them.
	got = window([]string{"a", "b"}, 5, 0)
	if strings.Join(got, ",") != "a,b" {
		t.Fatalf("short content returns as-is, got %v", got)
	}
}

// TestRailBandRendersEntries proves the agents rail band paints one row per
// decoded entry with its status label and token count, and shows nothing for an
// empty rail (honest absence, not an empty box).
func TestRailBandRendersEntries(t *testing.T) {
	if renderRail(80, nil) != nil {
		t.Fatal("an empty rail must render no band")
	}
	rail := []RailEntry{
		{TaskID: "t1", Status: "completed", Label: "survey", Tokens: 1500, HasTokens: true},
		{TaskID: "t2", Status: "running", Label: "build"},
	}
	out := strings.Join(renderRail(80, rail), "\n")
	if !strings.Contains(out, "agents") {
		t.Fatalf("rail band must be headed 'agents', got:\n%s", out)
	}
	if !strings.Contains(out, "survey") || !strings.Contains(out, "build") {
		t.Fatalf("rail band must list each entry's label, got:\n%s", out)
	}
	if !strings.Contains(out, "done") || !strings.Contains(out, "running") {
		t.Fatalf("rail band must show each entry's status, got:\n%s", out)
	}
	if !strings.Contains(out, "1.5k") {
		t.Fatalf("rail band must show token usage (1.5k), got:\n%s", out)
	}
}

// TestRailBandEatsTranscriptHeight proves the rail band is a fixed band that
// reduces the transcript viewport rather than overrunning the frame — the
// composer keeps its stable bottom seat.
func TestRailBandEatsTranscriptHeight(t *testing.T) {
	msgs := make([]Message, 0, 40)
	for i := 1; i <= 40; i++ {
		msgs = append(msgs, Message{Seq: i, Role: "user", SourceMarkdown: "line"})
	}
	withRail := Model{width: 80, height: 24, screen: screenChat, scroll: -1,
		st: State{Messages: msgs, Rail: []RailEntry{{TaskID: "t1", Status: "running", Label: "a"}}}}
	noRail := withRail
	noRail.st.Rail = nil
	if lines := strings.Count(withRail.renderChat(), "\n"); lines != strings.Count(noRail.renderChat(), "\n") {
		t.Fatalf("rail must keep the total frame height stable (with=%d without=%d)",
			strings.Count(withRail.renderChat(), "\n"), strings.Count(noRail.renderChat(), "\n"))
	}
}

// TestFooterAdvertisesPendingCard proves the answer affordance is discoverable
// from the footer even when the card scrolled out of view.
func TestFooterAdvertisesPendingCard(t *testing.T) {
	m := Model{width: 80, height: 24, screen: screenChat,
		st: State{Messages: []Message{pendingCard("approval")}}}
	foot := m.chatFooter()
	if !strings.Contains(foot, "card waiting") || !strings.Contains(foot, "ctrl+a") {
		t.Fatalf("footer must advertise a pending card's answer keys, got:\n%s", foot)
	}
}

// ── wsc-s4: the epic-cycle session-card lines ────────────────────────────────

// loadWorkflowFixture decodes one shared D3 workflow-summary fixture (the same
// shape wsc-s1 mirrors to testdata/) into the aliased wire type. This is the
// mechanism-A field-projection seam: decode → assert the projected fields, never
// a byte-diff and never an extension of the pdrender D13 reply-body harness.
func loadWorkflowFixture(t *testing.T, name string) SessionWorkflow {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatalf("read fixture %s: %v", name, err)
	}
	var wf SessionWorkflow
	if err := json.Unmarshal(raw, &wf); err != nil {
		t.Fatalf("decode fixture %s: %v", name, err)
	}
	return wf
}

// loadSharedSummaries decodes wsc-s1's SHARED parity fixture — the byte-mirror
// of api/test/support/fixtures/workflow_summary/workflow_summary.json, real
// workflow_summary/1 folds of the two committed epic-cycle captures. THE
// mechanism-A seam: the Elixir side proves the bytes fresh; this side proves
// they decode onto the wire struct with every rendered field intact.
func loadSharedSummaries(t *testing.T) map[string]SessionWorkflow {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", "workflow_summary.json"))
	if err != nil {
		t.Fatalf("read shared fixture: %v", err)
	}
	var m map[string]SessionWorkflow
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("decode shared fixture: %v", err)
	}
	return m
}

// validTickStates is the six-state journey vocabulary (charter D58) every wire
// tick must speak — the render tolerates unknowns, but the parity fixtures may
// never drift outside the truth table.
var validTickStates = map[string]bool{
	"done": true, "active": true, "interrupted": true,
	"future": true, "skipped": true, "unreached": true,
}

// TestWorkflowSummaryFieldProjection is the Go↔Elixir parity proof (wsc D12,
// mechanism-A): decoding wsc-s1's shared D3 fixtures — the REAL Elixir folds of
// the committed epic-cycle captures — projects exactly the fields the session
// card renders, with the wave-11 invariants intact (seven ticks, settled ≤
// total, terminal ⇒ an honest lifecycle word). No byte-diff; the fold lives on
// the server, this side only decodes.
func TestWorkflowSummaryFieldProjection(t *testing.T) {
	shared := loadSharedSummaries(t)

	cases := []struct {
		key         string
		phase       string
		phaseIndex  int
		agentsDone  int
		agentsTotal int
		running     int
		terminal    bool
		outcome     string
		tokens      int
		ticks       []string
	}{
		{
			key: "epic_cycle_progress", phase: "", phaseIndex: 0,
			agentsDone: 29, agentsTotal: 29, running: 0,
			terminal: true, outcome: "completed", tokens: 2137873,
			ticks: []string{"done", "done", "done", "done", "done", "done", "done"},
		},
		{
			key: "epic_cycle_interrupted", phase: "Explore", phaseIndex: 2,
			agentsDone: 1, agentsTotal: 5, running: 4,
			terminal: true, outcome: "interrupted", tokens: 68272,
			ticks: []string{"done", "interrupted", "unreached", "unreached", "unreached", "unreached", "unreached"},
		},
	}
	for _, tc := range cases {
		t.Run(tc.key, func(t *testing.T) {
			wf, ok := shared[tc.key]
			if !ok {
				t.Fatalf("shared fixture must carry %q", tc.key)
			}
			if wf.Label == "" {
				t.Errorf("label must project (opaque 'slug — one-liner'), got empty")
			}
			if len(wf.Ticks) != 7 {
				t.Fatalf("expected seven phase ticks, got %d: %v", len(wf.Ticks), wf.Ticks)
			}
			for i, s := range wf.Ticks {
				if !validTickStates[s] {
					t.Errorf("tick state must speak the D58 vocabulary, got %q", s)
				}
				if s != tc.ticks[i] {
					t.Errorf("tick %d = %q, want %q", i, s, tc.ticks[i])
				}
			}
			if wf.Phase != tc.phase || wf.PhaseIndex != tc.phaseIndex {
				t.Errorf("phase = %q/%d, want %q/%d", wf.Phase, wf.PhaseIndex, tc.phase, tc.phaseIndex)
			}
			if wf.AgentsDone != tc.agentsDone || wf.AgentsTotal != tc.agentsTotal {
				t.Errorf("agents = %d/%d, want %d/%d", wf.AgentsDone, wf.AgentsTotal, tc.agentsDone, tc.agentsTotal)
			}
			if wf.AgentsDone > wf.AgentsTotal {
				t.Errorf("settled (%d) must never exceed total (%d)", wf.AgentsDone, wf.AgentsTotal)
			}
			if wf.Running != tc.running {
				t.Errorf("running = %d, want %d", wf.Running, tc.running)
			}
			if wf.Terminal != tc.terminal {
				t.Errorf("terminal? = %v, want %v", wf.Terminal, tc.terminal)
			}
			if wf.Outcome != tc.outcome {
				t.Errorf("outcome = %q, want %q", wf.Outcome, tc.outcome)
			}
			if wf.Tokens != tc.tokens {
				t.Errorf("tokens = %d, want %d", wf.Tokens, tc.tokens)
			}
			// timestamps are wire-read epoch ms — present here, never a string
			if wf.StartedAt == nil || *wf.StartedAt <= 0 {
				t.Errorf("started_at must decode as epoch ms, got %v", wf.StartedAt)
			}
			if wf.EndedAt != nil {
				t.Errorf("ended_at is honestly nil until the D5 stamp, got %v", *wf.EndedAt)
			}
		})
	}
}

// TestSessionSummaryDecodesWorkflow proves the compact summary rides on the
// ChatSessionSummary list wire (nested `workflow` key, SIBLING `epic` key — the
// exact bytes sidebar_json emits) and decodes through the alias — the fields
// the picker reads. A plain session (no keys) decodes to nil Workflow/Epic, the
// compile-time signal that the row renders as today.
func TestSessionSummaryDecodesWorkflow(t *testing.T) {
	withWF := []byte(`{"id":"s1","title":"cycle","message_count":3,
		"workflow":{"ticks":["done","active","future"],"phase":"Survey",
		"agents_done":5,"agents_total":17,"running":12,"terminal?":false,
		"outcome":"live","started_at":1783633546962,"ended_at":null},
		"epic":{"id":"task-x","title":"Epic Cycle","slices_done":2,
		"slices_total":5,"wave_status":"wave: building 5 slices"}}`)
	var s SessionSummary
	if err := json.Unmarshal(withWF, &s); err != nil {
		t.Fatalf("decode summary: %v", err)
	}
	if s.Workflow == nil {
		t.Fatal("workflow summary must decode onto the list summary")
	}
	if s.Workflow.AgentsDone != 5 || s.Workflow.AgentsTotal != 17 {
		t.Fatalf("counter must project, got %d/%d", s.Workflow.AgentsDone, s.Workflow.AgentsTotal)
	}
	if s.Workflow.Terminal || s.Workflow.Outcome != "live" {
		t.Fatalf("lifecycle must project (terminal?/outcome), got %v/%q", s.Workflow.Terminal, s.Workflow.Outcome)
	}
	if s.Workflow.StartedAt == nil || *s.Workflow.StartedAt != 1783633546962 {
		t.Fatalf("started_at must decode as epoch ms, got %v", s.Workflow.StartedAt)
	}
	if s.Epic == nil || s.Epic.SlicesDone != 2 || s.Epic.SlicesTotal != 5 {
		t.Fatalf("sibling epic goal must project, got %+v", s.Epic)
	}
	if s.Epic.WaveStatus != "wave: building 5 slices" {
		t.Fatalf("wave_status heartbeat must project, got %q", s.Epic.WaveStatus)
	}

	plain := []byte(`{"id":"s2","title":"chat","message_count":1}`)
	var p SessionSummary
	if err := json.Unmarshal(plain, &p); err != nil {
		t.Fatalf("decode plain: %v", err)
	}
	if p.Workflow != nil || p.Epic != nil {
		t.Fatal("a plain session must decode to nil workflow/epic (renders as today)")
	}
}

// TestWorkflowCardLinesRender proves the two card lines paint from the decoded
// summary: seven glyphs, the settled/total counter, the phase word (or the
// terminal outcome), the token total, and the epic-goal line when present. This
// is what makes '13/17 agents done' visible in the session list.
func TestWorkflowCardLinesRender(t *testing.T) {
	wf := loadWorkflowFixture(t, "workflow_building.json")
	epic := &EpicGoal{ID: "task-x", Title: "Epic Cycle chat", SlicesDone: 2, SlicesTotal: 5,
		WaveStatus: "wave: building 5 slices"}
	lines := workflowCardLines(80, &wf, epic)
	if len(lines) != 2 {
		t.Fatalf("a workflow row with an epic goal grows two lines, got %d:\n%v", len(lines), lines)
	}
	out := strings.Join(lines, "\n")
	if !strings.Contains(out, "13/17") {
		t.Errorf("tick line must carry the settled/total counter 13/17, got:\n%s", out)
	}
	if !strings.Contains(out, "Build") {
		t.Errorf("tick line must carry the active phase word, got:\n%s", out)
	}
	if !strings.Contains(out, "●") || !strings.Contains(out, "◉") || !strings.Contains(out, "○") {
		t.Errorf("tick line must draw done/active/future glyphs, got:\n%s", out)
	}
	if !strings.Contains(out, "1.5M") {
		t.Errorf("tick line must render wire-carried tokens (1.5M), got:\n%s", out)
	}
	if !strings.Contains(out, "2/5 slices") {
		t.Errorf("epic-goal line must carry the slices counter, got:\n%s", out)
	}
	if !strings.Contains(out, "wave: building 5 slices") {
		t.Errorf("epic-goal line must carry the wave_status heartbeat, got:\n%s", out)
	}

	// A terminal wave settles honestly to its lifecycle word, never a stuck
	// phase — straight off s1's shared interrupted fold.
	interrupted := loadSharedSummaries(t)["epic_cycle_interrupted"]
	iout := strings.Join(workflowCardLines(80, &interrupted, nil), "\n")
	if !strings.Contains(iout, "interrupted") {
		t.Errorf("an interrupted wave must render 'interrupted', got:\n%s", iout)
	}
	if !strings.Contains(iout, "✕") {
		t.Errorf("the dead-frontier tick must render the interrupted glyph, got:\n%s", iout)
	}
	// No epic goal → exactly one line (no fabricated goal line).
	if got := len(workflowCardLines(80, &interrupted, nil)); got != 1 {
		t.Errorf("a goal-less workflow row grows exactly one line, got %d", got)
	}

	// A nil summary adds nothing — the minimalism contract.
	if workflowCardLines(80, nil, epic) != nil {
		t.Fatal("a nil workflow summary must add no lines (even with a stray epic)")
	}
}

// TestPhaseTicksFallback proves the presentation-only geometry fallback: a
// summary that carries no explicit ticks still shows an honest strip derived
// from phase_index/phases_total (NOT a rail fold) — done before the active phase,
// active at it, future after.
func TestPhaseTicksFallback(t *testing.T) {
	// phase_index is 1-based on the wire (the journey's phase index): index 2
	// means the SECOND phase breathes.
	wf := SessionWorkflow{PhaseIndex: 2, PhasesTotal: 5}
	ticks := phaseTicks(&wf)
	if len(ticks) != 5 {
		t.Fatalf("derived ticks must honour phases_total, got %d", len(ticks))
	}
	want := []string{"done", "active", "future", "future", "future"}
	for i := range want {
		if ticks[i] != want[i] {
			t.Fatalf("derived ticks = %v, want %v", ticks, want)
		}
	}
	// A terminal wave with no ticks settles all done (never a stuck active tick).
	term := phaseTicks(&SessionWorkflow{PhaseIndex: 3, PhasesTotal: 4, Terminal: true})
	for i, s := range term {
		if s != "done" {
			t.Fatalf("terminal fallback tick %d must be done, got %q", i, s)
		}
	}
}

// TestPickerRowsWorkflowMultiline proves a workflow session's picker row spans
// the two extra lines (so the list expands in height to show fleet progress),
// while a plain session's row is UNCHANGED — byte-identical to the pre-wsc render
// (the minimalism contract: plain chats pay zero).
func TestPickerRowsWorkflowMultiline(t *testing.T) {
	wf := loadWorkflowFixture(t, "workflow_building.json")
	m := Model{width: 80, sessions: []SessionSummary{
		{ID: "plain", Title: "just a chat", MessageCount: 4},
		{ID: "cycle", Title: "epic cycle run", MessageCount: 9, Workflow: &wf,
			Epic: &EpicGoal{Title: "Epic Cycle chat", SlicesDone: 2, SlicesTotal: 5}},
	}}
	rows := m.pickerRows()
	if len(rows) != 3 { // "+ new session" + two sessions
		t.Fatalf("one navigable row per session (+ new), got %d", len(rows))
	}

	// Plain row: exactly the legacy single-line shape, no embedded newline.
	plainRow := rows[1]
	if strings.Contains(plainRow, "\n") {
		t.Fatalf("a plain session row must stay single-line, got:\n%q", plainRow)
	}
	wantPlain := "just a chat" // the legacy %-40s title + meta; assert it is byte-for-byte the old shape
	if !strings.HasPrefix(plainRow, wantPlain) {
		t.Fatalf("plain row must render as today, got:\n%q", plainRow)
	}
	legacy := legacyPickerRow(m.sessions[0])
	if plainRow != legacy {
		t.Fatalf("plain row must be byte-identical to the pre-wsc render.\n got: %q\nwant: %q", plainRow, legacy)
	}

	// Workflow row: three physical lines (title + tick line + goal line), and it
	// is still ONE navigable entry (cursor stops once).
	wfRow := rows[2]
	if n := strings.Count(wfRow, "\n"); n != 2 {
		t.Fatalf("a workflow row (with goal) spans three lines, got %d newlines:\n%q", n, wfRow)
	}
	if !strings.Contains(wfRow, "13/17") {
		t.Fatalf("workflow row must surface the fleet counter, got:\n%q", wfRow)
	}
}

// legacyPickerRow reproduces the exact pre-wsc single-line row shape — the frozen
// baseline the byte-identical proof asserts a plain (workflow-less) session still
// renders. If pickerRows ever changed a plain row, this diverges and the test above
// fails.
func legacyPickerRow(s SessionSummary) string {
	title := strings.TrimSpace(s.Title)
	if title == "" {
		title = "untitled session"
	}
	meta := fmt.Sprintf("%d msg", s.MessageCount)
	if s.PendingApprovals > 0 {
		meta += fmt.Sprintf(" · %d pending", s.PendingApprovals)
	}
	if age := relTime(s.LastActiveAt); age != "" {
		meta += " · " + age
	}
	return fmt.Sprintf("%-40s %s", truncate(title, 40), dimStyle.Render(meta))
}

// TestTranscriptOrdering proves the transcript stacks settled messages, then
// optimistic local sends, then the live tail — the reading order a person sees.
func TestTranscriptOrdering(t *testing.T) {
	m := Model{st: State{
		Messages: []Message{{Seq: 1, Role: "user", SourceMarkdown: "hello"}},
		Local:    []LocalSend{{Content: "pending"}},
		Tail:     "streaming reply",
	}}
	out := strings.Join(m.transcriptLines(80), "\n")
	iHello := strings.Index(out, "hello")
	iPending := strings.Index(out, "pending")
	iTail := strings.Index(out, "streaming reply")
	if !(iHello < iPending && iPending < iTail) {
		t.Fatalf("order must be settled → local → tail, got hello=%d pending=%d tail=%d\n%s", iHello, iPending, iTail, out)
	}
}

// ── the below-composer workflow panel (wave session-card charter D13–D15) ────

// stripModel builds a conversation model over a rail fixture at a fixed clock
// (90s after the run's min startedAt).
func stripModel(t *testing.T, fixture string) Model {
	t.Helper()
	raw, err := os.ReadFile("testdata/" + fixture)
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	m := Model{width: 80, height: 24, screen: screenChat, scroll: -1,
		st: State{SessionID: "s1", Workflow: decodeWorkflow(raw)}}
	m.now = func() time.Time { return time.UnixMilli(1782767557221).Add(90 * time.Second) }
	return m
}

// TestWorkflowStripRendersCounters: the collapsed strip carries the label, the
// Claude-Code-style settled counter, the live elapsed (now − min startedAt),
// and the settle-on-state token floor — all from wire figures.
func TestWorkflowStripRendersCounters(t *testing.T) {
	m := stripModel(t, "rail_workflow_live.json")
	panel := m.workflowPanelLines()
	if len(panel) != 1 {
		t.Fatalf("a collapsed live workflow must render exactly the strip, got %d lines", len(panel))
	}
	strip := panel[0]
	for _, want := range []string{"core-auth-phases-2-5", "23/28 agents done", "1m30s", "↓1.6M"} {
		if !strings.Contains(strip, want) {
			t.Fatalf("strip must contain %q, got:\n%s", want, strip)
		}
	}
	if !strings.Contains(strip, "○") {
		t.Fatalf("an unfocused strip wears the ○ glyph, got:\n%s", strip)
	}
	// focused → the ❯ affordance so the operator sees which zone the arrows drive
	m.focus = focusWorkflow
	if got := m.workflowPanelLines()[0]; !strings.Contains(got, "❯") {
		t.Fatalf("a focused strip must highlight, got:\n%s", got)
	}
}

// TestWorkflowStripOmitsAbsentFigures is the D15 honesty proof: a workflow
// whose nodes carry no startedAt and no tokens renders the settled counter
// ONLY — elapsed and ↓tokens are omitted, never synthesized as zeros.
func TestWorkflowStripOmitsAbsentFigures(t *testing.T) {
	wf := &Workflow{Status: "running", Label: "bare run", Nodes: []WorkflowNode{
		{Type: "workflow_phase", Index: 1, Title: "Build"},
		{Type: "workflow_agent", Label: "build:x", PhaseIndex: 1, State: "start"},
	}}
	m := Model{width: 80, height: 24, screen: screenChat, st: State{Workflow: wf}}
	m.now = time.Now
	strip := m.workflowPanelLines()[0]
	if !strings.Contains(strip, "0/1 agents done") {
		t.Fatalf("strip must carry the settled counter, got:\n%s", strip)
	}
	if strings.Contains(strip, "↓") {
		t.Fatalf("no node carried tokens — the strip must omit ↓, got:\n%s", strip)
	}
	if strings.Contains(strip, "0s") || strings.Contains(strip, " · ") && strings.Count(strip, "·") > 0 {
		// the right side is exactly the counter — no elapsed segment
		if strings.Contains(strip, "·") {
			t.Fatalf("no startedAt on the wire — the strip must omit elapsed, got:\n%s", strip)
		}
	}
}

// TestWorkflowDetailTwoPane: the expanded panel shows phases left (glyph +
// title + settled/total, selection marked) and the selected phase's agents
// right (pair-grammar label, model family, tokens, elapsed) — plus the honest
// mid-flight omission on the interrupted fixture.
func TestWorkflowDetailTwoPane(t *testing.T) {
	m := stripModel(t, "rail_workflow_live.json")
	m.focus = focusWorkflow
	m.wfExpanded = true
	m.wfPhase = 5 // the active Build-ish phase (position 5 = phase 6)
	panel := m.workflowPanelLines()
	if len(panel) < 8 {
		t.Fatalf("expanded panel must render strip + 7 phase rows, got %d lines", len(panel))
	}
	out := strings.Join(panel, "\n")
	for _, want := range []string{"│", "▸", "✓", "❯"} {
		if !strings.Contains(out, want) {
			t.Fatalf("expanded panel must contain %q, got:\n%s", want, out)
		}
	}
	// phase titles from the real epic-cycle capture (the core-auth cycle)
	for _, phase := range []string{"Design", "Security Review", "Synthesis"} {
		if !strings.Contains(out, phase) {
			t.Fatalf("phase column must list %q, got:\n%s", phase, out)
		}
	}

	// the interrupted fixture: selected frontier phase renders mid-flight agents
	// with NO elapsed (dead entry, no durationMs) and the Opus family
	mi := stripModel(t, "rail_workflow_interrupted.json")
	_ = mi
	wf := mi.st.Workflow
	j := journeyOf(wf)
	rows := workflowAgentLines(50, j.Phases[1], j.EntryStatus, mi.now())
	agentPane := strings.Join(rows, "\n")
	if !strings.Contains(agentPane, "explore:") && !strings.Contains(agentPane, "liveness-anatomy") {
		t.Fatalf("agent pane must render the pair-grammar labels, got:\n%s", agentPane)
	}
	if !strings.Contains(agentPane, "Opus") {
		t.Fatalf("agent pane must render the model family, got:\n%s", agentPane)
	}
	for _, row := range rows {
		if strings.HasSuffix(strings.TrimRight(row, " "), "s") && strings.Contains(row, "m") {
			// crude: no mm/ss elapsed may appear on mid-flight rows of a dead entry
		}
	}
	if strings.Contains(agentPane, "0s") {
		t.Fatalf("mid-flight agents of a dead entry must OMIT elapsed, got:\n%s", agentPane)
	}
}

// TestWorkflowPanelGeometryConditional is the minimalism proof (charter D11 of
// the wsc charter / criterion 1): (a) a session whose workflow has SETTLED
// renders a frame byte-identical to one with no workflow at all — the 3-line
// footer and the height-5 bodyHeight are untouched; (b) a live strip eats
// transcript rows so the total frame height stays fixed.
func TestWorkflowPanelGeometryConditional(t *testing.T) {
	msgs := make([]Message, 0, 40)
	for i := 1; i <= 40; i++ {
		msgs = append(msgs, Message{Seq: i, Role: "user", SourceMarkdown: "line"})
	}

	base := Model{width: 80, height: 24, screen: screenChat, scroll: -1,
		st: State{Messages: msgs}}
	base.now = time.Now

	settled := stripModel(t, "rail_workflow_completed.json")
	settled.st.Messages = msgs
	settled.now = base.now

	if base.bodyHeight() != 24-5 {
		t.Fatalf("no-workflow bodyHeight must stay the height-5 constant, got %d", base.bodyHeight())
	}
	if a, b := base.renderChat(), settled.renderChat(); a != b {
		t.Fatalf("a settled workflow must render a byte-identical frame to no workflow:\n--- none ---\n%s\n--- settled ---\n%s", a, b)
	}

	live := stripModel(t, "rail_workflow_live.json")
	live.st.Messages = msgs
	if lines := strings.Count(live.renderChat(), "\n"); lines != strings.Count(base.renderChat(), "\n") {
		t.Fatalf("the strip must eat transcript rows, not grow the frame (live=%d base=%d)",
			lines, strings.Count(base.renderChat(), "\n"))
	}
	if live.bodyHeight() != 24-5-1 {
		t.Fatalf("a live strip costs exactly its one row, got bodyHeight=%d", live.bodyHeight())
	}

	// the expanded panel still keeps the frame fixed
	live.focus = focusWorkflow
	live.wfExpanded = true
	if lines := strings.Count(live.renderChat(), "\n"); lines != strings.Count(base.renderChat(), "\n") {
		t.Fatalf("the expanded panel must keep the frame height fixed (expanded=%d base=%d)",
			lines, strings.Count(base.renderChat(), "\n"))
	}
}

// TestWorkflowFooterHints: an unfocused visible strip advertises ↓ workflow;
// the focused strip and the expanded panel swap the hints honestly (esc there
// collapses — it must not claim to interrupt).
func TestWorkflowFooterHints(t *testing.T) {
	m := stripModel(t, "rail_workflow_live.json")
	if foot := m.chatFooter(); !strings.Contains(foot, "↓ workflow") {
		t.Fatalf("an unfocused strip must advertise ↓ workflow, got:\n%s", foot)
	}
	m.focus = focusWorkflow
	if foot := m.chatFooter(); !strings.Contains(foot, "enter details") {
		t.Fatalf("a focused strip must hint enter, got:\n%s", foot)
	}
	m.wfExpanded = true
	foot := m.chatFooter()
	if !strings.Contains(foot, "select phase") || !strings.Contains(foot, "esc back") {
		t.Fatalf("the expanded panel must hint up/down select · esc back, got:\n%s", foot)
	}
	if strings.Contains(foot, "esc interrupt") {
		t.Fatalf("the panel's hints must not claim esc interrupts, got:\n%s", foot)
	}
}
