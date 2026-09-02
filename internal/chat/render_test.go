package chat

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/FRIKKern/barkpark/internal/pdrender"
)

// render_test.go — the projection proofs. The load-bearing one is D10: each
// settled assistant message renders as its OWN document (one RenderDoc call), so
// nothing leaks across replies — and since pdrender now numbers NOTHING (it only
// emphasises an author-typed "Figure N." lead, like the web reader), a caption
// says exactly what the author typed in every message. The golden-parity harness
// diffs exactly this assistant-body projection; cards/tail/user echoes are out of
// scope and only proven not to crash or scope-creep.

// figureBlocks is a one-figure document. Two of these rendered as separate
// messages must each carry their OWN caption text and no invented number.
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

// TestFigureCaptionsCarryNoInventedNumber is the D10 proof in its honest form:
// two assistant messages each rendered via their own RenderDoc call carry their
// own author caption and NO renderer-generated "Figure N." — nothing accumulates
// across replies because there is no counter to accumulate.
func TestFigureCaptionsCarryNoInventedNumber(t *testing.T) {
	reg := pdrender.DefaultRegistry(pdrender.DarkTheme())
	m1 := Message{Role: "assistant", Blocks: figureBlocks("first")}
	m2 := Message{Role: "assistant", Blocks: figureBlocks("second")}

	out1 := strings.Join(renderAssistantDoc(reg, 80, m1), "\n")
	out2 := strings.Join(renderAssistantDoc(reg, 80, m2), "\n")

	if !strings.Contains(out1, "first") || !strings.Contains(out2, "second") {
		t.Fatalf("each message must carry its own caption, got:\n%s\n---\n%s", out1, out2)
	}
	for i, out := range []string{out1, out2} {
		if strings.Contains(out, "Figure") {
			t.Fatalf("message %d gained a figure number no author typed:\n%s", i+1, out)
		}
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
	lines := workflowCardLines(80, &wf, epic, 0)
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
	iout := strings.Join(workflowCardLines(80, &interrupted, nil, 0), "\n")
	if !strings.Contains(iout, "interrupted") {
		t.Errorf("an interrupted wave must render 'interrupted', got:\n%s", iout)
	}
	if !strings.Contains(iout, "✕") {
		t.Errorf("the dead-frontier tick must render the interrupted glyph, got:\n%s", iout)
	}
	// No epic goal → exactly one line (no fabricated goal line).
	if got := len(workflowCardLines(80, &interrupted, nil, 0)); got != 1 {
		t.Errorf("a goal-less workflow row grows exactly one line, got %d", got)
	}

	// A nil summary adds nothing — the minimalism contract.
	if workflowCardLines(80, nil, epic, 0) != nil {
		t.Fatal("a nil workflow summary must add no lines (even with a stray epic)")
	}
}

// TestWorkflowTickLineNeedsYouPill is criterion 2: on a live workflow row the
// needs-you pill REPLACES the status word when PendingApprovals>0 (needs-you >
// working, single-badge — one word slot, never a new line, never side-by-side);
// a terminal wave is never needs-you (its lifecycle word wins even with pending);
// and a plain workflow row (pending=0) is unchanged.
func TestWorkflowTickLineNeedsYouPill(t *testing.T) {
	wf := loadWorkflowFixture(t, "workflow_building.json") // live, phase word "Build"

	pill := workflowTickLine(80, &wf, 2)
	if !strings.Contains(pill, "needs you") || !strings.Contains(pill, "⏸") {
		t.Fatalf("a live workflow with a pending gate must show the needs-you pill, got:\n%q", pill)
	}
	if strings.Contains(pill, "\n") {
		t.Fatalf("the needs-you pill must never add a line (single-badge law), got:\n%q", pill)
	}
	if strings.Contains(pill, "Build") {
		t.Fatalf("needs-you > working — the pill must REPLACE the live status word, got:\n%q", pill)
	}
	// the fleet counter still rides alongside (the pill only swaps the word slot).
	if !strings.Contains(pill, "13/17") {
		t.Fatalf("the pill must not eat the settled/total counter, got:\n%q", pill)
	}

	// pending=0 → the ordinary status word, no pill.
	plain := workflowTickLine(80, &wf, 0)
	if strings.Contains(plain, "needs you") {
		t.Fatalf("no pending gate must show no pill, got:\n%q", plain)
	}
	if !strings.Contains(plain, "Build") {
		t.Fatalf("without a gate the live phase word must render, got:\n%q", plain)
	}

	// a terminal wave is never needs-you even with a stale pending count.
	term := loadSharedSummaries(t)["epic_cycle_interrupted"]
	tline := workflowTickLine(80, &term, 3)
	if strings.Contains(tline, "needs you") {
		t.Fatalf("a terminal wave must never show needs-you, got:\n%q", tline)
	}
	if !strings.Contains(tline, "interrupted") {
		t.Fatalf("a terminal wave keeps its lifecycle word, got:\n%q", tline)
	}
}

// TestPickerRowSurfacesNeedsYou proves the wsc needs-you pill still flows
// through the herd row's tick line (a workflow session with pending approvals
// shows it), and that a plain (workflow-less) row never grows a tick line —
// it stays ONE physical line wearing only the herd's four-state pill (the
// pre-herd byte-identity contract is SUPERSEDED by "every row wears the pill",
// herd charter D55h).
func TestPickerRowSurfacesNeedsYou(t *testing.T) {
	wf := loadWorkflowFixture(t, "workflow_building.json")
	m := Model{width: 80, sessions: []SessionSummary{
		{ID: "plain", Title: "just a chat", MessageCount: 4, PendingApprovals: 1},
		{ID: "cycle", Title: "epic cycle run", MessageCount: 9, PendingApprovals: 2, Workflow: &wf},
	}}
	rows := m.pickerRows()
	var plainRow, wfRow string
	for _, r := range rows[1:] {
		if strings.Contains(r, "just a chat") {
			plainRow = r
		}
		if strings.Contains(r, "epic cycle run") {
			wfRow = r
		}
	}
	if !strings.Contains(wfRow, "needs you") {
		t.Fatalf("a workflow row with pending approvals must surface the needs-you pill, got:\n%q", wfRow)
	}
	if strings.Contains(plainRow, "\n") {
		t.Fatalf("a plain row must never grow a tick line, got:\n%q", plainRow)
	}
	if !strings.Contains(plainRow, "1 pending") {
		t.Fatalf("the pending count must still ride the plain row's meta, got:\n%q", plainRow)
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

// TestPickerRowsWorkflowMultiline proves a workflow session's herd row spans
// the two extra wsc card lines UNCHANGED (fleet progress stays visible at a
// glance), while a plain session's row stays exactly ONE physical line — the
// herd-era minimalism contract (D55h: the pill replaced byte-identity; the
// one-line law is what remains protected).
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
	var plainRow, wfRow string
	for _, r := range rows[1:] {
		if strings.Contains(r, "just a chat") {
			plainRow = r
		}
		if strings.Contains(r, "epic cycle run") {
			wfRow = r
		}
	}

	// Plain row: one physical line, pill + title + meta.
	if strings.Contains(plainRow, "\n") {
		t.Fatalf("a plain session row must stay single-line, got:\n%q", plainRow)
	}
	if !strings.Contains(plainRow, "4 msg") {
		t.Fatalf("plain row must keep its meta tail, got:\n%q", plainRow)
	}

	// Workflow row: three physical lines (title + tick line + goal line), and it
	// is still ONE navigable entry (cursor stops once).
	if n := strings.Count(wfRow, "\n"); n != 2 {
		t.Fatalf("a workflow row (with goal) spans three lines, got %d newlines:\n%q", n, wfRow)
	}
	if !strings.Contains(wfRow, "13/17") {
		t.Fatalf("workflow row must surface the fleet counter, got:\n%q", wfRow)
	}
	if !strings.Contains(wfRow, "2/5 slices") {
		t.Fatalf("workflow row must keep the wsc goal line, got:\n%q", wfRow)
	}
}

// TestHerdRowPillAgeCost is the herd home's row proof (charter D50h): every
// session row wears the four-state pill, an honest RELATIVE age (never a live
// now-line — the row must not carry any activity text), and the session's
// cost; a stalled working row swaps its pill for the stall badge; the rows
// come out in attention order.
func TestHerdRowPillAgeCost(t *testing.T) {
	now := time.Date(2026, 7, 18, 12, 0, 0, 0, time.UTC)
	iso := func(t time.Time) string { return t.Format(time.RFC3339Nano) }
	m := Model{width: 100, now: func() time.Time { return now }, sessions: []SessionSummary{
		{ID: "w", Title: "worker", MessageCount: 1, TotalCostUSD: 1.5,
			AgentState: "working", AgentStateAt: iso(now.Add(-2 * time.Minute))},
		{ID: "b", Title: "blocked one", MessageCount: 2, TotalCostUSD: 0.42,
			AgentState: "blocked", AgentStateAt: iso(now.Add(-5 * time.Minute))},
		{ID: "i", Title: "idler", MessageCount: 3,
			AgentState: "idle", AgentStateAt: iso(now.Add(-3 * time.Hour))},
		{ID: "s", Title: "wedged", MessageCount: 4,
			AgentState: "working", AgentStateAt: iso(now.Add(-10 * time.Minute))},
	}}
	m.herd = herdSeed(m.herd, m.sessions)
	// a fresh heartbeat keeps w honest-working; s saw nothing for 10m → stalled
	m.herd = herdHeartbeat(m.herd, "w", now)

	rows := m.pickerRows()
	if len(rows) != 5 {
		t.Fatalf("expected new + 4 rows, got %d", len(rows))
	}
	// attention order: blocked, stalled, working, idle
	for i, want := range []string{"blocked one", "wedged", "worker", "idler"} {
		if !strings.Contains(rows[i+1], want) {
			t.Fatalf("attention order row %d must be %q, got rows:\n%s", i+1, want, strings.Join(rows[1:], "\n"))
		}
	}
	if !strings.Contains(rows[1], "⏸ blocked") || !strings.Contains(rows[1], "$0.42") {
		t.Fatalf("blocked row must wear the pill + cost, got:\n%q", rows[1])
	}
	if !strings.Contains(rows[1], "5m") {
		t.Fatalf("blocked row must carry the honest relative age, got:\n%q", rows[1])
	}
	if !strings.Contains(rows[2], "⚠ stalled") {
		t.Fatalf("a working row with no frame past 150s must wear the stall badge, got:\n%q", rows[2])
	}
	if !strings.Contains(rows[3], "● working") || !strings.Contains(rows[3], "$1.50") {
		t.Fatalf("working row must wear the pill + cost, got:\n%q", rows[3])
	}
	if !strings.Contains(rows[4], "○ idle") || !strings.Contains(rows[4], "3h") {
		t.Fatalf("idle row must wear the pill + age, got:\n%q", rows[4])
	}
	// no cost on the wire → no fabricated $0.00
	if strings.Contains(rows[4], "$") {
		t.Fatalf("a costless row must not fabricate a cost, got:\n%q", rows[4])
	}
}

// TestHerdRowTitleFollowsTheTitleFrame is the READ half of the D69h fold: a
// live `title` frame renames the picker row IN PLACE, without a roster refetch.
// The paint must read the HERD's held title, not the cold list's — a fold
// nobody reads would be a stored value with no reader, and the stale row title
// this frame exists to fix would survive the fix.
func TestHerdRowTitleFollowsTheTitleFrame(t *testing.T) {
	now := time.Date(2026, 7, 18, 12, 0, 0, 0, time.UTC)
	m := Model{width: 100, now: func() time.Time { return now }, sessions: []SessionSummary{
		{ID: "a", Title: "stale list title", MessageCount: 1, AgentState: "idle",
			AgentStateAt: now.Add(-time.Minute).Format(time.RFC3339Nano)},
	}}
	m.herd = herdSeed(m.herd, m.sessions)
	if !strings.Contains(m.pickerRows()[1], "stale list title") {
		t.Fatalf("precondition: the cold list title paints, got:\n%q", m.pickerRows()[1])
	}

	h, ok := applyFleetFrame(m.herd, "title", []byte(`{"session_id":"a","title":"renamed in Studio"}`))
	if !ok {
		t.Fatal("the title frame must apply")
	}
	m.herd = h
	row := m.pickerRows()[1]
	if !strings.Contains(row, "renamed in Studio") {
		t.Fatalf("the renamed row must paint the fresh title, got:\n%q", row)
	}
	if strings.Contains(row, "stale list title") {
		t.Fatalf("the stale list title must be gone, got:\n%q", row)
	}

	// A herd row that holds NO title still falls back to the list's (a roster
	// row the stream and the seed have not reached).
	if got := herdRowTitle(HerdRow{SessionID: "a"}, SessionSummary{ID: "a", Title: " listed "}); got != "listed" {
		t.Fatalf("a titleless herd row must fall back to the list title, got %q", got)
	}
}

// ── the archived shelf screen ────────────────────────────────────────────────

// TestShelfScreenPaintsRowsAndTheRestoreKey is the shelf's paint proof: the pane
// can SHOW the shelf — rows with their title, size, cost and how long they have
// been shelved — and the footer advertises the ONE verb that gets them back. It
// also pins the two honest edges: an empty shelf says so, and a load error
// offers the retry rather than a blank frame.
func TestShelfScreenPaintsRowsAndTheRestoreKey(t *testing.T) {
	now := time.Date(2026, 7, 26, 12, 0, 0, 0, time.UTC)
	iso := func(t time.Time) string { return t.Format(time.RFC3339Nano) }
	m := Model{width: 100, height: 24, screen: screenShelf, now: func() time.Time { return now }}
	m.shelf = []SessionSummary{
		{ID: "old", Title: "dismissed epic", MessageCount: 12, TotalCostUSD: 3.25,
			ArchivedAt: iso(now.Add(-2 * time.Hour))},
		{ID: "bare", MessageCount: 1},
	}

	out := m.renderShelf()
	for _, want := range []string{"shelf", "dismissed epic", "12 msg", "$3.25", "shelved 2h", "enter/u restore"} {
		if !strings.Contains(out, want) {
			t.Errorf("the shelf paint must carry %q:\n%s", want, out)
		}
	}
	// A titleless row is honest, never blank; and no cost is invented.
	if !strings.Contains(out, "untitled session") {
		t.Errorf("a titleless shelf row must read \"untitled session\":\n%s", out)
	}
	if strings.Count(out, "$") != 1 {
		t.Errorf("a costless shelf row must not fabricate a cost:\n%s", out)
	}
	// No attention pill on the shelf: the fleet snapshot excludes archived
	// sessions, so a pill here would be stale-by-construction.
	for _, never := range []string{"● working", "○ idle", "? unknown", "⚠ stalled"} {
		if strings.Contains(out, never) {
			t.Errorf("the shelf must not paint an attention pill (%q):\n%s", never, out)
		}
	}
	// The cursor marks the row it will restore.
	if !strings.Contains(out, youStyle.Render("▸ ")+titleStyle.Render(m.shelfRows()[0])) {
		t.Errorf("the shelf cursor must mark its row:\n%s", out)
	}

	empty := Model{width: 100, height: 24, screen: screenShelf, now: func() time.Time { return now }}
	if got := empty.renderShelf(); !strings.Contains(got, "Nothing on the shelf") {
		t.Errorf("an empty shelf must say so:\n%s", got)
	}
	// A failed READ is prefixed at the source (model.go), so the paint can print
	// it verbatim — under stale rows that line is the only context there is.
	failed := empty
	failed = mustModel(failed.Update(shelfLoadedMsg{err: errArchiveTest}))
	if got := failed.renderShelf(); !strings.Contains(got, "could not read the shelf — boom") ||
		!strings.Contains(got, "press r to retry") {
		t.Errorf("a failed shelf read must say so and offer the retry:\n%s", got)
	}
}

// TestShelfRowFollowsTheHerdTitle: the shelf reads the SAME title projection the
// herd home does (herdRowTitle), so a session renamed while it sits on the shelf
// is not a mystery row.
func TestShelfRowFollowsTheHerdTitle(t *testing.T) {
	now := time.Date(2026, 7, 26, 12, 0, 0, 0, time.UTC)
	m := Model{width: 100, height: 24, screen: screenShelf, now: func() time.Time { return now }}
	m.shelf = []SessionSummary{{ID: "old", Title: "stale list title"}}
	m.herd = seedHerd(HerdRow{SessionID: "old", AgentState: "idle", Title: "renamed while shelved"})

	out := m.renderShelf()
	if !strings.Contains(out, "renamed while shelved") || strings.Contains(out, "stale list title") {
		t.Errorf("the shelf row must read the herd's held title:\n%s", out)
	}
}

// TestShelfWindowsThroughTheSharedLaw: the shelf uses the picker's cursor-follow
// windowing (followTop + pickerFitEnd), never a forked copy — a long shelf
// clips with the same ↑/↓ affordances and the cursor row is always in view.
func TestShelfWindowsThroughTheSharedLaw(t *testing.T) {
	m := Model{width: 100, height: 12, screen: screenShelf, now: time.Now}
	for i := 0; i < 30; i++ {
		m.shelf = append(m.shelf, SessionSummary{ID: fmt.Sprintf("s%02d", i), Title: fmt.Sprintf("row %02d", i)})
	}
	m.shelfCursor = 25
	m.shelfTop = m.followShelfTop()

	out := m.renderShelf()
	if !strings.Contains(out, "row 25") {
		t.Errorf("the cursor row must be inside the window:\n%s", out)
	}
	if !strings.Contains(out, "more above") {
		t.Errorf("a scrolled shelf must show the ↑ affordance:\n%s", out)
	}
	if strings.Contains(out, "row 00") {
		t.Errorf("the window must clip the rows above it:\n%s", out)
	}
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

// TestWorkflowStripPrefersLiveSummary proves wsc-bl-workflow-sse's visible win:
// a compact live summary (the mid-turn SSE `event: workflow` delta) drives the
// collapsed strip, OVERRIDING a staler rail fold; a Terminal summary drops the
// strip even while the rail fold still reads live.
func TestWorkflowStripPrefersLiveSummary(t *testing.T) {
	// A rail fold that alone would render "0/1" with a stale label, plus a fresher
	// live summary carrying "3/4" — the strip must show the LIVE figures.
	stale := &Workflow{Status: "running", Label: "stale label", Nodes: []WorkflowNode{
		{Type: "workflow_phase", Index: 1, Title: "Build"},
		{Type: "workflow_agent", Label: "a", PhaseIndex: 1, State: "start"},
	}}
	live := &SessionWorkflow{Label: "live label", AgentsDone: 3, AgentsTotal: 4}
	m := Model{width: 80, height: 24, screen: screenChat, st: State{Workflow: stale, LiveWorkflow: live}}
	m.now = time.Now

	panel := m.workflowPanelLines()
	if len(panel) != 1 {
		t.Fatalf("a live non-terminal summary renders exactly the strip, got %d lines", len(panel))
	}
	strip := panel[0]
	if !strings.Contains(strip, "live label") || !strings.Contains(strip, "3/4 agents done") {
		t.Fatalf("the strip must read the LIVE summary mid-turn, got:\n%s", strip)
	}
	if strings.Contains(strip, "stale label") {
		t.Fatalf("the staler rail fold must not drive the strip, got:\n%s", strip)
	}

	// A Terminal live summary drops the strip even though the rail fold still
	// reads live (D23 — the settled wave gives the transcript its rows back).
	m.st.LiveWorkflow = &SessionWorkflow{Label: "done", AgentsDone: 4, AgentsTotal: 4, Terminal: true}
	if got := m.workflowPanelLines(); got != nil {
		t.Fatalf("a Terminal summary must drop the strip, got:\n%v", got)
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
	rows := workflowAgentLines(50, j.Phases[1], j.EntryStatus, mi.now(), true)
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

// ── wsc-map-inline: the execution-map round (charter D40–D44) ────────────────

// TestAgentSnippetExtraction pins the D40 ladder on hand-built payloads: the
// truncation-tolerant key regex (RE2 captures an UNTERMINATED tail — the corpus
// truth is 817/820 previews clip at 401 chars), key priority, escape handling,
// the dangling-backslash drop, the bare-prose first-sentence fallback, and the
// never-brace-noise guarantee.
func TestAgentSnippetExtraction(t *testing.T) {
	for _, tc := range []struct {
		name, in, want string
	}{
		// the 1-line RE2 proof: a clipped value with NO closing quote captures to
		// end-of-string (the (?:\\.|[^"\\])* tail).
		{"clipped-unterminated-tail", `{"phase":2,"summary":"IMPORTANT FINDING: Phase 2 is done`, "IMPORTANT FINDING: Phase 2 is done"},
		{"key-priority-direction-first", `{"summary":"later","direction":"WAVE 11 — alive at a glance`, "WAVE 11 — alive at a glance"},
		{"test-summary-when-no-summary", `{"phase":2,"ok":true,"test_summary":"64 tests, 0 failures`, "64 tests, 0 failures"},
		{"escapes-unescaped", `{"summary":"a \"quoted\" word\nnext line`, `a "quoted" word next line`},
		{"dangling-backslash-dropped", `{"summary":"clipped mid-escape \`, "clipped mid-escape"},
		{"trailing-ellipsis-stripped", `{"summary":"the tail was clipped …`, "the tail was clipped"},
		{"json-without-headline-keys", `{"phase":4,"ok":true,"committed":false,"files":["a.ex"]`, ""},
		{"prose-first-sentence", "The fix landed cleanly. More detail follows here.", "The fix landed cleanly."},
		{"prose-markdown-markers-stripped", "## Verdict\nrest of the report", "Verdict"},
		{"empty", "   ", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := agentSnippet(tc.in); got != tc.want {
				t.Fatalf("agentSnippet(%q) = %q, want %q", tc.in, got, tc.want)
			}
		})
	}
}

// TestAgentSnippetSyntheticWholeParse drives the committed SYNTHETIC
// untruncated-object fixture (agent_snippet_synthetic.json — D29/D37 precedent:
// zero real captures parse whole, so the whole-parse branch is exercised by
// hand-built payloads, never a doctored real fixture).
func TestAgentSnippetSyntheticWholeParse(t *testing.T) {
	raw, err := os.ReadFile("testdata/agent_snippet_synthetic.json")
	if err != nil {
		t.Fatalf("read synthetic fixture: %v", err)
	}
	var fx struct {
		Cases []struct {
			Name    string `json:"name"`
			Preview string `json:"preview"`
			Want    string `json:"want"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(raw, &fx); err != nil {
		t.Fatalf("decode synthetic fixture: %v", err)
	}
	if len(fx.Cases) == 0 {
		t.Fatal("the synthetic fixture must carry cases")
	}
	for _, c := range fx.Cases {
		if got := agentSnippet(c.Preview); got != c.Want {
			t.Fatalf("%s: agentSnippet = %q, want %q", c.Name, got, c.Want)
		}
	}
}

// collectResultPreviews walks decoded JSON for every "resultPreview" string —
// the corpus harvester for the brace-noise proof.
func collectResultPreviews(v any, out *[]string) {
	switch x := v.(type) {
	case map[string]any:
		for k, vv := range x {
			if k == "resultPreview" {
				if s, ok := vv.(string); ok {
					*out = append(*out, s)
				}
				continue
			}
			collectResultPreviews(vv, out)
		}
	case []any:
		for _, vv := range x {
			collectResultPreviews(vv, out)
		}
	}
}

// TestAgentSnippetCorpusNeverBraceNoise is the D40 corpus proof: over EVERY
// resultPreview in the committed fixtures, agentSnippet returns either "" or a
// clean headline — never raw JSON noise (the codex parse-first design yields
// zero snippets on this corpus; string passthrough yields brace-noise; ours
// must yield clean extractions).
func TestAgentSnippetCorpusNeverBraceNoise(t *testing.T) {
	files, err := filepath.Glob("testdata/*.json")
	if err != nil || len(files) == 0 {
		t.Fatalf("glob testdata: %v (%d files)", err, len(files))
	}
	total, extracted := 0, 0
	for _, f := range files {
		raw, err := os.ReadFile(f)
		if err != nil {
			t.Fatalf("read %s: %v", f, err)
		}
		var v any
		if err := json.Unmarshal(raw, &v); err != nil {
			t.Fatalf("decode %s: %v", f, err)
		}
		var previews []string
		collectResultPreviews(v, &previews)
		for _, p := range previews {
			total++
			got := agentSnippet(p)
			if got == "" {
				continue
			}
			extracted++
			if strings.HasPrefix(got, "{") || strings.HasPrefix(got, "[") || strings.HasPrefix(got, `"`) {
				t.Fatalf("%s: brace-noise snippet %q from preview %q", f, got, p[:60])
			}
		}
	}
	if total < 30 {
		t.Fatalf("corpus proof needs the committed fixtures' previews, walked only %d", total)
	}
	if extracted == 0 {
		t.Fatal("the extractor must land snippets on the real corpus, got none")
	}
}

// TestWorkflowSettledRowSnippets is the D40 render law: a dimmed snippet line
// rides under SETTLED rows only — a running agent never carries one (no live
// churn), and a settled agent whose preview yields nothing adds no line.
func TestWorkflowSettledRowSnippets(t *testing.T) {
	done := `{"summary":"landed the fold; gate green`
	running := `{"summary":"half-way through the fold`
	noise := `{"phase":3,"ok":true`
	wf := &Workflow{Status: "running", Label: "fleet", Nodes: []WorkflowNode{
		{Type: "workflow_phase", Index: 1, Title: "Build"},
		{Type: "workflow_agent", PhaseIndex: 1, Label: "build:done", State: "done", ResultPreview: &done},
		{Type: "workflow_agent", PhaseIndex: 1, Label: "build:live", State: "progress", ResultPreview: &running},
		{Type: "workflow_agent", PhaseIndex: 1, Label: "build:quiet", State: "done", ResultPreview: &noise},
	}}
	j := journeyOf(wf)
	rows := workflowAgentLines(80, j.Phases[0], j.EntryStatus, time.Now(), true)
	out := strings.Join(rows, "\n")
	if !strings.Contains(out, "landed the fold; gate green") {
		t.Fatalf("a settled row must carry its snippet, got:\n%s", out)
	}
	if strings.Contains(out, "half-way") {
		t.Fatalf("a running row must NEVER carry a snippet, got:\n%s", out)
	}
	if strings.Contains(out, "{") {
		t.Fatalf("no brace-noise may ever render, got:\n%s", out)
	}
	// 3 agent rows + exactly 1 snippet line (the noise preview yields "")
	if len(rows) != 4 {
		t.Fatalf("rows = 3 agents + 1 snippet, got %d:\n%s", len(rows), out)
	}
}

// TestWorkflowStallBadge is the D41 proof: a non-terminal agent whose
// lastProgressAt is >90s old wears the warn-token 'no progress since <HH:MM>'
// (never an absolute 'stalled' verdict, never a crashed/stopped state); fresh,
// terminal and timestamp-less agents wear nothing; and a pending answerable
// card suppresses EVERY badge — waiting on the operator is never a stall.
func TestWorkflowStallBadge(t *testing.T) {
	base := time.UnixMilli(1783633800000)
	old := base.Add(-2 * time.Minute).UnixMilli()
	fresh := base.Add(-30 * time.Second).UnixMilli()
	wf := &Workflow{Status: "running", Label: "fleet", Nodes: []WorkflowNode{
		{Type: "workflow_phase", Index: 1, Title: "Build"},
		{Type: "workflow_agent", PhaseIndex: 1, Label: "build:slow", State: "progress", LastProgressAt: &old},
		{Type: "workflow_agent", PhaseIndex: 1, Label: "build:fresh", State: "progress", LastProgressAt: &fresh},
		{Type: "workflow_agent", PhaseIndex: 1, Label: "build:done", State: "done", LastProgressAt: &old},
		{Type: "workflow_agent", PhaseIndex: 1, Label: "build:quiet", State: "progress"},
	}}
	m := Model{width: 110, height: 30, screen: screenChat, scroll: -1,
		st: State{SessionID: "s1", Workflow: wf}}
	m.now = func() time.Time { return base }
	m.focus = focusWorkflow
	m.wfExpanded = true
	m.wfPhase = 0

	out := strings.Join(m.workflowPanelLines(), "\n")
	want := "no progress since " + time.UnixMilli(old).Format("15:04")
	if !strings.Contains(out, want) {
		t.Fatalf("a >90s-quiet running agent must wear %q, got:\n%s", want, out)
	}
	if n := strings.Count(out, "no progress since"); n != 1 {
		t.Fatalf("fresh/terminal/timestamp-less agents must wear NO badge (want exactly 1, got %d):\n%s", n, out)
	}
	if strings.Contains(strings.ToLower(out), "stalled") || strings.Contains(strings.ToLower(out), "crashed") {
		t.Fatalf("the badge must never claim an absolute stalled/crashed verdict, got:\n%s", out)
	}

	// suppression: any pending answerable card silences every stall badge
	m.st.Messages = []Message{pendingCard("plan")}
	out = strings.Join(m.workflowPanelLines(), "\n")
	if strings.Contains(out, "no progress since") {
		t.Fatalf("a pending answerable card must suppress all stall badges, got:\n%s", out)
	}
}

// TestWorkflowResultBox is the D43 proof: once the rail entry settles (while
// the strip still stands on a fresher live summary), the panel bottom states
// the EntryStatus verbatim + settled/total + tokens; the grade line rides ONLY
// when the cached picker Epic's wave_status carries 'complete — grade'; a
// failed fleet gets a first-class '✕ N failed' line; and an interrupted wave
// is never dressed with a resultPreview snippet.
func TestWorkflowResultBox(t *testing.T) {
	m := stripModel(t, "rail_workflow_completed.json")
	// the real mid-window: the rail refetch landed terminal before the final SSE
	// workflow frame — the strip stands on the (still non-terminal) live summary
	m.st.LiveWorkflow = &SessionWorkflow{Label: "core-auth", AgentsDone: 29, AgentsTotal: 29}
	m.sessions = []SessionSummary{{ID: "s1",
		Epic: &EpicGoal{Title: "Epic", WaveStatus: "wave: complete — grade A-"}}}

	out := strings.Join(m.workflowPanelLines(), "\n")
	for _, want := range []string{"completed", "29/29 agents", "↓2.1M", "wave: complete — grade A-"} {
		if !strings.Contains(out, want) {
			t.Fatalf("result box must carry %q, got:\n%s", want, out)
		}
	}

	// the grade line renders ONLY on the 'complete — grade' heartbeat substring
	m.sessions[0].Epic.WaveStatus = "wave: building 6 slices"
	out = strings.Join(m.workflowPanelLines(), "\n")
	if strings.Contains(out, "wave: building") {
		t.Fatalf("a non-grade wave_status must never ride the result box, got:\n%s", out)
	}

	// a completed entry carrying failures states them first-class
	failed := &Workflow{Status: "completed", Label: "x", Nodes: []WorkflowNode{
		{Type: "workflow_phase", Index: 1, Title: "Build"},
		{Type: "workflow_agent", PhaseIndex: 1, Label: "a", State: "done"},
		{Type: "workflow_agent", PhaseIndex: 1, Label: "b", State: "error"},
		{Type: "workflow_agent", PhaseIndex: 1, Label: "c", State: "failed"},
	}}
	fm := m
	fm.st.Workflow = failed
	out = strings.Join(fm.workflowPanelLines(), "\n")
	if !strings.Contains(out, "✕ 2 failed") {
		t.Fatalf("a failed fleet must state '✕ 2 failed' first-class, got:\n%s", out)
	}

	// interrupted: stated verbatim, never dressed with a resultPreview snippet
	mi := stripModel(t, "rail_workflow_interrupted.json")
	mi.st.LiveWorkflow = &SessionWorkflow{Label: "epic", AgentsDone: 1, AgentsTotal: 5}
	out = strings.Join(mi.workflowPanelLines(), "\n")
	if !strings.Contains(out, "interrupted") {
		t.Fatalf("an interrupted wave must state 'interrupted', got:\n%s", out)
	}
	if strings.Contains(out, "WAVE 11") {
		t.Fatalf("an interrupted result box must never carry a resultPreview snippet, got:\n%s", out)
	}
}

// synthetic18Workflow is the MANDATORY D44 fixture: an 18-agent phase with
// running agents at wire indices 0, 9 and 17 (no real fixture exceeds 5
// agents/phase — before D44, a running agent at wire index ≥9 was silently
// folded and cursor-unreachable). Comment-labelled SYNTHETIC per D29/D37.
func synthetic18Workflow() *Workflow {
	nodes := []WorkflowNode{{Type: "workflow_phase", Index: 1, Title: "Build"}}
	for i := 0; i < 18; i++ {
		state := "done"
		if i == 0 || i == 9 || i == 17 {
			state = "progress"
		}
		p := fmt.Sprintf("brief %d", i)
		rp := fmt.Sprintf(`{"summary":"result %02d clipped`, i)
		n := WorkflowNode{Type: "workflow_agent", PhaseIndex: 1,
			Label: fmt.Sprintf("build:agent-%02d", i), State: state, Attempt: 1, PromptPreview: &p}
		if state == "done" {
			n.ResultPreview = &rp
		}
		nodes = append(nodes, n)
	}
	return &Workflow{Status: "running", Label: "wide fleet", Nodes: nodes}
}

// TestVisibleAgentsPinsRunning is the D44 projection proof on the synthetic
// 18-agent phase: running agents are NEVER folded (wire 0/9/17 all visible at
// cap 8, wire order), the index map translates every painted row back to its
// wire position, the overflow row counts settled only, and the detail pane
// resolves the SAME agent the painted row names (cursor == paint == detail).
func TestVisibleAgentsPinsRunning(t *testing.T) {
	j := journeyOf(synthetic18Workflow())
	p := j.Phases[0]
	visible, indexMap, settledOverflow := visibleAgents(p)
	if len(visible) != workflowDetailMaxAgents {
		t.Fatalf("cap must hold at %d, got %d", workflowDetailMaxAgents, len(visible))
	}
	if settledOverflow != 10 {
		t.Fatalf("overflow counts settled only (15 settled − 5 shown = 10), got %d", settledOverflow)
	}
	// wire order + faithful translation
	for i, ix := range indexMap {
		if i > 0 && ix <= indexMap[i-1] {
			t.Fatalf("visible must stay in wire order, indexMap=%v", indexMap)
		}
		if visible[i].Label != p.Agents[ix].Label {
			t.Fatalf("index map must translate position %d to wire %d faithfully", i, ix)
		}
	}
	// running never folded
	seen := map[int]bool{}
	for _, ix := range indexMap {
		seen[ix] = true
	}
	for _, ix := range []int{0, 9, 17} {
		if !seen[ix] {
			t.Fatalf("running agent at wire %d must be pinned, indexMap=%v", ix, indexMap)
		}
	}

	// paint == projection: every visible label renders; a folded settled agent
	// (wire 8 — beyond the settled backfill) does not; overflow row says +10.
	rows := workflowAgentLines(60, p, j.EntryStatus, time.Now(), true)
	out := strings.Join(rows, "\n")
	for _, a := range visible {
		if !strings.Contains(out, a.Label[len("build:"):]) {
			t.Fatalf("painted rows must carry visible agent %q, got:\n%s", a.Label, out)
		}
	}
	if strings.Contains(out, "agent-08") {
		t.Fatalf("a folded settled agent must not paint, got:\n%s", out)
	}
	if !strings.Contains(out, "+10 more") {
		t.Fatalf("the overflow row must count the 10 folded settled agents, got:\n%s", out)
	}

	// detail == paint: the pane at each visible position names the SAME agent
	// the painted row names — including the pinned running agents past the old
	// cap (wire 9 at position 6, wire 17 at position 7).
	for pos, wantWire := range map[int]int{6: 9, 7: 17} {
		pane := strings.Join(renderWorkflowAgentDetail(80, j, time.Now(), 0, pos, true), "\n")
		want := fmt.Sprintf("agent-%02d", wantWire)
		if !strings.Contains(pane, want) {
			t.Fatalf("detail at position %d must resolve %s via the index map, got:\n%s", pos, want, pane)
		}
		// the naive phase.Agents[pos] addressing would name agent-06/agent-07
		wrong := fmt.Sprintf("agent-%02d", pos)
		if strings.Contains(pane, wrong) {
			t.Fatalf("detail must NEVER address phase.Agents[%d] directly, got:\n%s", pos, pane)
		}
	}

	// the running>cap edge: 10 running + 4 settled pins the first 8 running
	// (wire order) and the overflow row suffixes the hidden running count.
	nodes := []WorkflowNode{{Type: "workflow_phase", Index: 1, Title: "Explore"}}
	for i := 0; i < 14; i++ {
		state := "progress"
		if i >= 10 {
			state = "done"
		}
		nodes = append(nodes, WorkflowNode{Type: "workflow_agent", PhaseIndex: 1,
			Label: fmt.Sprintf("explore:a-%02d", i), State: state})
	}
	je := journeyOf(&Workflow{Status: "running", Nodes: nodes})
	vis, im, so := visibleAgents(je.Phases[0])
	if len(vis) != 8 || so != 4 {
		t.Fatalf("running>cap edge: want 8 visible / 4 settled overflow, got %d/%d", len(vis), so)
	}
	for i, ix := range im {
		if ix != i {
			t.Fatalf("running>cap edge must pin the FIRST 8 running in wire order, indexMap=%v", im)
		}
	}
	erows := strings.Join(workflowAgentLines(60, je.Phases[0], je.EntryStatus, time.Now(), true), "\n")
	if !strings.Contains(erows, "+4 more (2 running)") {
		t.Fatalf("the overflow row must read '… +4 more (2 running)', got:\n%s", erows)
	}
}

// TestChatHeaderShowsModeAndModelBadges proves the header's right-aligned truth
// cluster: ◇ PLAN / ▶ AUTOPILOT carry the two-state projection (glyphs survive
// the NoColor profile), the model renders as its family, and an odd raw mode
// shows verbatim — honest, never guessed.
func TestChatHeaderShowsModeAndModelBadges(t *testing.T) {
	m := Model{width: 80, height: 24, screen: screenChat, scroll: -1,
		st: State{Title: "My session", Mode: "plan", Model: "claude-opus-4-8[1m]"}}
	h := m.chatHeader()
	for _, want := range []string{"◇ PLAN", "Opus"} {
		if !strings.Contains(h, want) {
			t.Fatalf("header must contain %q, got %q", want, h)
		}
	}

	m.st.Mode = "auto"
	if h := m.chatHeader(); !strings.Contains(h, "▶ AUTOPILOT") {
		t.Fatalf("auto must render the AUTOPILOT badge, got %q", h)
	}

	m.st.Mode = "acceptEdits"
	if h := m.chatHeader(); !strings.Contains(h, "acceptEdits") {
		t.Fatalf("an odd raw mode must show verbatim, got %q", h)
	}

	// Effort rides the cluster when set (and not "default").
	m.st.Mode = "plan"
	m.effortChoice = "high"
	if h := m.chatHeader(); !strings.Contains(h, "high") {
		t.Fatalf("effort must ride the cluster, got %q", h)
	}
}

// TestChatHeaderPrefersObservedOverIntent proves fact-over-intent: before a
// turn reveals the answering model, the picker intent labels the badge; the
// observed wire id wins once present.
func TestChatHeaderPrefersObservedOverIntent(t *testing.T) {
	m := Model{width: 80, height: 24, screen: screenChat, scroll: -1,
		modelChoice: "sonnet",
		st:          State{Title: "s", Mode: "plan"}}
	if h := m.chatHeader(); !strings.Contains(h, "Sonnet") {
		t.Fatalf("intent must label the badge pre-turn, got %q", h)
	}
	m.st.Model = "claude-opus-4-8[1m]"
	if h := m.chatHeader(); !strings.Contains(h, "Opus") {
		t.Fatalf("observed model must win over intent, got %q", h)
	}
	// No intent, no observation → the honest "Default" (the CLI chooses).
	m2 := Model{width: 80, height: 24, screen: screenChat, scroll: -1,
		st: State{Title: "s", Mode: "plan"}}
	if h := m2.chatHeader(); !strings.Contains(h, "Default") {
		t.Fatalf("unset model must read Default, got %q", h)
	}
}

// TestChatHeaderDropsBadgesWhenNarrow proves the degrade order: a tight width
// drops detail rather than ever wrapping the title band onto a second line.
func TestChatHeaderDropsBadgesWhenNarrow(t *testing.T) {
	m := Model{width: 20, height: 24, screen: screenChat, scroll: -1,
		effortChoice: "high",
		st: State{Title: strings.Repeat("x", 40), Mode: "plan",
			Model: "claude-opus-4-8[1m]"}}
	lines := strings.Split(m.chatHeader(), "\n")
	if len(lines) != 2 {
		t.Fatalf("header must stay two lines, got %d", len(lines))
	}
	if w := lipgloss.Width(lines[0]); w > m.width {
		t.Fatalf("title band must never overflow width: %d > %d", w, m.width)
	}
}

// TestPickerWindowsPastScreenful is the S14 flagship-gap guard: past a
// screenful of sessions the picker must CLAMP its paint to the terminal height
// (alt-screen = fixed buffer) and slide a cursor-follow viewport so the
// highlighted row is always inside the window, with honest ↑/↓ more-indicators
// for the hidden overflow. It drives the REAL key grammar (down-past-edge,
// home, end, pgup, pgdn) through handlePickerKey and re-renders after every
// stroke; m.height<=0 (a bare test Model, no WindowSizeMsg yet) must fall back
// to show-all — never an empty paint.
func TestPickerWindowsPastScreenful(t *testing.T) {
	sessions := make([]SessionSummary, 50)
	for i := range sessions {
		sessions[i] = SessionSummary{ID: fmt.Sprintf("s%02d", i),
			Title: fmt.Sprintf("session %02d", i), MessageCount: i + 1}
	}
	m := Model{width: 80, height: 24, sessions: sessions}

	renderLines := func(out string) int { return strings.Count(out, "\n") + 1 }
	cursorLine := func(out string) string {
		for _, l := range strings.Split(out, "\n") {
			if strings.Contains(l, "▸") {
				return l
			}
		}
		return ""
	}
	assertCursorVisible := func(step string) string {
		t.Helper()
		out := m.renderPicker()
		if n := renderLines(out); n > m.height {
			t.Fatalf("%s: picker paints %d lines past height %d:\n%s", step, n, m.height, out)
		}
		want := "+ new session"
		if m.pickCursor > 0 {
			want = m.orderedSessions()[m.pickCursor-1].Title
		}
		if cl := cursorLine(out); !strings.Contains(cl, want) {
			t.Fatalf("%s: cursor row %q (pickCursor=%d) fell out of the window; cursor line=%q\n%s",
				step, want, m.pickCursor, cl, out)
		}
		return out
	}
	press := func(k tea.KeyType) {
		t.Helper()
		nm, _ := m.handlePickerKey(tea.KeyMsg{Type: k})
		m = nm.(Model)
	}

	// Initial: top of the roster, overflow only below.
	out := assertCursorVisible("initial")
	if strings.Contains(out, "more above") || !strings.Contains(out, "more below") {
		t.Fatalf("initial window must hide rows below only, got:\n%s", out)
	}

	// Down past the window edge and all the way past the roster end: the
	// viewport follows the cursor on every stroke and the cursor clamps.
	for i := 0; i < 60; i++ {
		press(tea.KeyDown)
		assertCursorVisible(fmt.Sprintf("down #%d", i+1))
	}
	if m.pickCursor != len(sessions) {
		t.Fatalf("down must clamp at the last session, got %d", m.pickCursor)
	}
	out = assertCursorVisible("down-past-edge settled")
	if !strings.Contains(out, "more above") || strings.Contains(out, "more below") {
		t.Fatalf("bottom window must hide rows above only, got:\n%s", out)
	}

	// Home jumps to the top; End back to the bottom — both keep the cursor in view.
	press(tea.KeyHome)
	if m.pickCursor != 0 {
		t.Fatalf("home must land on the new-session row, got %d", m.pickCursor)
	}
	out = assertCursorVisible("home")
	if strings.Contains(out, "more above") {
		t.Fatalf("home window must start at the top, got:\n%s", out)
	}
	press(tea.KeyEnd)
	if m.pickCursor != len(sessions) {
		t.Fatalf("end must land on the last session, got %d", m.pickCursor)
	}
	assertCursorVisible("end")

	// pgup/pgdn page by one window: a real multi-row stride, cursor always visible.
	press(tea.KeyHome)
	press(tea.KeyPgDown)
	if m.pickCursor < 2 {
		t.Fatalf("pgdn must stride a full window, got cursor %d", m.pickCursor)
	}
	assertCursorVisible("pgdn")
	firstPage := m.pickCursor
	press(tea.KeyPgDown)
	if m.pickCursor <= firstPage {
		t.Fatalf("second pgdn must keep paging, got %d after %d", m.pickCursor, firstPage)
	}
	assertCursorVisible("pgdn #2")
	press(tea.KeyPgUp)
	assertCursorVisible("pgup")
	if m.pickCursor >= len(sessions) {
		t.Fatalf("pgup must move back up, got %d", m.pickCursor)
	}

	// m.height<=0 (no WindowSizeMsg yet) shows ALL rows — never an empty paint.
	m.height = 0
	all := m.renderPicker()
	for i := range sessions {
		if !strings.Contains(all, fmt.Sprintf("session %02d", i)) {
			t.Fatalf("height<=0 must show every row, missing session %02d", i)
		}
	}
	if strings.Contains(all, "more above") || strings.Contains(all, "more below") {
		t.Fatalf("height<=0 show-all must carry no more-indicators:\n%s", all)
	}
}

// TestPickerWindowCountsPhysicalLines proves the window budget is charged in
// PHYSICAL lines, not row indices: a workflow session is ONE navigable row
// spanning THREE lines (herd row + two wsc card lines), so a viewport full of
// workflow rows admits fewer rows and still never overflows the height.
func TestPickerWindowCountsPhysicalLines(t *testing.T) {
	wf := loadWorkflowFixture(t, "workflow_building.json")
	sessions := make([]SessionSummary, 20)
	for i := range sessions {
		sessions[i] = SessionSummary{ID: fmt.Sprintf("w%02d", i),
			Title: fmt.Sprintf("wave %02d", i), MessageCount: 1, Workflow: &wf,
			Epic: &EpicGoal{Title: "epic", SlicesDone: 1, SlicesTotal: 3}}
	}
	m := Model{width: 100, height: 18, sessions: sessions}
	out := m.renderPicker()
	if n := strings.Count(out, "\n") + 1; n > m.height {
		t.Fatalf("workflow-heavy picker paints %d lines past height %d:\n%s", n, m.height, out)
	}
	if !strings.Contains(out, "more below") {
		t.Fatalf("hidden workflow rows must surface the below indicator:\n%s", out)
	}
	// The fleet notice is chrome OUTSIDE the row block: it must still paint and
	// the total must still respect the height.
	m.fleetNotice = "herd stream lost — boom"
	out = m.renderPicker()
	if !strings.Contains(out, "herd stream lost") {
		t.Fatalf("the fleet notice must always render under a windowed list:\n%s", out)
	}
	if n := strings.Count(out, "\n") + 1; n > m.height {
		t.Fatalf("noticed picker paints %d lines past height %d:\n%s", n, m.height, out)
	}
}

// ── charter D80: a frozen viewport is anchored to CONTENT, not to a line number

// d80Model builds a scrollable transcript of one-physical-line user messages,
// each carrying its own identifying text — so a drifted viewport shows up as
// DIFFERENT CONTENT, never merely a different index.
func d80Model(t *testing.T, n int) Model {
	t.Helper()
	msgs := make([]Message, 0, n)
	for i := 1; i <= n; i++ {
		msgs = append(msgs, Message{Seq: i, Role: "user", SourceMarkdown: fmt.Sprintf("msg-%02d", i)})
	}
	return wfTestModel(t, State{SessionID: "s1", Messages: msgs, LastSeq: n})
}

// d80BodyHeight mirrors renderChat's transcript budget exactly (frame minus
// chrome minus the rail band), so the tests window the same rows the reader sees.
func d80BodyHeight(m Model) int {
	h := m.bodyHeight() - len(renderRail(m.width, m.st.Rail))
	if h < 1 {
		h = 1
	}
	return h
}

func equalLines(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// TestFrozenScrollReanchorsWhenAnEarlierBlockGrows is the D80 regression proof.
// A reader freezes the transcript mid-history through the REAL key path, then a
// block ABOVE the pin grows by 11 physical lines (the measured drift floor). The
// pinned viewport must still show the EXACT lines the reader was reading.
//
// The test carries its own anti-vacuity arm: it computes the pre-anchor
// behaviour in-test (window() at the same RAW index over the grown transcript)
// and fails if that already reproduces the viewport — so the assertion can never
// pass by accident, and the drift it documents is the growth itself.
func TestFrozenScrollReanchorsWhenAnEarlierBlockGrows(t *testing.T) {
	const grow = 11
	m := d80Model(t, 40)
	bodyH := d80BodyHeight(m)

	// Freeze via the key grammar (Up), NEVER by poking m.scroll: the pin only
	// carries a content anchor because the scroll path recorded one.
	for i := 0; i < 20; i++ {
		nm, _ := m.handleChatKey(tea.KeyMsg{Type: tea.KeyUp})
		m = nm.(Model)
	}
	if m.scroll <= 0 {
		t.Fatalf("setup: the reader must be frozen ABOVE the transcript top, got scroll=%d", m.scroll)
	}
	if !m.anchor.set {
		t.Fatal("a pin made through the scroll path must record a content anchor")
	}
	before := append([]string(nil), m.transcriptViewport(bodyH)...)
	beforeCount := len(m.transcriptLines(m.width))

	// Grow a block ABOVE the pin by exactly `grow` physical lines.
	m.st.Messages[1].SourceMarkdown = "msg-02" + strings.Repeat("\nfiller", grow)
	afterAll := m.transcriptLines(m.width)
	if got := len(afterAll) - beforeCount; got != grow {
		t.Fatalf("setup: the earlier block must grow by exactly %d lines, grew %d", grow, got)
	}

	// ANTI-VACUITY: the pre-anchor behaviour must genuinely differ here.
	if raw := window(afterAll, bodyH, m.scroll); equalLines(raw, before) {
		t.Fatal("vacuous: the raw physical index already reproduces the viewport, so this test could not fail")
	}

	after := m.transcriptViewport(bodyH)
	if !equalLines(after, before) {
		t.Fatalf("a %d-line growth ABOVE the pin swapped the frozen viewport.\nwas:\n%s\n\nnow:\n%s",
			grow, strings.Join(before, "\n"), strings.Join(after, "\n"))
	}
}

// TestFollowModeUnchangedByEarlierBlockGrowth: follow (scroll = -1) is a pure
// last-N slice per frame and was already immune to height change. It must stay
// BYTE-IDENTICAL to the raw window() call — the anchor never touches it.
func TestFollowModeUnchangedByEarlierBlockGrowth(t *testing.T) {
	m := d80Model(t, 40)
	bodyH := d80BodyHeight(m)
	if m.scroll != -1 {
		t.Fatalf("setup: the model must start in follow mode, got %d", m.scroll)
	}
	if got, want := m.transcriptViewport(bodyH), window(m.transcriptLines(m.width), bodyH, -1); !equalLines(got, want) {
		t.Fatal("follow mode must be byte-identical to the raw last-N slice")
	}
	m.st.Messages[1].SourceMarkdown = "msg-02" + strings.Repeat("\nfiller", 11)
	if got, want := m.transcriptViewport(bodyH), window(m.transcriptLines(m.width), bodyH, -1); !equalLines(got, want) {
		t.Fatal("follow mode must stay byte-identical to the raw last-N slice after a height change")
	}
}

// TestUnanchoredPinKeepsRawIndexSemantics: a pin set by poking m.scroll (no
// anchor recorded) keeps the pre-D80 raw-index contract verbatim — the anchor
// corrects pins it made, it does not reinterpret ones it did not.
func TestUnanchoredPinKeepsRawIndexSemantics(t *testing.T) {
	m := d80Model(t, 40)
	bodyH := d80BodyHeight(m)
	m.scroll = 7
	if got, want := m.transcriptViewport(bodyH), window(m.transcriptLines(m.width), bodyH, 7); !equalLines(got, want) {
		t.Fatal("an unanchored pin must slice at its raw index, exactly as before")
	}
}

// TestScrollToBottomDropsTheAnchor: reaching the bottom re-enters follow and the
// anchor goes with it — a stale anchor must never survive into follow mode.
func TestScrollToBottomDropsTheAnchor(t *testing.T) {
	m := d80Model(t, 40)
	nm, _ := m.handleChatKey(tea.KeyMsg{Type: tea.KeyUp})
	m = nm.(Model)
	if !m.anchor.set {
		t.Fatal("setup: the pin must carry an anchor")
	}
	nm, _ = m.handleChatKey(tea.KeyMsg{Type: tea.KeyEnd})
	m = nm.(Model)
	if m.scroll != -1 || m.anchor.set {
		t.Fatalf("End must re-enter follow AND drop the anchor, got scroll=%d anchor=%+v", m.scroll, m.anchor)
	}
}

// TestAnchorAtRoundTripsThroughTheBlockIndex pins the coordinate system itself:
// every physical top line resolves to a (block, offset) pair that maps straight
// back to the same line in an UNCHANGED layout.
func TestAnchorAtRoundTripsThroughTheBlockIndex(t *testing.T) {
	m := d80Model(t, 12)
	all, _, starts := m.transcriptAnchored(m.width, "")
	if len(starts) != 12 {
		t.Fatalf("12 one-line messages must be 12 blocks, got %d", len(starts))
	}
	for top := 0; top < len(all); top++ {
		a := anchorAt(starts, top)
		if !a.set {
			t.Fatalf("top %d produced no anchor", top)
		}
		if got := a.resolve(starts, -1, len(all)); got != top {
			t.Fatalf("anchor round-trip broke at top %d: got %d (block %d off %d)", top, got, a.block, a.off)
		}
	}
	// An anchor whose block no longer exists degrades to the raw index rather
	// than jumping somewhere the reader never asked for.
	gone := scrollAnchor{set: true, block: 99, off: 0}
	if got := gone.resolve(starts, 5, len(all)); got != 5 {
		t.Fatalf("a vanished block must fall back to the raw pin, got %d", got)
	}
}
