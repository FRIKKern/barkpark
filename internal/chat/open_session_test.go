package chat

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"

	"github.com/FRIKKern/barkpark/internal/taskboard"
)

// open_session_test.go — wsc-steer-open-session-managed, criterion 3: the TUI's
// agent detail offers "enter open session" for exactly the agents whose joined
// task has a managed-Codex session, opens that session on Enter, and paints no
// control at all for any other agent (no disabled or decorative row).

const managedSID = "6f1c2a9e-0b7d-4c3e-9a51-2d8e4b7f0c11"

func openSessionFixture() (*fakeTransport, Model) {
	f := &fakeTransport{
		joinTasks: []taskboard.Task{
			{DocID: "t-managed", Title: "Managed codex slice"},
			{DocID: "t-claude", Title: "Claude lane slice"},
		},
		managedSessions: map[string]string{"t-managed": managedSID},
	}
	m := newTestModel(f)
	m.screen = screenChat
	m.width, m.height = 100, 40
	m.st.Workflow = &Workflow{Status: "running", Nodes: []WorkflowNode{
		{Type: "workflow_phase", Index: 1, Title: "Build"},
		joinAgent("build:managed-codex-slice"),
		joinAgent("build:claude-lane-slice"),
	}}
	m.focus, m.wfExpanded, m.wfPhase = focusWorkflow, true, 0
	return f, m
}

// drain runs a command tree to quiescence, feeding every message back through
// Update, the way the Bubble Tea runtime would.
func drain(t *testing.T, m Model, cmd tea.Cmd) Model {
	t.Helper()
	queue := []tea.Cmd{cmd}
	for i := 0; len(queue) > 0 && i < 50; i++ {
		c := queue[0]
		queue = queue[1:]
		if c == nil {
			continue
		}
		switch msg := c().(type) {
		case nil:
		case tea.BatchMsg:
			queue = append(queue, msg...)
		default:
			mm, next := m.Update(msg)
			m = mm.(Model)
			queue = append(queue, next)
		}
	}
	return m
}

func key(t *testing.T, m Model, k tea.KeyType) (Model, tea.Cmd) {
	t.Helper()
	mm, cmd, handled := m.handleWorkflowKey(tea.KeyMsg{Type: k})
	if !handled {
		t.Fatalf("the workflow panel did not handle %v", k)
	}
	return mm.(Model), cmd
}

func TestManagedAgentDetailOffersAndOpensItsSession(t *testing.T) {
	f, m := openSessionFixture()

	// Drill into the first agent; the join rows load, then the session answer.
	m, cmd := key(t, m, tea.KeyEnter)
	if !m.wfAgentDetail {
		t.Fatal("Enter did not open the agent detail")
	}
	m = drain(t, m, cmd)

	if got := strings.Join(f.managedSessionCalls, ","); got != "t-managed" {
		t.Fatalf("asked ManagedSession for %q, want exactly t-managed", got)
	}
	view := ansi.Strip(m.View())
	for _, want := range []string{"session " + managedSID[:8], "enter opens it", "enter open session"} {
		if !strings.Contains(view, want) {
			t.Errorf("the managed agent's detail lacks %q:\n%s", want, view)
		}
	}

	// Enter inside the detail opens EXACTLY that session (a full GET, D14).
	_, cmd = key(t, m, tea.KeyEnter)
	if cmd == nil {
		t.Fatal("Enter on a managed agent issued no open")
	}
	cmd()
	if len(f.getCalls) != 1 || f.getCalls[0].id != managedSID || f.getCalls[0].since != 0 {
		t.Fatalf("Enter opened %+v, want one full GET of %s", f.getCalls, managedSID)
	}
}

func TestClaudeLaneAgentDetailHasNoSessionControl(t *testing.T) {
	f, m := openSessionFixture()
	m, cmd := key(t, m, tea.KeyEnter)
	m = drain(t, m, cmd)

	// Move to the Claude-lane agent: its task is asked about once, answered no.
	m, cmd = key(t, m, tea.KeyDown)
	m = drain(t, m, cmd)
	if got := strings.Join(f.managedSessionCalls, ","); got != "t-managed,t-claude" {
		t.Fatalf("asked ManagedSession for %q, want t-managed,t-claude", got)
	}

	view := ansi.Strip(m.View())
	for _, unwanted := range []string{"enter opens it", "enter open session", managedSID[:8]} {
		if strings.Contains(view, unwanted) {
			t.Errorf("a Claude-lane agent shows %q:\n%s", unwanted, view)
		}
	}
	if !strings.Contains(view, "t-claude") {
		t.Errorf("the control fixture is wrong: the Claude agent's task line is missing:\n%s", view)
	}

	// Enter stays the honest no-op it was: nothing to open.
	if _, cmd = key(t, m, tea.KeyEnter); cmd != nil {
		cmd()
		t.Fatalf("Enter on a Claude-lane agent issued a command (GETs: %+v)", f.getCalls)
	}

	// Moving back and forth never re-asks: each task is asked once.
	m, cmd = key(t, m, tea.KeyUp)
	m = drain(t, m, cmd)
	m, cmd = key(t, m, tea.KeyDown)
	drain(t, m, cmd)
	if len(f.managedSessionCalls) != 2 {
		t.Fatalf("re-asked on cursor moves: %v", f.managedSessionCalls)
	}
}

func TestNoJoinedTaskMeansNoSessionQuestion(t *testing.T) {
	f, m := openSessionFixture()
	f.joinTasks = nil // nothing to join against
	m, cmd := key(t, m, tea.KeyEnter)
	m = drain(t, m, cmd)
	if len(f.managedSessionCalls) != 0 {
		t.Fatalf("asked ManagedSession without a joined task: %v", f.managedSessionCalls)
	}
	if strings.Contains(ansi.Strip(m.View()), "enter open session") {
		t.Error("offered open session with no joined task")
	}
}
