package chat

import (
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
