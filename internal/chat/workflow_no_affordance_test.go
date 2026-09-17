package chat

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

// ── the NO-AFFORDANCE path, proven rather than traced (wsc-bl-agent-detail-
// fixture-gaps) ──────────────────────────────────────────────────────────────
//
// Before this file the "no detail → no expand affordance" rule was proven only
// by code trace: `rail_apply_codex_item` never writes detail fields, and a
// background task without a nested workflow projects an empty node list. Two
// committed rail fixtures now carry those REAL wire shapes:
//
//   - rail_codex_origin.json          — two codex threads, NO `workflow` key at
//     all (exactly what rail_apply_codex_item/3 writes: row + origin + model +
//     status, nothing else).
//   - rail_background_no_workflow.json — a background `agent` row with no
//     workflow key, and a background `local_workflow` row carrying the SEEDED
//     BUT EMPTY envelope seed_workflow_envelope/2 writes (`"workflow": []`,
//     `"usage": null`) — a well-formed envelope with nothing in it.
// The harder negative — a codex entry that DOES carry workflow nodes, so the
// strip paints and the phase level opens, but whose agent nodes are detail-less
// — lives INLINE below as thinCodexRail, NOT as a committed testdata file. It
// cannot be one: api/test/barkpark/studio_chat_test.exs:2899 globs
// "internal/chat/testdata/*.json" and asserts EVERY workflow_agent node in this
// directory carries attempt == 1 (the D21/D25 no-fabricated-retry proof) — and
// attempt > 0 is one of the five signals agentHasDetail reads, so a committed
// mirror can NEVER hold a detail-less agent node. The shape is real wire either
// way; only its storage moved.
//
// An absence is never caught by inspection, so every negative arm below is
// paired with (a) a PRECONDITION that the path was actually reached and (b) a
// CONTROL built from the same bytes that DOES produce the affordance.

var noAffordanceFixtures = []string{
	"rail_codex_origin.json",
	"rail_background_no_workflow.json",
}

// thinCodexRail is the detail-less workflow arm, held in Go source rather than
// testdata for the reason stated above. Two workflow_agent nodes with NO
// promptPreview / lastToolName / lastToolSummary / resultPreview and NO attempt
// key — the "thin mid-persist frame" agentHasDetail's own doc comment names.
const thinCodexRail = `{
 "01JQ8TH3CODEXTHREADCCCC": {
  "status": "running",
  "seq": 3,
  "row": {"task_type": "collab_agent_tool_call", "description": "Codex fleet - thin persist frame"},
  "origin": "codex",
  "usage": null,
  "workflow": [
   {"type": "workflow_phase", "index": 1, "title": "Survey"},
   {"type": "workflow_agent", "index": 1, "label": "survey:rail", "phaseIndex": 1,
    "phaseTitle": "Survey", "agentId": "cdx1a2b3c4d5e6f70", "agentType": "Explore",
    "model": "gpt-5-codex", "state": "start", "startedAt": 1782767557221},
   {"type": "workflow_agent", "index": 2, "label": "survey:keys", "phaseIndex": 1,
    "phaseTitle": "Survey", "agentId": "cdx1a2b3c4d5e6f71", "agentType": "Explore",
    "model": "gpt-5-codex", "state": "start", "startedAt": 1782767557231}
  ]
 }
}`

func railKeySet(entries map[string]railWireEntry) []string {
	keys := make([]string, 0, len(entries))
	for k := range entries {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// TestNoAffordanceFixturesAreReachable is the PRECONDITION gate for every
// negative arm in this file: each committed negative fixture must decode into a
// non-empty rail with rows that really would paint. Without this, a typo'd
// filename or an unparseable fixture would make every "nothing rendered"
// assertion below pass vacuously.
func TestNoAffordanceFixturesAreReachable(t *testing.T) {
	for _, name := range noAffordanceFixtures {
		raw := loadRailFixture(t, name)
		entries := decodeRailWire(raw)
		if len(entries) == 0 {
			t.Fatalf("%s: decoded ZERO rail entries — every negative assertion over it would be vacuous", name)
		}
		t.Logf("%s: %d rail entries, keys=%v", name, len(entries), railKeySet(entries))
		for tid, e := range entries {
			if e.Row.Description == "" {
				t.Fatalf("%s[%s]: no row.description — not a rail row that would paint", name, tid)
			}
			if e.Status == "" {
				t.Fatalf("%s[%s]: no status — the entry never went through a real fold", name, tid)
			}
			if e.contractError != "" {
				t.Fatalf("%s[%s]: contract error %q — this fixture would render the ENVELOPE warning, "+
					"not the no-affordance path", name, tid, e.contractError)
			}
		}
	}
}

// TestCodexAndWorkflowlessBackgroundRailsHaveNoWorkflowPanel: the two realistic
// negatives project to NO workflow at all — no strip, no panel lines, no phases,
// and Enter with the panel focused cannot expand anything.
//
// FAILURE DIRECTION: delete the `len(e.Workflow) == 0 && e.contractError == ""`
// skip in decodeWorkflow and this test reds — a codex thread with no workflow
// list would decode into a Workflow and paint a clickable strip.
func TestCodexAndWorkflowlessBackgroundRailsHaveNoWorkflowPanel(t *testing.T) {
	for _, name := range noAffordanceFixtures {
		raw := loadRailFixture(t, name)

		if wf := decodeWorkflow(raw); wf != nil {
			t.Fatalf("%s: must project NO workflow, got %+v", name, wf)
		}

		m := wfTestModel(t, State{SessionID: "s1", Workflow: decodeWorkflow(raw)})
		if m.workflowStripVisible() {
			t.Fatalf("%s: no workflow ⇒ no strip", name)
		}
		if lines := m.workflowPanelLines(); lines != nil {
			t.Fatalf("%s: no workflow ⇒ no panel lines, got %d: %q", name, len(lines), lines)
		}
		if n := len(journeyOf(m.st.Workflow).Phases); n != 0 {
			t.Fatalf("%s: no workflow ⇒ no phases, got %d", name, n)
		}

		// the hit target: even with the panel forced into focus, Enter cannot open
		// a level over these rows.
		m.focus = focusWorkflow
		got := m
		for i := 0; i < 3; i++ {
			nm, _ := got.handleChatKey(tea.KeyMsg{Type: tea.KeyEnter})
			got = nm.(Model)
			if got.wfExpanded || got.wfAgentDetail {
				t.Fatalf("%s: Enter #%d opened a level over a detail-less rail (expanded=%v detail=%v)",
					name, i+1, got.wfExpanded, got.wfAgentDetail)
			}
		}
	}
}

// TestNoAffordanceFixturesCanProduceAnAffordance is the CONTROL for the arm
// above: take the SAME committed negative bytes, splice the real epic-cycle node
// list into the highest-seq entry, and the strip + panel + phases all appear. So
// the fixtures are shaped like rails the panel CAN read — their emptiness is the
// projection's verdict, not a broken fixture.
func TestNoAffordanceFixturesCanProduceAnAffordance(t *testing.T) {
	live := loadRailFixture(t, "rail_workflow_live.json")
	var liveRail map[string]map[string]json.RawMessage
	if err := json.Unmarshal(live, &liveRail); err != nil {
		t.Fatalf("decode live fixture: %v", err)
	}
	var nodes json.RawMessage
	for _, e := range liveRail {
		if wf, ok := e["workflow"]; ok {
			nodes = wf
		}
	}
	if len(nodes) == 0 {
		t.Fatal("control source carries no workflow nodes — the control would prove nothing")
	}

	for _, name := range noAffordanceFixtures {
		var rail map[string]map[string]json.RawMessage
		if err := json.Unmarshal(loadRailFixture(t, name), &rail); err != nil {
			t.Fatalf("%s: decode: %v", name, err)
		}
		// pick a deterministic entry (highest task id) and make it workflow-bearing
		ids := make([]string, 0, len(rail))
		for id := range rail {
			ids = append(ids, id)
		}
		sort.Strings(ids)
		target := ids[len(ids)-1]
		rail[target]["workflow"] = nodes
		rail[target]["status"] = json.RawMessage(`"running"`)
		rail[target]["usage"] = json.RawMessage(`null`)
		spliced, err := json.Marshal(rail)
		if err != nil {
			t.Fatalf("%s: re-encode: %v", name, err)
		}

		wf := decodeWorkflow(spliced)
		if wf == nil {
			t.Fatalf("%s + real nodes: the control must decode a workflow", name)
		}
		m := wfTestModel(t, State{SessionID: "s1", Workflow: wf})
		if !m.workflowStripVisible() {
			t.Fatalf("%s + real nodes: the control must show the strip", name)
		}
		if len(m.workflowPanelLines()) == 0 {
			t.Fatalf("%s + real nodes: the control must paint panel lines", name)
		}
		m.focus = focusWorkflow
		nm, _ := m.handleChatKey(tea.KeyMsg{Type: tea.KeyEnter})
		if !nm.(Model).wfExpanded {
			t.Fatalf("%s + real nodes: the control's Enter must expand", name)
		}
	}
}

// TestThinCodexWorkflowOffersNoAgentDetail is the agentHasDetail gate proven over
// a real wire shape: a codex entry whose workflow nodes carry NO signal field.
// The strip paints, Enter opens the phase — so the drill code REACHES the gate —
// and the second Enter is an honest no-op.
//
// FAILURE DIRECTION: drop the `&& agentHasDetail(visible[0])` conjunct from the
// depth-1 Enter branch in keys.go and this test reds — the second Enter would
// open an empty agent pane over rows with nothing to show.
func TestThinCodexWorkflowOffersNoAgentDetail(t *testing.T) {
	raw := json.RawMessage(thinCodexRail)
	// PRECONDITION: the inline rail really decodes — a typo'd literal would make
	// every "no affordance" assertion below pass for the wrong reason.
	if n := len(decodeRailWire(raw)); n != 1 {
		t.Fatalf("thin rail decoded %d entries, want 1 — the arm below would be vacuous", n)
	}
	wf := decodeWorkflow(raw)
	if wf == nil {
		t.Fatal("the thin fixture MUST still project a workflow — otherwise this test never reaches the agent gate")
	}

	j := journeyOf(wf)
	// PRECONDITION: the gate is reachable — phases exist and phase 0 has visible agents.
	if len(j.Phases) == 0 {
		t.Fatal("thin fixture: no phases — the drill would no-op for the WRONG reason")
	}
	visible, _, _ := visibleAgents(j.Phases[0])
	if len(visible) == 0 {
		t.Fatal("thin fixture: phase 0 has no visible agents — the agentHasDetail gate is never consulted")
	}
	for i, a := range visible {
		if agentHasDetail(a) {
			t.Fatalf("thin fixture agent %d (%s) carries a detail signal — it is not a negative", i, a.Label)
		}
	}

	m := wfTestModel(t, State{SessionID: "s1", Workflow: wf})
	if !m.workflowStripVisible() {
		t.Fatal("thin fixture: the strip MUST be visible (this negative is about the third level only)")
	}
	m.focus = focusWorkflow

	nm, _ := m.handleChatKey(tea.KeyMsg{Type: tea.KeyEnter})
	got := nm.(Model)
	if !got.wfExpanded {
		t.Fatal("thin fixture: the first Enter must open the PHASE level — the gate is only reached from there")
	}
	if got.wfAgentDetail {
		t.Fatal("thin fixture: the first Enter must not drill to the agent level")
	}

	nm, _ = got.handleChatKey(tea.KeyMsg{Type: tea.KeyEnter})
	got = nm.(Model)
	if got.wfAgentDetail {
		t.Fatal("thin fixture: the second Enter opened an agent pane over detail-less rows")
	}
}

// TestThinCodexWorkflowDrillsOnceOneAgentHasDetail is the CONTROL for the arm
// above: the SAME committed fixture with ONE promptPreview added to agent 0 DOES
// open the third level. So the thin fixture is capable of an affordance — the
// no-op is agentHasDetail's verdict, not an unreachable code path.
func TestThinCodexWorkflowDrillsOnceOneAgentHasDetail(t *testing.T) {
	var rail map[string]map[string]json.RawMessage
	if err := json.Unmarshal([]byte(thinCodexRail), &rail); err != nil {
		t.Fatalf("decode: %v", err)
	}
	for _, e := range rail {
		var nodes []map[string]any
		if err := json.Unmarshal(e["workflow"], &nodes); err != nil {
			t.Fatalf("decode nodes: %v", err)
		}
		patched := 0
		for _, n := range nodes {
			if n["type"] == "workflow_agent" {
				n["promptPreview"] = "sweep internal/chat for rail decode forks"
				patched++
				break
			}
		}
		if patched != 1 {
			t.Fatalf("the control patched %d agent nodes, want exactly 1", patched)
		}
		b, err := json.Marshal(nodes)
		if err != nil {
			t.Fatalf("re-encode nodes: %v", err)
		}
		e["workflow"] = b
	}
	spliced, err := json.Marshal(rail)
	if err != nil {
		t.Fatalf("re-encode rail: %v", err)
	}

	wf := decodeWorkflow(spliced)
	if wf == nil {
		t.Fatal("the control must still project a workflow")
	}
	j := journeyOf(wf)
	visible, _, _ := visibleAgents(j.Phases[0])
	if len(visible) == 0 || !agentHasDetail(visible[0]) {
		t.Fatal("the control's agent 0 must carry a detail signal")
	}

	m := wfTestModel(t, State{SessionID: "s1", Workflow: wf})
	m.focus = focusWorkflow
	nm, _ := m.handleChatKey(tea.KeyMsg{Type: tea.KeyEnter})
	got := nm.(Model)
	if !got.wfExpanded {
		t.Fatal("the control's first Enter must open the phase level")
	}
	nm, _ = got.handleChatKey(tea.KeyMsg{Type: tea.KeyEnter})
	got = nm.(Model)
	if !got.wfAgentDetail || got.wfAgent != 0 {
		t.Fatalf("the control's second Enter MUST drill (detail=%v agent=%d) — without this, "+
			"TestThinCodexWorkflowOffersNoAgentDetail proves nothing", got.wfAgentDetail, got.wfAgent)
	}
	// The pane really paints for the control. `nil` here is the "no task join
	// data" seam the byte-locked agent-detail tests use — the assertion is on the
	// agent's OWN label, which no join can supply, so a nil lookup cannot make
	// this arm pass or fail for the wrong reason.
	lines := renderWorkflowAgentDetail(got.width, j, got.now(), got.wfPhase, got.wfAgent, true, nil)
	if len(lines) == 0 {
		t.Fatal("the control's agent pane must paint lines")
	}
	if !strings.Contains(strings.Join(lines, "\n"), visible[0].Label) {
		t.Fatalf("the control's pane must name the drilled agent %q, got:\n%s",
			visible[0].Label, strings.Join(lines, "\n"))
	}
}

// TestPositiveAgentDetailFixtureStaysNonEmpty pins the existing POSITIVE shared
// parity fixture against collateral damage from the negatives landed here: both
// committed scenarios must still project a non-empty agent-detail roster, and
// every node in them must still pass agentHasDetail.
func TestPositiveAgentDetailFixtureStaysNonEmpty(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "workflow_agent_detail.json"))
	if err != nil {
		t.Fatalf("read positive fixture: %v", err)
	}
	var byScenario map[string][]WorkflowNode
	if err := json.Unmarshal(raw, &byScenario); err != nil {
		t.Fatalf("decode positive fixture: %v", err)
	}
	if len(byScenario) == 0 {
		t.Fatal("the positive parity fixture is empty")
	}
	for name, nodes := range byScenario {
		if len(nodes) == 0 {
			t.Fatalf("positive scenario %q went EMPTY — the negatives must not have touched it", name)
		}
		for i, n := range nodes {
			if !agentHasDetail(n) {
				t.Fatalf("positive scenario %q node %d lost every detail signal", name, i)
			}
		}
	}
	t.Logf("positive fixture intact: %d scenarios", len(byScenario))
}
