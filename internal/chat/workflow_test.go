package chat

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// workflow_test.go — parity proofs for the Go port of Studio's workflow-journey
// truth table (wave session-card charter D13–D15). The heavy fixtures in
// testdata/rail_workflow_*.json are REAL wire shapes: their workflow node lists
// are lifted verbatim from the committed api/test/fixtures/claude_chat/
// epic_cycle_*.ndjson captures (studio-chat charter D62 fixture provenance),
// wrapped in the rail_snapshot entry shape the Recorder persists
// (rail_capture_progress / rail_apply_background / the D5 end_time stamp).

// loadRailFixture reads one testdata rail_snapshot and returns its raw bytes.
func loadRailFixture(t *testing.T, name string) json.RawMessage {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatalf("read fixture %s: %v", name, err)
	}
	return raw
}

// TestWorkflowStateSetsNeverEnumerate is the D58/D4 set proof: status logic
// consults the ported terminal?/failed? SETS, so the live states beyond "start"
// ("progress" is real wire data) and the case-insensitive terminals all resolve
// — an enumeration of {start, done} would fail this.
func TestWorkflowStateSetsNeverEnumerate(t *testing.T) {
	for _, live := range []string{"start", "progress", "", "queued"} {
		if workflowStateTerminal(live) {
			t.Fatalf("state %q must read live (non-terminal)", live)
		}
		if workflowStateFailed(live) {
			t.Fatalf("state %q must not read failed", live)
		}
	}
	for _, s := range []string{"done", "completed", "Done", "COMPLETED"} {
		if !workflowStateTerminal(s) || workflowStateFailed(s) {
			t.Fatalf("state %q must read success-terminal", s)
		}
	}
	for _, s := range []string{"failed", "error", "canceled", "cancelled", "aborted", "Error"} {
		if !workflowStateTerminal(s) || !workflowStateFailed(s) {
			t.Fatalf("state %q must read failure-terminal", s)
		}
	}
}

// TestDecodeWorkflowPicksHighestSeq is the D3 pick rule: the highest-seq rail
// entry carrying a non-empty workflow list wins; entries without a workflow
// never qualify; a snapshot with none yields nil (plain chats pay zero).
func TestDecodeWorkflowPicksHighestSeq(t *testing.T) {
	snap := json.RawMessage(`{
		"plain": {"status":"running","seq":9,"row":{"description":"no workflow here"}},
		"old":   {"status":"completed","seq":1,"row":{"description":"old run"},
		          "workflow":[{"type":"workflow_phase","index":1,"title":"P"}]},
		"new":   {"status":"running","seq":2,"row":{"description":"new run"},
		          "workflow":[{"type":"workflow_phase","index":1,"title":"P"}]}
	}`)
	wf := decodeWorkflow(snap)
	if wf == nil || wf.TaskID != "new" || wf.Label != "new run" {
		t.Fatalf("must pick the highest-seq workflow-bearing entry, got %+v", wf)
	}
	if decodeWorkflow(json.RawMessage(`{"t":{"status":"running","seq":1}}`)) != nil {
		t.Fatal("a snapshot with no workflow entry must decode to nil")
	}
	if decodeWorkflow(json.RawMessage(`{"early":{"status":"running","seq":1,"row":{"task_type":"local_workflow"},"workflow":[],"usage":null}}`)) != nil {
		t.Fatal("an explicit pre-progress local_workflow envelope must remain a legitimate empty workflow")
	}
	if decodeWorkflow(nil) != nil {
		t.Fatal("an absent snapshot must decode to nil")
	}
}

// TestWorkflowRailEnvelopeDriftIsVisible locks the Barkpark-owned half of the
// rail seam. Workflow node fields are third-party telemetry and intentionally
// remain passthrough; workflow/status/usage are our envelope. A rename of any
// owned key must paint an explicit failure after both full-session hydration
// paths instead of becoming an empty workflow that vanishes from the TUI.
func TestWorkflowRailEnvelopeDriftIsVisible(t *testing.T) {
	base := map[string]any{
		"status": "running",
		"seq":    1,
		"row":    map[string]any{"task_type": "local_workflow", "description": "compatibility run"},
		"usage":  map[string]any{"total_tokens": 10},
		"workflow": []map[string]any{
			{"type": "workflow_phase", "index": 1, "title": "Build"},
			{"type": "workflow_agent", "phaseIndex": 1, "label": "build:rail", "state": "start"},
		},
	}

	for _, missing := range []string{"workflow", "status", "usage"} {
		t.Run("missing_"+missing, func(t *testing.T) {
			entry := make(map[string]any, len(base))
			for key, value := range base {
				entry[key] = value
			}
			delete(entry, missing)
			raw, err := json.Marshal(map[string]any{"task": entry})
			if err != nil {
				t.Fatalf("marshal rail: %v", err)
			}

			assertVisible := func(t *testing.T, m Model) {
				t.Helper()
				if m.st.Workflow == nil || !strings.Contains(m.st.Workflow.ContractError, missing) {
					t.Fatalf("missing %s must survive decode as a contract error, got %+v", missing, m.st.Workflow)
				}
				paint := strings.Join(m.workflowPanelLines(), "\n")
				if !strings.Contains(paint, "workflow data unavailable") || !strings.Contains(paint, missing) {
					t.Fatalf("missing %s must paint a visible failure, got %q", missing, paint)
				}
			}

			resumed := newTestModel(&fakeTransport{})
			resumed.width = 80
			resumed = resumed.openSession(Session{ID: "s1", RailSnapshot: raw})
			resumed.st.LiveWorkflow = &SessionWorkflow{Terminal: true, Outcome: "completed"}
			assertVisible(t, resumed)

			st, _ := Reduce(State{
				SessionID:    "s1",
				LiveWorkflow: &SessionWorkflow{Terminal: true, Outcome: "completed"},
			}, TailFetchedEvent{
				Session: Session{ID: "s1", RailSnapshot: raw},
			}, time.Now())
			refetched := newTestModel(&fakeTransport{})
			refetched.width = 80
			refetched.screen = screenChat
			refetched.st = st
			assertVisible(t, refetched)
		})
	}
}

// TestJourneyLiveFixture drives the ported grouping over the REAL mid-run
// epic-cycle capture (frame 41 of epic_cycle_progress.ndjson): 7 phases,
// agents through phase 6 (the frontier), 23 done + 5 live. The expected
// numbers are the Elixir workflow_journey/1 outputs for the same nodes.
func TestJourneyLiveFixture(t *testing.T) {
	wf := decodeWorkflow(loadRailFixture(t, "rail_workflow_live.json"))
	if wf == nil {
		t.Fatal("live fixture must decode a workflow")
	}
	if wf.Label != "core-auth-phases-2-5 — 7-phase epic cycle" {
		t.Fatalf("label must be the entry's row.description verbatim (one opaque string, D3), got %q", wf.Label)
	}
	j := journeyOf(wf)
	if j.EntryStatus != "live" {
		t.Fatalf("running entry must read live, got %q", j.EntryStatus)
	}
	if len(j.Phases) != 7 {
		t.Fatalf("want 7 phases, got %d", len(j.Phases))
	}
	wantStatus := []string{"done", "done", "done", "done", "done", "active", "future"}
	for i, want := range wantStatus {
		if j.Phases[i].Status != want {
			t.Fatalf("phase %d (%s) status: want %s got %s", i+1, j.Phases[i].Title, want, j.Phases[i].Status)
		}
	}
	if j.AgentsTotal != 28 || j.Done != 23 || j.Running != 5 || j.Failed != 0 {
		t.Fatalf("agent counts drifted: total=%d done=%d running=%d failed=%d",
			j.AgentsTotal, j.Done, j.Running, j.Failed)
	}
	if j.Settled() != 23 {
		t.Fatalf("settled (done+failed) must be 23, got %d", j.Settled())
	}
	if j.Active != 5 {
		t.Fatalf("active phase position must be 5 (phase 6), got %d", j.Active)
	}
	if !j.HasTokens || j.Tokens != 1552004 {
		t.Fatalf("tokens must sum the persisted node figures (1552004), got %d has=%v", j.Tokens, j.HasTokens)
	}
	if j.StartedAt == nil || *j.StartedAt != 1782767557221 {
		t.Fatalf("StartedAt must be the min agent startedAt, got %v", j.StartedAt)
	}
	// live elapsed = now − min(startedAt), from wire figures only
	now := time.UnixMilli(1782767557221).Add(90 * time.Second)
	el, ok := workflowElapsed(wf, j, now)
	if !ok || el != 90*time.Second {
		t.Fatalf("live elapsed must be now−min(startedAt)=90s, got %v ok=%v", el, ok)
	}
}

// TestJourneyInterruptedFixture is the honesty proof (charter D15): the REAL
// interrupted capture has 1 settled strategist + 4 mid-flight "progress"
// surveyors that keep startedAt but never earned durationMs. The frontier
// phase reads interrupted, the untouched phases unreached — and no elapsed is
// synthesized for the dead entry or its mid-flight agents.
func TestJourneyInterruptedFixture(t *testing.T) {
	wf := decodeWorkflow(loadRailFixture(t, "rail_workflow_interrupted.json"))
	if wf == nil {
		t.Fatal("interrupted fixture must decode a workflow")
	}
	j := journeyOf(wf)
	if j.EntryStatus != "interrupted" {
		t.Fatalf("entry must read interrupted, got %q", j.EntryStatus)
	}
	wantStatus := []string{"done", "interrupted", "unreached", "unreached", "unreached", "unreached", "unreached"}
	for i, want := range wantStatus {
		if j.Phases[i].Status != want {
			t.Fatalf("phase %d status: want %s got %s", i+1, want, j.Phases[i].Status)
		}
	}
	if j.AgentsTotal != 5 || j.Settled() != 1 {
		t.Fatalf("want 1/5 settled, got %d/%d", j.Settled(), j.AgentsTotal)
	}

	// The dead entry has no end_time (s2's stamp never landed before the kill)
	// → whole-run elapsed is OMITTED, never now−startedAt on a corpse.
	now := time.UnixMilli(*j.StartedAt).Add(time.Hour)
	if _, ok := workflowElapsed(wf, j, now); ok {
		t.Fatal("an interrupted entry without end_time must omit whole-run elapsed (D15)")
	}
	// Mid-flight agents: startedAt present, durationMs absent, entry dead →
	// elapsed omitted (a growing fake clock on a dead run is a lie).
	for _, a := range j.Phases[1].Agents {
		if workflowStateTerminal(a.State) {
			continue
		}
		if a.StartedAt == nil {
			t.Fatalf("fixture drift: mid-flight agent %q must carry startedAt", a.Label)
		}
		if _, ok := agentElapsed(a, j.EntryStatus, now); ok {
			t.Fatalf("mid-flight agent %q of a dead entry must omit elapsed", a.Label)
		}
	}
	// The settled strategist DID earn durationMs → its elapsed renders.
	strategist := j.Phases[0].Agents[0]
	if el, ok := agentElapsed(strategist, j.EntryStatus, now); !ok || el <= 0 {
		t.Fatalf("terminal agent with durationMs must render elapsed, got %v ok=%v", el, ok)
	}
}

// TestJourneyCompletedFixture: the finished 29-agent run. Every phase done,
// whole-run elapsed = entry end_time − min(startedAt) (the D5 terminal rule),
// and the strip is NOT visible any more (settles/disappears on terminal).
func TestJourneyCompletedFixture(t *testing.T) {
	raw := loadRailFixture(t, "rail_workflow_completed.json")
	wf := decodeWorkflow(raw)
	j := journeyOf(wf)
	if j.EntryStatus != "completed" {
		t.Fatalf("entry must read completed, got %q", j.EntryStatus)
	}
	for i, p := range j.Phases {
		if p.Status != "done" {
			t.Fatalf("phase %d of a completed run with agents everywhere must be done, got %s", i+1, p.Status)
		}
	}
	if j.AgentsTotal != 29 || j.Settled() != 29 || j.Running != 0 {
		t.Fatalf("want 29/29 settled, got %d/%d running=%d", j.Settled(), j.AgentsTotal, j.Running)
	}
	if wf.EndTime == nil {
		t.Fatal("completed fixture must carry the D5 end_time stamp")
	}
	el, ok := workflowElapsed(wf, j, time.Now())
	want := time.UnixMilli(*wf.EndTime).Sub(time.UnixMilli(*j.StartedAt))
	if !ok || el != want {
		t.Fatalf("terminal elapsed must be end_time−min(startedAt)=%v, got %v ok=%v", want, el, ok)
	}

	m := Model{width: 80, height: 24, screen: screenChat, st: State{Workflow: wf}}
	if m.workflowStripVisible() {
		t.Fatal("the strip must disappear once the workflow entry is terminal")
	}
}

// TestJourneySyntheticEdges covers the branches the real captures don't carry
// (synthetic-only today per charter D4's caveat): a skipped phase on a
// completed run, an error agent counted failed-not-done, and a failed agent
// still counting as settled.
func TestJourneySyntheticEdges(t *testing.T) {
	started := int64(1000)
	dur := int64(2000)
	toks := 500
	wf := &Workflow{
		Status: "completed",
		Label:  "synthetic",
		Nodes: []WorkflowNode{
			{Type: "workflow_phase", Index: 1, Title: "Build"},
			{Type: "workflow_phase", Index: 2, Title: "Perfect"},
			{Type: "workflow_agent", Label: "build:thing", PhaseIndex: 1, State: "done",
				StartedAt: &started, DurationMs: &dur, Tokens: &toks},
			{Type: "workflow_agent", Label: "build:other", PhaseIndex: 1, State: "error",
				StartedAt: &started},
		},
	}
	j := journeyOf(wf)
	if j.Phases[0].Status != "done" || j.Phases[1].Status != "skipped" {
		t.Fatalf("agentless phase on a completed run must read skipped, got %s/%s",
			j.Phases[0].Status, j.Phases[1].Status)
	}
	if j.Skipped != 1 || j.PhasesRun != 1 {
		t.Fatalf("summary must count 1 run + 1 skipped, got run=%d skipped=%d", j.PhasesRun, j.Skipped)
	}
	if j.Done != 1 || j.Failed != 1 {
		t.Fatalf("an error agent is failed, never done: done=%d failed=%d", j.Done, j.Failed)
	}
	if j.Settled() != 2 {
		t.Fatalf("a failure IS settled (honest 13/17 counting): settled=%d", j.Settled())
	}

	// live entry: agentless phase reads future instead
	wf.Status = "running"
	if j := journeyOf(wf); j.Phases[1].Status != "future" {
		t.Fatalf("agentless phase on a live run must read future, got %s", j.Phases[1].Status)
	}
	// interrupted entry: unreached
	wf.Status = "interrupted"
	if j := journeyOf(wf); j.Phases[1].Status != "unreached" {
		t.Fatalf("agentless phase on an interrupted run must read unreached, got %s", j.Phases[1].Status)
	}
}

// TestWorkflowLabelParts is the D59 pair-grammar parity table.
func TestWorkflowLabelParts(t *testing.T) {
	cases := []struct {
		in         string
		kind, rest string
		pair       bool
	}{
		{"design:encryption", "design", "encryption", true},
		{"verify:encryption:leak", "verify", "encryption:leak", true},
		{"survey:rail-chrome-inventory", "survey", "rail-chrome-inventory", true},
		{"strategist", "", "strategist", false},
		{"NotASlug:x", "", "NotASlug:x", false},
		{"seventeencharhead1:x", "", "seventeencharhead1:x", false}, // 18-char head fails the 1–16 slug
		{":x", "", ":x", false},                                     // empty head is not a slug
	}
	for _, c := range cases {
		kind, rest, pair := workflowLabelParts(c.in)
		if kind != c.kind || rest != c.rest || pair != c.pair {
			t.Fatalf("workflowLabelParts(%q) = (%q,%q,%v), want (%q,%q,%v)",
				c.in, kind, rest, pair, c.kind, c.rest, c.pair)
		}
	}
}

// TestModelFamily is the D59 prefix-map parity table — raw wire ids (with the
// [1m] suffix), the short picker slugs, and the honest raw passthrough.
func TestModelFamily(t *testing.T) {
	cases := map[string]string{
		"claude-fable-5":      "Fable",
		"claude-opus-4-8[1m]": "Opus",
		"claude-sonnet-4-6":   "Sonnet",
		"claude-haiku-4":      "Haiku",
		"sonnet":              "Sonnet",
		"fable":               "Fable",
		"gpt-5":               "gpt-5",
		"":                    "",
	}
	for in, want := range cases {
		if got := modelFamily(in); got != want {
			t.Fatalf("modelFamily(%q) = %q, want %q", in, got, want)
		}
	}
}

// TestFormatTokensParity pins formatTokens to StudioChat.format_tokens: the
// <1M branch ROUNDS (145.5k → 146k) like Elixir's round/1 — the old truncation
// drifted low against Studio's rendering of the same figure.
func TestFormatTokensParity(t *testing.T) {
	cases := map[int]string{
		845:     "845",
		1500:    "1.5k",
		9600:    "9.6k",
		68272:   "68k",
		145500:  "146k",
		1240000: "1.2M",
		2137873: "2.1M",
		-1:      "—",
	}
	for in, want := range cases {
		if got := formatTokens(in); got != want {
			t.Fatalf("formatTokens(%d) = %q, want %q", in, got, want)
		}
	}
}

// TestFormatElapsed pins the compact duration vocabulary.
func TestFormatElapsed(t *testing.T) {
	cases := map[time.Duration]string{
		42 * time.Second:                "42s",
		3*time.Minute + 12*time.Second:  "3m12s",
		time.Hour + 4*time.Minute:       "1h04m",
		-5 * time.Second:                "0s",
		59*time.Minute + 59*time.Second: "59m59s",
	}
	for in, want := range cases {
		if got := formatElapsed(in); got != want {
			t.Fatalf("formatElapsed(%v) = %q, want %q", in, got, want)
		}
	}
}
