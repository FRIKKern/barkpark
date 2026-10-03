package chat

import (
	"strings"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/FRIKKern/barkpark/internal/taskboard"
)

// agentjoin.go — the terminal HALF of the agent↔task intermingle
// (task wsc-bl-agent-task-join). The join RULE is not here: it lives once, in
// taskboard.JoinAgentTask, so the TUI's agent-detail pane and Studio's Doing
// strip can never drift on which task a builder is advancing. This file is only
// the seam that gets the candidate rows into the chat shell and the projection
// the pane paints.
//
// WHEN IT FETCHES: once, lazily, the first time the operator drills into an
// agent's detail (the third focus level). A chat session that never opens that
// pane pays nothing — no extra call on launch, no poll, no new stream. The
// rows are a SNAPSHOT: a pulse landing after the fetch is not reflected until
// the pane is reopened on a fresh session, which is honest for a reading
// surface whose whole freshness contract is turn-boundary (charter D13).
//
// WHEN IT SHOWS NOTHING: a failed fetch, an un-fetched set, a label that names
// no task, and an ambiguous label all render the SAME way — no task line at
// all. The pane never says "no task found" and never guesses, because a wrong
// task line is worse than no task line: it pins a builder's live evidence to
// somebody else's row.

// joinTasksMsg carries the lazily fetched task rows back into the update loop.
// err is kept but never rendered as an error state — a failed join fetch
// degrades to no task line (see the file docs).
type joinTasksMsg struct {
	tasks []taskboard.Task
	err   error
}

// loadJoinTasksCmd fetches the task rows the agent↔task join resolves against.
// It is fired at most once per process (guarded by joinTasksAsked), off the
// SAME Transport seam every other network touch in this package uses, so the
// shell still drives deterministically under a fake transport.
func loadJoinTasksCmd(tr Transport) tea.Cmd {
	return func() tea.Msg {
		tasks, err := tr.JoinTasks()
		return joinTasksMsg{tasks: tasks, err: err}
	}
}

// maybeLoadJoinTasks returns the fetch command the FIRST time the agent-detail
// level opens, and nil every time after. It marks the ask on the model, so the
// guard is one bool rather than a per-call-site convention.
func (m *Model) maybeLoadJoinTasks() tea.Cmd {
	if m.joinTasksAsked {
		return nil
	}
	m.joinTasksAsked = true
	return loadJoinTasksCmd(m.tr)
}

// agentTaskJoin resolves the selected agent's label to the task it advances,
// against whatever rows this process has fetched. ok is false — meaning paint
// NOTHING — when the rows are not in yet, the fetch failed, the label names no
// task, or the label is ambiguous. There is deliberately no fifth answer.
func (m Model) agentTaskJoin(label string) (taskboard.AgentTaskJoin, bool) {
	if m.joinIndex.Len() == 0 {
		return taskboard.AgentTaskJoin{}, false
	}
	return m.joinIndex.Join(label)
}

// ── open session: the managed-Codex lane (wsc-steer-open-session-managed) ──
//
// Only a CycleFleet MANAGED Codex builder has a real session behind it (steer
// paper §1/§5): its task carries a runtime attempt bound to one chat session. A
// Claude-lane builder is a subagent with no session at all. So the agent detail
// asks the server, per joined task, whether a session exists, and offers
// "enter open session" ONLY on a yes. There is no disabled or decorative
// control for any other agent: a miss paints nothing, exactly like a task line
// that does not join.
//
// WHEN IT ASKS: once per task id, lazily, when the selected agent's task first
// becomes known (the drill, a cursor move inside the detail, or the join rows
// landing). A failed or negative answer is remembered as asked, so a pane the
// operator is reading never turns into a retry loop.

// managedSessionMsg carries one task's answer back into the update loop.
type managedSessionMsg struct {
	taskID    string
	sessionID string
	ok        bool
}

func loadManagedSessionCmd(tr Transport, taskID string) tea.Cmd {
	return func() tea.Msg {
		sid, ok, err := tr.ManagedSession(taskID)
		if err != nil || sid == "" {
			ok = false
		}
		return managedSessionMsg{taskID: taskID, sessionID: sid, ok: ok}
	}
}

// selectedAgentTaskID resolves the agent under the detail cursor to the BARE id
// of the task it advances — through the SAME visibleAgents projection the pane
// paints and the SAME join the task line uses. ok is false whenever the pane
// paints no task line.
func (m Model) selectedAgentTaskID() (string, bool) {
	if !m.wfAgentDetail {
		return "", false
	}
	j := journeyOf(m.st.Workflow)
	if m.wfPhase < 0 || m.wfPhase >= len(j.Phases) {
		return "", false
	}
	visible, indexMap, _ := visibleAgents(j.Phases[m.wfPhase])
	if m.wfAgent < 0 || m.wfAgent >= len(visible) {
		return "", false
	}
	a := j.Phases[m.wfPhase].Agents[indexMap[m.wfAgent]]
	tj, ok := m.agentTaskJoin(a.Label)
	if !ok {
		return "", false
	}
	id := strings.TrimPrefix(tj.Task.DocID, "drafts.")
	return id, id != ""
}

// maybeLoadManagedSession returns the ask for the selected agent's task the
// first time that task is seen, and nil otherwise.
func (m *Model) maybeLoadManagedSession() tea.Cmd {
	id, ok := m.selectedAgentTaskID()
	if !ok || m.managedAsked[id] {
		return nil
	}
	if m.managedAsked == nil {
		m.managedAsked = map[string]bool{}
	}
	m.managedAsked[id] = true
	return loadManagedSessionCmd(m.tr, id)
}

// selectedManagedSession is the session the selected agent's task resolved to,
// when the server said one exists.
func (m Model) selectedManagedSession() (string, bool) {
	id, ok := m.selectedAgentTaskID()
	if !ok {
		return "", false
	}
	sid, ok := m.managedSessions[id]
	return sid, ok && sid != ""
}

// agentSessionLines is the agent-detail row that names the managed session and
// the key that opens it. nil — nothing painted — for every agent without one.
func (m Model) agentSessionLines() []string {
	sid, ok := m.selectedManagedSession()
	if !ok {
		return nil
	}
	short := sid
	if len(short) > 8 {
		short = short[:8]
	}
	return []string{"  " + dimStyle.Render("session") + " " + short + dimStyle.Render(" · enter opens it")}
}
