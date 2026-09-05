package chat

import (
	"encoding/json"
	"regexp"
	"sort"
	"strings"
	"time"
)

// workflow.go — the Go port of Studio's workflow-journey truth table (wave
// session-card charter D13). The below-composer workflow panel renders the SAME
// rail_snapshot truth Studio's agents rail renders, so every grouping rule here
// is a 1:1 port of `Barkpark.StudioChat` (api/lib/barkpark/studio_chat.ex):
//
//   - the terminal?/failed? state SETS (studio_chat.ex @workflow_node_terminal /
//     @workflow_node_failed, charter D58) — states are NEVER enumerated in logic
//     ("progress" exists on the wire beyond "start"; the sets are the one owner);
//   - workflow_journey/1 — phases grouped by phaseIndex, the frontier (highest
//     phase WITH agents), and the six-state phase truth table;
//   - workflow_label_parts/1 — the first-colon pair grammar;
//   - model_family/1 — the wire-id prefix map;
//   - format_tokens parity lives in render.go's formatTokens (shared with the
//     rail band).
//
// Freshness is turn-boundary only (charter D13): the workflow decodes from the
// full-session GET's rail_snapshot at every FetchTailEffect — no new SSE frame,
// no polling; mid-turn the panel honestly lags until the next refetch. Elapsed
// and tokens render ONLY from wire-carried figures (charter D15): durationMs /
// startedAt / entry end_time / node tokens — absent figures are OMITTED, never
// synthesized.

// workflowNodeTerminalStates is the terminal-state SUPERSET (studio_chat.ex
// @workflow_node_terminal, charter D58): done/completed are SUCCESS terminals;
// the failure set below are FAILURE terminals. Everything else (start,
// progress, absent) is live.
var workflowNodeTerminalStates = map[string]bool{
	"done": true, "completed": true, "failed": true, "error": true,
	"canceled": true, "cancelled": true, "aborted": true,
}

// workflowNodeFailedStates is the FAILURE-terminal set (studio_chat.ex
// @workflow_node_failed): terminal but never a success — an "error" agent
// renders ✕ and is never counted done.
var workflowNodeFailedStates = map[string]bool{
	"failed": true, "error": true, "canceled": true, "cancelled": true, "aborted": true,
}

// workflowStateTerminal mirrors StudioChat.workflow_node_terminal?/1:
// case-insensitive set membership; an absent state reads live.
func workflowStateTerminal(state string) bool {
	return workflowNodeTerminalStates[strings.ToLower(state)]
}

// workflowStateFailed mirrors StudioChat.workflow_node_failed?/1.
func workflowStateFailed(state string) bool {
	return workflowNodeFailedStates[strings.ToLower(state)]
}

// WorkflowNode is one flat node of a rail entry's `workflow` list — the exact
// shape the Recorder persists from a task_progress frame's workflow_progress
// (type workflow_phase carries index/title; type workflow_agent carries
// label/phaseIndex/model/state plus the wire-carried timing/usage figures).
// Timing/usage fields are POINTERS: absent on the wire means absent here, so
// the render can omit honestly instead of painting a fake zero (charter D15).
type WorkflowNode struct {
	Type       string `json:"type"`
	Index      int    `json:"index"`
	Title      string `json:"title"`
	Label      string `json:"label"`
	PhaseIndex int    `json:"phaseIndex"`
	Model      string `json:"model"`
	State      string `json:"state"`
	StartedAt  *int64 `json:"startedAt"`  // epoch ms
	DurationMs *int64 `json:"durationMs"` // stamped once terminal
	Tokens     *int   `json:"tokens"`     // settle-on-state figure

	// Agent-detail projection (wave session-card charter D36): the SAME fields
	// StudioChat.workflow_agent_node_detail/1 keeps (@agent_detail_keys), decoded
	// here so the below-composer panel's third focus level reads Go↔Elixir
	// byte-identical truth off the shared workflow_agent_detail.json fixture.
	// Terminal/failed are NEVER a wire bool — they DERIVE from State through
	// workflowStateTerminal/workflowStateFailed (the one truth table), so no
	// Terminal/Failed/AgentId struct field exists to drift from the sets.
	// Previews are POINTERS: absent on the wire stays absent here, so the pane
	// omits honestly instead of painting an empty label (charter D27).
	Attempt         int     `json:"attempt"`         // retry number; chip renders only when >1
	PromptPreview   *string `json:"promptPreview"`   // the brief ('about')
	LastToolName    *string `json:"lastToolName"`    // live NOW line: tool name
	LastToolSummary *string `json:"lastToolSummary"` // live NOW line: one-line summary
	ResultPreview   *string `json:"resultPreview"`   // terminal DONE line (capped at render)
	LastProgressAt  *int64  `json:"lastProgressAt"`  // epoch ms of the last progress tick
}

// agentHasDetail mirrors StudioChat's @agent_detail_signal_keys gate (charter
// D27): a node carries an expandable detail iff it has at least one signal field
// — promptPreview / lastToolName / lastToolSummary / resultPreview / attempt. A
// detail-less node (a background/codex row, a thin mid-persist frame) has NO
// affordance: Enter no-ops on it. This is the structural gate the panel reads
// before it drills, so a row with nothing to show never opens an empty pane.
func agentHasDetail(n WorkflowNode) bool {
	return n.PromptPreview != nil || n.LastToolName != nil ||
		n.LastToolSummary != nil || n.ResultPreview != nil || n.Attempt > 0
}

// Workflow is the open session's workflow-bearing rail entry, decoded from the
// full-session GET (charter D13): the HIGHEST-seq entry carrying a non-empty
// `workflow` list (the D3 pick rule). Label is the entry's row.description
// treated as ONE opaque string (D3 — never em-dash-split).
type Workflow struct {
	TaskID        string
	Status        string // rail entry status: running | completed | interrupted
	Label         string
	EndTime       *int64 // entry-level end_time (charter D5), epoch ms; nil until stamped
	Nodes         []WorkflowNode
	ContractError string // owned rail-envelope drift; telemetry node contents stay passthrough
}

// railWireEntry is the raw wire shape of ONE rail_snapshot cell — the single
// decode target for the snapshot in this package: decodeRail (the flat rail
// band) and decodeWorkflow (the below-composer panel) both project from it, so
// there is exactly one parsing of the rail wire shape (no fork to drift).
type railWireEntry struct {
	Status  string `json:"status"`
	Seq     int    `json:"seq"`
	EndTime *int64 `json:"end_time"`
	Row     struct {
		Description string `json:"description"`
		TaskType    string `json:"task_type"`
	} `json:"row"`
	Usage struct {
		TotalTokens *int `json:"total_tokens"`
	} `json:"usage"`
	Workflow []WorkflowNode `json:"workflow"`

	contractError string
}

// decodeRailWire parses the rail_snapshot map into its wire entries. Malformed
// individual entries are skipped (forward-compatible, the same tolerance
// decodeRail always had); an absent/undecodable snapshot yields nil.
func decodeRailWire(raw json.RawMessage) map[string]railWireEntry {
	if len(raw) == 0 {
		return nil
	}
	var m map[string]json.RawMessage
	if err := json.Unmarshal(raw, &m); err != nil {
		return nil
	}
	out := make(map[string]railWireEntry, len(m))
	for tid, er := range m {
		var e railWireEntry
		if err := json.Unmarshal(er, &e); err != nil {
			continue
		}
		// Barkpark owns the rail ENTRY envelope, while WorkflowNode is Claude Code
		// telemetry forwarded verbatim. A local_workflow entry (or any entry that
		// already carries workflow nodes) must therefore retain our three envelope
		// keys. Without this presence check, a producer rename decodes as zero values
		// and the whole workflow panel silently disappears.
		if e.Row.TaskType == "local_workflow" || len(e.Workflow) > 0 {
			var fields map[string]json.RawMessage
			if err := json.Unmarshal(er, &fields); err == nil {
				missing := make([]string, 0, 3)
				for _, key := range []string{"workflow", "status", "usage"} {
					if _, ok := fields[key]; !ok {
						missing = append(missing, key)
					}
				}
				if len(missing) > 0 {
					e.contractError = "missing " + strings.Join(missing, ", ")
				}
			}
		}
		out[tid] = e
	}
	return out
}

// decodeWorkflow picks the open session's workflow entry per the D3 rule: the
// highest-seq rail entry carrying a non-empty `workflow` list (ties break on
// task_id so the pick is deterministic). nil when no entry qualifies — plain
// chats pay zero.
func decodeWorkflow(raw json.RawMessage) *Workflow {
	entries := decodeRailWire(raw)
	bestID := ""
	var best railWireEntry
	for tid, e := range entries {
		if len(e.Workflow) == 0 && e.contractError == "" {
			continue
		}
		if bestID == "" || e.Seq > best.Seq || (e.Seq == best.Seq && tid > bestID) {
			bestID, best = tid, e
		}
	}
	if bestID == "" {
		return nil
	}
	label := best.Row.Description
	if label == "" {
		label = best.Row.TaskType
	}
	if label == "" {
		label = "workflow"
	}
	return &Workflow{
		TaskID:        bestID,
		Status:        best.Status,
		Label:         label,
		EndTime:       best.EndTime,
		Nodes:         best.Workflow,
		ContractError: best.contractError,
	}
}

// entryLifecycle mirrors studio_chat.ex entry_lifecycle/1: "interrupted" is its
// own dead frontier; any other terminal status means the cycle finished;
// everything else (running) is live.
func entryLifecycle(status string) string {
	if status == "interrupted" {
		return "interrupted"
	}
	if workflowStateTerminal(status) {
		return "completed"
	}
	return "live"
}

// WorkflowPhase is one grouped phase of the journey (workflow_journey/1's phase
// map): its agents, the settled counts, and the six-state status.
type WorkflowPhase struct {
	Index   int
	Title   string
	Status  string // done | active | interrupted | future | skipped | unreached
	Agents  []WorkflowNode
	Running int
	Done    int // SUCCESS terminals only (failed never counts done, D58)
	Failed  int
	Total   int
	Tokens  int
	Model   string // family of the first agent; "" when agentless
}

// Settled is the phase's Claude-Code-style settled counter: done + failed (a
// failure IS settled — counted honestly, per the D3 agents_done rule).
func (p WorkflowPhase) Settled() int { return p.Done + p.Failed }

// WorkflowJourney is the ported workflow_journey/1 projection: the grouped
// phases plus the entry-level summary the strip renders. Every number is
// derived from the persisted nodes — nothing here invents a figure.
type WorkflowJourney struct {
	EntryStatus string // live | interrupted | completed
	Phases      []WorkflowPhase
	PhasesRun   int
	Skipped     int
	Active      int // position in Phases of the active/interrupted phase; -1 none
	AgentsTotal int
	Running     int
	Done        int
	Failed      int
	Tokens      int
	HasTokens   bool   // any node carried a tokens figure (else the strip omits it)
	StartedAt   *int64 // min agent startedAt (epoch ms); nil when no node carries one
}

// Settled is the whole-run settled-agent counter (done + failed) — the "13/17
// agents done" numerator.
func (j WorkflowJourney) Settled() int { return j.Done + j.Failed }

// journeyOf is the ported StudioChat.workflow_journey/1 grouping: phases sorted
// by index, agents grouped by phaseIndex, the frontier = the highest phase WITH
// agents, and the phase truth table keyed on the entry lifecycle. Pure.
func journeyOf(wf *Workflow) WorkflowJourney {
	j := WorkflowJourney{EntryStatus: "live", Active: -1}
	if wf == nil {
		return j
	}
	j.EntryStatus = entryLifecycle(wf.Status)

	var phaseNodes []WorkflowNode
	agentsByPhase := map[int][]WorkflowNode{}
	for _, n := range wf.Nodes {
		switch n.Type {
		case "workflow_phase":
			phaseNodes = append(phaseNodes, n)
		case "workflow_agent":
			agentsByPhase[n.PhaseIndex] = append(agentsByPhase[n.PhaseIndex], n)
		}
	}
	sort.SliceStable(phaseNodes, func(a, b int) bool { return phaseNodes[a].Index < phaseNodes[b].Index })

	// the frontier = highest phase index that actually has agents (-1 if none)
	frontier := -1
	for _, p := range phaseNodes {
		if len(agentsByPhase[p.Index]) > 0 && p.Index > frontier {
			frontier = p.Index
		}
	}

	for _, p := range phaseNodes {
		agents := agentsByPhase[p.Index]
		phase := WorkflowPhase{
			Index:  p.Index,
			Title:  p.Title,
			Status: phaseStatus(len(agents) > 0, p.Index, frontier, j.EntryStatus),
			Agents: agents,
			Total:  len(agents),
		}
		for _, a := range agents {
			switch {
			case workflowStateFailed(a.State):
				phase.Failed++
			case workflowStateTerminal(a.State):
				phase.Done++
			default:
				phase.Running++
			}
			if a.Tokens != nil {
				phase.Tokens += *a.Tokens
				j.HasTokens = true
			}
			if a.StartedAt != nil && (j.StartedAt == nil || *a.StartedAt < *j.StartedAt) {
				v := *a.StartedAt
				j.StartedAt = &v
			}
		}
		if len(agents) > 0 {
			phase.Model = modelFamily(agents[0].Model)
		}
		switch phase.Status {
		case "done":
			j.PhasesRun++
		case "skipped":
			j.Skipped++
		case "active", "interrupted":
			j.Active = len(j.Phases)
		}
		j.AgentsTotal += phase.Total
		j.Running += phase.Running
		j.Done += phase.Done
		j.Failed += phase.Failed
		j.Tokens += phase.Tokens
		j.Phases = append(j.Phases, phase)
	}
	return j
}

// visibleAgents is the pin-running projection the agents pane paints (wave
// session-card charter D44, amending D35): every RUNNING agent is pinned (wire
// order), settled agents backfill up to workflowDetailMaxAgents, and the pick
// is re-sorted to wire order so the pane reads like the wire. It returns the
// visible nodes, the index map (visible position → position in p.Agents — the
// ONE translation every consumer shares, so the painted row list, the cursor
// clamp and the detail pane can never address different agents), and the count
// of SETTLED agents folded behind the overflow row. When running agents alone
// exceed the cap, the first cap running agents (wire order) are pinned and the
// hidden-running rest is the render's "(M running)" suffix — the returned
// overflow still counts settled only.
func visibleAgents(p WorkflowPhase) ([]WorkflowNode, []int, int) {
	agents := p.Agents
	if len(agents) <= workflowDetailMaxAgents {
		idx := make([]int, len(agents))
		for i := range idx {
			idx[i] = i
		}
		return agents, idx, 0
	}
	var running, settled []int
	for i, a := range agents {
		if workflowStateTerminal(a.State) {
			settled = append(settled, i)
		} else {
			running = append(running, i)
		}
	}
	pick := running
	if len(pick) > workflowDetailMaxAgents {
		pick = pick[:workflowDetailMaxAgents] // wire-order prefix of the running set
	} else if fill := workflowDetailMaxAgents - len(pick); fill > 0 {
		if fill > len(settled) {
			fill = len(settled)
		}
		pick = append(append([]int(nil), pick...), settled[:fill]...)
		sort.Ints(pick) // back to wire order
	}
	visible := make([]WorkflowNode, len(pick))
	settledShown := 0
	for i, ix := range pick {
		visible[i] = agents[ix]
		if workflowStateTerminal(agents[ix].State) {
			settledShown++
		}
	}
	return visible, pick, len(settled) - settledShown
}

// phaseStatus is the ported phase_status/4 truth table (charter D58): an
// agentless phase reads the entry's fate; a phase with agents reads the
// frontier + lifecycle. Exactly one phase is active/interrupted at a time
// (phases are strictly sequential).
func phaseStatus(hasAgents bool, idx, frontier int, lifecycle string) string {
	if !hasAgents {
		switch lifecycle {
		case "interrupted":
			return "unreached"
		case "completed":
			return "skipped"
		default:
			return "future"
		}
	}
	switch lifecycle {
	case "interrupted":
		if idx == frontier {
			return "interrupted"
		}
		return "done"
	case "live":
		if idx == frontier {
			return "active"
		}
		return "done"
	default: // completed
		return "done"
	}
}

// workflowLabelKindRe is the pair-grammar head test (workflow_label_parts/1,
// charter D59): a short slug head before the FIRST colon.
var workflowLabelKindRe = regexp.MustCompile(`^[a-z0-9_-]{1,16}$`)

// workflowLabelParts is the ported StudioChat.workflow_label_parts/1: split at
// the first colon iff the head is a short slug — "verify:encryption:leak" →
// ("verify", "encryption:leak", true); a bare role or a non-slug head returns
// (_, label, false) — render raw, never invent.
func workflowLabelParts(label string) (kind, rest string, pair bool) {
	if i := strings.IndexByte(label, ':'); i >= 0 && workflowLabelKindRe.MatchString(label[:i]) {
		return label[:i], label[i+1:], true
	}
	return "", label, false
}

// modelFamily is the ported StudioChat.model_family/1 prefix map: rail nodes
// carry raw wire ids ("claude-opus-4-8[1m]") and the short picker slugs both;
// anything unknown returns raw (an honest passthrough, never a guess).
func modelFamily(id string) string {
	if id == "" {
		return ""
	}
	down := strings.ToLower(id)
	switch {
	case strings.HasPrefix(down, "claude-fable") || down == "fable":
		return "Fable"
	case strings.HasPrefix(down, "claude-opus") || down == "opus":
		return "Opus"
	case strings.HasPrefix(down, "claude-sonnet") || down == "sonnet":
		return "Sonnet"
	case strings.HasPrefix(down, "claude-haiku") || down == "haiku":
		return "Haiku"
	}
	return id
}

// workflowElapsed is the whole-run elapsed per charter D5/D15: live = now −
// min(startedAt); terminal = end_time − min(startedAt). false when either
// figure is absent from the wire — the strip omits it, never synthesizes.
func workflowElapsed(wf *Workflow, j WorkflowJourney, now time.Time) (time.Duration, bool) {
	if wf == nil || j.StartedAt == nil {
		return 0, false
	}
	start := time.UnixMilli(*j.StartedAt)
	if j.EntryStatus == "live" {
		return now.Sub(start), true
	}
	if wf.EndTime != nil {
		return time.UnixMilli(*wf.EndTime).Sub(start), true
	}
	return 0, false
}

// agentElapsed is the per-agent elapsed per charter D15: durationMs once the
// node is terminal; now − startedAt while the ENTRY is live; otherwise omitted
// — a dead entry's mid-flight agent has no honest duration (it never settled),
// so an interrupted run renders interrupted instead of a growing fake clock.
func agentElapsed(n WorkflowNode, entryStatus string, now time.Time) (time.Duration, bool) {
	if workflowStateTerminal(n.State) {
		if n.DurationMs != nil {
			return time.Duration(*n.DurationMs) * time.Millisecond, true
		}
		return 0, false
	}
	if entryStatus == "live" && n.StartedAt != nil {
		return now.Sub(time.UnixMilli(*n.StartedAt)), true
	}
	return 0, false
}
