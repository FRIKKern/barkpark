package chat

import (
	"errors"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"

	"github.com/FRIKKern/barkpark/internal/taskboard"
)

// agentjoin_test.go — the TERMINAL arms of task wsc-bl-agent-task-join. The
// join RULE's own arms live in internal/taskboard/agentjoin_test.go; these
// assert the surface: that a resolved join reaches the pane with the pulse, the
// criteria meter and the deep link, that every degrade paints NOTHING, and that
// the candidate rows are fetched once, lazily, on the drill.

var joinNow = time.Date(2026, 9, 17, 4, 0, 0, 0, time.UTC)

// joinAgent is a builder agent labelled the way bp-epic-cycle emits
// (`build:<slug>`), carrying enough detail signal to open the pane at all.
func joinAgent(label string) WorkflowNode {
	return WorkflowNode{
		Type: "workflow_agent", PhaseIndex: 1, Label: label, State: "start",
		Model: "opus", PromptPreview: strPtr("build the slice"),
	}
}

// renderJoinPane paints one agent's detail pane with a live join lookup.
func renderJoinPane(a WorkflowNode, tasks []taskboard.Task) string {
	wf := &Workflow{Status: "running", Nodes: []WorkflowNode{
		{Type: "workflow_phase", Index: 1, Title: "Build"}, a,
	}}
	m := Model{joinTasks: tasks, joinIndex: taskboard.NewAgentTaskIndex(tasks)}
	lines := renderWorkflowAgentDetail(80, journeyOf(wf), joinNow, 0, 0, true, m.agentTaskJoin)
	return ansi.Strip(strings.Join(lines, "\n"))
}

// ── ARM 1 (RED when the join is reverted) ─────────────────────────────────
// The joined row's pulse now-line, its sealed-criteria count, and the Studio
// deep link must all reach the pane. Every asserted substring is a FIGURE off
// the task row, so the arm cannot pass on a pane that merely says "task".
func TestAgentDetailPaintsTheJoinedTaskLine(t *testing.T) {
	task := taskboard.Task{
		DocID: "wsc-bl-agent-task-join", Title: "Intermingle the agent row",
		Criteria: &taskboard.Criteria{Met: 2, Total: 4},
		Claim: &taskboard.Claim{Worker: "cli-r20c-w19", Now: &taskboard.ClaimPulse{
			Text: "wiring the pane", At: joinNow.Add(-3 * time.Minute),
		}},
	}
	pane := renderJoinPane(joinAgent("build:intermingle-the-agent-row"), []taskboard.Task{task})
	for _, want := range []string{
		"task ",
		"wsc-bl-agent-task-join",
		"2/4 criteria",
		"wiring the pane",
		"(3m)",
		"/admin/projects?task=wsc-bl-agent-task-join",
	} {
		if !strings.Contains(pane, want) {
			t.Errorf("pane is missing %q:\n%s", want, pane)
		}
	}
	// The wild-bulk two-segment grammar must reach the same row through the
	// same pane — the label grammars differ, the reading does not.
	pane2 := renderJoinPane(joinAgent("build:cli:intermingle-the-agent-row"), []taskboard.Task{task})
	if !strings.Contains(pane2, "/admin/projects?task=wsc-bl-agent-task-join") {
		t.Errorf("the two-segment label did not reach the task line:\n%s", pane2)
	}
}

// ── ARM 2 (QUIET when it should be) ───────────────────────────────────────
// Every degrade paints NOTHING: no rows fetched, a label naming no task, an
// ambiguous label, a non-slug label. The pane must not grow a placeholder, an
// error, or a "task unknown" row — and it must still paint its own detail.
func TestAgentDetailPaintsNoTaskLineWhenTheJoinDegrades(t *testing.T) {
	rows := []taskboard.Task{
		{DocID: "t-1", Title: "Intermingle the agent row"},
		{DocID: "c-1", Title: "Historical smoke record cmux smoke t2 1700"},
		{DocID: "c-2", Title: "Historical smoke record cmux smoke t2 1701"},
	}
	cases := []struct {
		name  string
		label string
		tasks []taskboard.Task
	}{
		{"rows never fetched", "build:intermingle-the-agent-row", nil},
		{"no such task", "build:nothing-named-this-at-all", rows},
		{"ambiguous key", "build:historical-smoke-record-cmux-smoke-t2-17", rows},
		{"free prose label", "Digest the survey", rows},
		{"bare role label", "verify", rows},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			pane := renderJoinPane(joinAgent(tc.label), tc.tasks)
			if strings.Contains(pane, "/admin/projects?task=") {
				t.Errorf("a degraded join painted a deep link:\n%s", pane)
			}
			for _, forbidden := range []string{"task ", "criteria", "unknown", "not found", "error"} {
				if strings.Contains(pane, forbidden) {
					t.Errorf("a degraded join painted %q:\n%s", forbidden, pane)
				}
			}
			// The pane itself must still render — a degraded join hides the task
			// line, never the agent.
			if !strings.Contains(pane, "build the slice") {
				t.Errorf("the agent's own detail vanished with the task line:\n%s", pane)
			}
		})
	}
}

// Every rendered line must fit the pane at every supported width. The deep
// link is a single unbreakable token, so a pane narrower than the link is the
// one case a wrap cannot save — it drops the link and keeps the doc id rather
// than overrunning the frame or handing over a cut URL. This arm reds on a
// blowout AND on a link that is silently truncated into an unusable one.
func TestTaskLineIsWidthSafeAtEveryPaneWidth(t *testing.T) {
	task := taskboard.Task{
		DocID: "wsc-bl-agent-task-join", Title: "Intermingle the agent row",
		Criteria: &taskboard.Criteria{Met: 2, Total: 4},
		Claim: &taskboard.Claim{Worker: "w", Now: &taskboard.ClaimPulse{
			Text: "a deliberately long now-line that will not fit on one terminal row at all",
			At:   joinNow.Add(-3 * time.Minute),
		}},
	}
	rows := []taskboard.Task{task}
	m := Model{joinTasks: rows, joinIndex: taskboard.NewAgentTaskIndex(rows)}
	wf := &Workflow{Status: "running", Nodes: []WorkflowNode{
		{Type: "workflow_phase", Index: 1, Title: "Build"},
		joinAgent("build:intermingle-the-agent-row"),
	}}
	const link = "/admin/projects?task=wsc-bl-agent-task-join"
	for _, w := range []int{40, 56, 60, 72, 80, 100} {
		lines := renderWorkflowAgentDetail(w, journeyOf(wf), joinNow, 0, 0, true, m.agentTaskJoin)
		joined := ansi.Strip(strings.Join(lines, "\n"))
		for i, ln := range lines {
			plain := ansi.Strip(ln)
			if got := lipgloss.Width(plain); got > w {
				t.Errorf("width %d: line %d is %d cols: %q", w, i, got, plain)
			}
		}
		// The doc id is never dropped — it is the handle that survives every width.
		if !strings.Contains(joined, "wsc-bl-agent-task-join") {
			t.Errorf("width %d: the doc id vanished:\n%s", w, joined)
		}
		if w >= 56 && !strings.Contains(joined, link) {
			t.Errorf("width %d: the deep link was dropped even though it fits:\n%s", w, joined)
		}
		// A PARTIAL link is worse than none: it reads as a URL and is not one.
		if i := strings.Index(joined, "/admin/projects?task="); i >= 0 && !strings.Contains(joined, link) {
			t.Errorf("width %d: the deep link was truncated into an unusable one:\n%s", w, joined)
		}
	}
}

// ── ARM 3 (what ARM 2 discriminates) ──────────────────────────────────────
// ARM 2 alone passes on a pane that can NEVER paint a task line — it only ever
// asserts absence. This is its control: the SAME ambiguous key, with the
// collision removed, must now paint. Mutating the pane to drop the task line
// entirely reds this and ARM 1 while ARM 2 stays green; mutating the join to
// pick the first of an ambiguous pair reds ARM 2 while this stays green.
// Neither test on its own separates those two failures.
func TestAgentDetailStillPaintsOnceTheCollisionIsGone(t *testing.T) {
	rows := []taskboard.Task{
		{DocID: "c-1", Title: "Historical smoke record cmux smoke t2 1700"},
		{DocID: "other", Title: "A completely different piece of work"},
	}
	pane := renderJoinPane(joinAgent("build:historical-smoke-record-cmux-smoke-t2-17"), rows)
	if !strings.Contains(pane, "/admin/projects?task=c-1") {
		t.Errorf("the unambiguous form of the colliding key painted no task line:\n%s", pane)
	}
}

// The candidate rows are fetched ONCE, LAZILY, on the first drill into an
// agent's detail — not on launch, not per paint. A chat that never drills must
// make zero task calls.
func TestJoinTasksFetchedOnceOnTheFirstDrill(t *testing.T) {
	f := &fakeTransport{joinTasks: []taskboard.Task{{DocID: "t-1", Title: "Intermingle the agent row"}}}
	m := newTestModel(f)
	if f.joinTaskCalls != 0 {
		t.Fatalf("a fresh model already fetched join tasks (%d calls)", f.joinTaskCalls)
	}
	// Drill: focus the workflow, expand it, then Enter into the agent detail.
	m.st.Workflow = &Workflow{Status: "running", Nodes: []WorkflowNode{
		{Type: "workflow_phase", Index: 1, Title: "Build"},
		joinAgent("build:intermingle-the-agent-row"),
	}}
	m.focus, m.wfExpanded, m.wfPhase = focusWorkflow, true, 0
	mm, cmd, _ := m.handleWorkflowKey(tea.KeyMsg{Type: tea.KeyEnter})
	m = mm.(Model)
	if !m.wfAgentDetail {
		t.Fatal("Enter did not open the agent-detail level")
	}
	if cmd == nil {
		t.Fatal("the first drill issued no join fetch")
	}
	msg := cmd()
	if f.joinTaskCalls != 1 {
		t.Fatalf("join tasks fetched %d times on the first drill, want 1", f.joinTaskCalls)
	}
	mm, _ = m.Update(msg)
	m = mm.(Model)
	if len(m.joinTasks) != 1 {
		t.Fatalf("the fetched rows did not reach the model: %d", len(m.joinTasks))
	}
	// Re-drilling must NOT refetch.
	m.wfAgentDetail = false
	mm, cmd2, _ := m.handleWorkflowKey(tea.KeyMsg{Type: tea.KeyEnter})
	m = mm.(Model)
	if cmd2 != nil {
		cmd2()
	}
	if f.joinTaskCalls != 1 {
		t.Fatalf("a second drill refetched (%d calls) — the one-shot guard is gone", f.joinTaskCalls)
	}
}

// A failed fetch is not an error STATE: joinTasks stays empty, the pane paints
// no task line, and nothing about the client leaks into the agent's reading.
func TestJoinTasksFetchErrorDegradesToNoTaskLine(t *testing.T) {
	f := &fakeTransport{joinTasksErr: errors.New("boom")}
	m := newTestModel(f)
	mm, _ := m.Update(joinTasksMsg{err: f.joinTasksErr})
	m = mm.(Model)
	if len(m.joinTasks) != 0 {
		t.Fatalf("a failed fetch seeded rows: %d", len(m.joinTasks))
	}
	if _, ok := m.agentTaskJoin("build:anything-at-all"); ok {
		t.Fatal("a failed fetch still resolved a join")
	}
	pane := renderJoinPane(joinAgent("build:intermingle-the-agent-row"), m.joinTasks)
	if strings.Contains(pane, "boom") || strings.Contains(pane, "/admin/projects?task=") {
		t.Errorf("a failed fetch leaked into the pane:\n%s", pane)
	}
}
