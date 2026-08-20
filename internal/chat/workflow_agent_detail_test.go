package chat

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

// rawAgentDetailNode is the FULL wire shape of one agent node in the shared
// workflow_agent_detail.json fixture — including the `terminal`/`failed`
// booleans the WorkflowNode struct deliberately DOES NOT carry (charter D36:
// terminal/failed derive from State in Go, never a wire bool). The parity test
// decodes the fixture into BOTH shapes and asserts the projection + the
// derivation agree with the wire on every node.
type rawAgentDetailNode struct {
	Type            string  `json:"type"`
	State           string  `json:"state"`
	Terminal        bool    `json:"terminal"`
	Failed          bool    `json:"failed"`
	Attempt         int     `json:"attempt"`
	PromptPreview   *string `json:"promptPreview"`
	LastToolName    *string `json:"lastToolName"`
	LastToolSummary *string `json:"lastToolSummary"`
	ResultPreview   *string `json:"resultPreview"`
	LastProgressAt  *int64  `json:"lastProgressAt"`
}

func strEq(a, b *string) bool {
	if a == nil || b == nil {
		return a == b
	}
	return *a == *b
}

func i64Eq(a, b *int64) bool {
	if a == nil || b == nil {
		return a == b
	}
	return *a == *b
}

// TestWorkflowAgentDetailFieldProjectionParity is the Mechanism-A parity test
// (charter D36): the shared, byte-identical-dual-mirror fixture decodes into the
// Go WorkflowNode struct with the 6 projected agent-detail fields intact, and the
// Go-side terminal/failed DERIVATION (workflowStateTerminal/workflowStateFailed
// off State) matches the fixture's own terminal/failed booleans on every one of
// the 34 nodes — so the TUI reads the exact truth Studio's Elixir fold produced.
func TestWorkflowAgentDetailFieldProjectionParity(t *testing.T) {
	raw, err := os.ReadFile("testdata/workflow_agent_detail.json")
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}

	var projected map[string][]WorkflowNode
	if err := json.Unmarshal(raw, &projected); err != nil {
		t.Fatalf("decode into WorkflowNode: %v", err)
	}
	var wire map[string][]rawAgentDetailNode
	if err := json.Unmarshal(raw, &wire); err != nil {
		t.Fatalf("decode into raw node: %v", err)
	}

	total := 0
	for key, nodes := range projected {
		wireNodes := wire[key]
		if len(nodes) != len(wireNodes) {
			t.Fatalf("scenario %q: node count drift proj=%d wire=%d", key, len(nodes), len(wireNodes))
		}
		for i, n := range nodes {
			w := wireNodes[i]
			total++

			// the 6 projected fields survive the decode verbatim
			if n.Attempt != w.Attempt {
				t.Fatalf("%s[%d]: attempt proj=%d wire=%d", key, i, n.Attempt, w.Attempt)
			}
			if !strEq(n.PromptPreview, w.PromptPreview) {
				t.Fatalf("%s[%d]: promptPreview mismatch", key, i)
			}
			if !strEq(n.LastToolName, w.LastToolName) {
				t.Fatalf("%s[%d]: lastToolName mismatch", key, i)
			}
			if !strEq(n.LastToolSummary, w.LastToolSummary) {
				t.Fatalf("%s[%d]: lastToolSummary mismatch", key, i)
			}
			if !strEq(n.ResultPreview, w.ResultPreview) {
				t.Fatalf("%s[%d]: resultPreview mismatch", key, i)
			}
			if !i64Eq(n.LastProgressAt, w.LastProgressAt) {
				t.Fatalf("%s[%d]: lastProgressAt mismatch", key, i)
			}

			// terminal/failed DERIVE from State — and agree with the wire on every node
			if got := workflowStateTerminal(n.State); got != w.Terminal {
				t.Fatalf("%s[%d] state=%q: derived terminal=%v wire=%v", key, i, n.State, got, w.Terminal)
			}
			if got := workflowStateFailed(n.State); got != w.Failed {
				t.Fatalf("%s[%d] state=%q: derived failed=%v wire=%v", key, i, n.State, got, w.Failed)
			}
		}
	}
	if total != 34 {
		t.Fatalf("the shared fixture must carry all 34 nodes, projected %d", total)
	}
}

// TestWorkflowAgentDetailSyntheticHonesty is the D37 mandate: the shared fixture
// is VACUOUS for three stars (every node has attempt=1, none is failed), so this
// test proves them on hand-built nodes —
//
//	(a) a thin node with NO signal fields yields no affordance (agentHasDetail
//	    false) and Enter no-ops (the level never opens an empty pane);
//	(b) an attempt=3 node renders the 'attempt 3' chip (gated attempt>1);
//	(c) a state=failed node derives terminal==true AND failed==true.
func TestWorkflowAgentDetailSyntheticHonesty(t *testing.T) {
	now := time.UnixMilli(1783633800000)

	// (a) thin node → no affordance, Enter no-ops
	thin := WorkflowNode{Type: "workflow_agent", PhaseIndex: 1, Label: "background", State: "progress"}
	if agentHasDetail(thin) {
		t.Fatal("(a) a signal-less node must have no detail affordance")
	}
	wf := &Workflow{Status: "running", Nodes: []WorkflowNode{
		{Type: "workflow_phase", Index: 1, Title: "P"},
		thin,
	}}
	m := wfTestModel(t, State{SessionID: "s1", Workflow: wf})
	m.focus = focusWorkflow
	m.wfExpanded = true
	m.wfPhase = 0
	nm, _ := m.handleChatKey(tea.KeyMsg{Type: tea.KeyEnter})
	if nm.(Model).wfAgentDetail {
		t.Fatal("(a) Enter on a signal-less agent must be an honest no-op")
	}

	// (b) attempt=3 → chip renders
	prompt := "do the thing"
	retry := WorkflowNode{Type: "workflow_agent", PhaseIndex: 1, Label: "builder",
		State: "progress", Attempt: 3, PromptPreview: &prompt, StartedAt: ptrI64(1783633700000)}
	if !agentHasDetail(retry) {
		t.Fatal("(b) an attempt=3 node must have a detail affordance")
	}
	pane := renderAgentDetailFor(retry, "live", now)
	if !strings.Contains(pane, "attempt 3") {
		t.Fatalf("(b) an attempt=3 node must render the chip, got:\n%s", pane)
	}
	// a single attempt must NOT render a chip (gate is attempt>1)
	once := retry
	once.Attempt = 1
	if strings.Contains(renderAgentDetailFor(once, "live", now), "attempt 1") {
		t.Fatal("(b) attempt=1 must not render a chip")
	}

	// (c) state=failed derives terminal AND failed
	if !workflowStateTerminal("failed") || !workflowStateFailed("failed") {
		t.Fatal("(c) a failed state must derive BOTH terminal and failed")
	}
}

// TestWorkflowAgentDetailPresentation is the D39 render contract (mirror of the
// shipped GUI #3959): a LIVE node paints the bare '▸' NOW line with the tool
// name (no 'thinking' label anywhere); a TERMINAL node paints the lowercase
// 'done' result; and every absent field is OMITTED, never a bare label.
func TestWorkflowAgentDetailPresentation(t *testing.T) {
	now := time.UnixMilli(1783633800000)

	// live node → ▸ NOW line, tool name, summary, age; NO 'done', NO 'thinking'
	prompt := "survey the codebase"
	tool := "Grep"
	summary := "searching for the resolver"
	live := WorkflowNode{Type: "workflow_agent", PhaseIndex: 1, Label: "explore:x",
		State: "progress", Attempt: 1, PromptPreview: &prompt,
		LastToolName: &tool, LastToolSummary: &summary,
		LastProgressAt: ptrI64(1783633740000), StartedAt: ptrI64(1783633700000)}
	pane := renderAgentDetailFor(live, "live", now)
	for _, want := range []string{"▸", "Grep", "searching for the resolver", "about", "survey the codebase"} {
		if !strings.Contains(pane, want) {
			t.Fatalf("live pane must contain %q, got:\n%s", want, pane)
		}
	}
	if strings.Contains(pane, "done") {
		t.Fatalf("a live node must NOT paint the terminal 'done' line, got:\n%s", pane)
	}
	if strings.Contains(strings.ToLower(pane), "thinking") {
		t.Fatalf("nothing may ever be labeled 'thinking', got:\n%s", pane)
	}

	// terminal node → lowercase 'done' + result; NO ▸ NOW line
	result := "shipped the fold and its parity test"
	done := WorkflowNode{Type: "workflow_agent", PhaseIndex: 1, Label: "builder",
		State: "done", Attempt: 1, PromptPreview: &prompt, ResultPreview: &result,
		DurationMs: ptrI64(120000), StartedAt: ptrI64(1783633700000)}
	pane = renderAgentDetailFor(done, "live", now)
	if !strings.Contains(pane, "done") || !strings.Contains(pane, "shipped the fold") {
		t.Fatalf("terminal pane must paint 'done' + result, got:\n%s", pane)
	}
	if strings.Contains(pane, "▸") {
		t.Fatalf("a terminal node must NOT paint the live '▸' NOW line, got:\n%s", pane)
	}

	// absent-field node → the pane omits every missing field (no bare labels)
	bare := WorkflowNode{Type: "workflow_agent", PhaseIndex: 1, Label: "quiet",
		State: "progress", Attempt: 1, PromptPreview: &prompt}
	pane = renderAgentDetailFor(bare, "live", now)
	if strings.Contains(pane, "▸") {
		t.Fatalf("a node with no tool fields must omit the NOW line, got:\n%s", pane)
	}
	if strings.Contains(pane, "done") {
		t.Fatalf("a non-terminal node must omit the 'done' line, got:\n%s", pane)
	}
}

// TestWorkflowAgentDetailWidthDiscipline: a long brief/result never overruns the
// pane width — the labeled 'about'/'done' block reserves its label width on the
// first line (house discipline, mirroring workflowAgentLine's budget), so the
// terminal never wraps a tail ugly.
func TestWorkflowAgentDetailWidthDiscipline(t *testing.T) {
	now := time.UnixMilli(1783633800000)
	longPrompt := strings.Repeat("survey the resolver and its callers exhaustively ", 12)
	longResult := strings.Repeat("shipped the fold plus its parity and honesty tests ", 12)

	for _, tc := range []struct {
		name  string
		width int
		node  WorkflowNode
	}{
		{"live-brief", 80, WorkflowNode{State: "progress", Attempt: 2, PromptPreview: &longPrompt,
			LastToolName: strPtr("Grep"), LastToolSummary: &longPrompt, LastProgressAt: ptrI64(1783633740000)}},
		{"done-result", 80, WorkflowNode{State: "done", PromptPreview: &longPrompt, ResultPreview: &longResult}},
		{"narrow", 40, WorkflowNode{State: "done", PromptPreview: &longPrompt, ResultPreview: &longResult}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			a := tc.node
			a.Type = "workflow_agent"
			a.PhaseIndex = 1
			wf := &Workflow{Status: "running", Nodes: []WorkflowNode{
				{Type: "workflow_phase", Index: 1, Title: "Phase"}, a,
			}}
			for _, ln := range renderWorkflowAgentDetail(tc.width, journeyOf(wf), now, 0, 0, true) {
				if w := lipgloss.Width(ln); w > tc.width {
					t.Fatalf("pane line overruns width %d (got %d): %q", tc.width, w, ln)
				}
			}
		})
	}
}

func strPtr(s string) *string { return &s }

// renderAgentDetailFor wraps one agent in a single-phase journey and paints its
// detail pane — the render harness for the presentation + chip assertions.
func renderAgentDetailFor(a WorkflowNode, entryStatus string, now time.Time) string {
	a.Type = "workflow_agent"
	a.PhaseIndex = 1
	status := "running"
	if entryStatus == "completed" {
		status = "completed"
	}
	wf := &Workflow{Status: status, Nodes: []WorkflowNode{
		{Type: "workflow_phase", Index: 1, Title: "Phase"},
		a,
	}}
	j := journeyOf(wf)
	return strings.Join(renderWorkflowAgentDetail(80, j, now, 0, 0, true), "\n")
}

func ptrI64(v int64) *int64 { return &v }
