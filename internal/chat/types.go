package chat

import (
	"encoding/json"
	"sort"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// Wire types for the /v1/chat contract are OWNED by internal/apiclient — the ONE
// shared chat client (charter D26 / ct-bl-tui-apiclient-dedup). The chat package
// consumes them by ALIAS so the reducer, the shell, and render.go keep their
// short local names (Session/SessionSummary/Message) while there is exactly ONE
// set of wire structs and ONE SSE decoder in the tree — no fork, no second
// projection to drift.
//
// The apiclient structs are a 3-way merge against the live server projection
// (chat_controller full_session_json / sidebar_json / message_json): the fork's
// render-bearing shape (Message.Metadata; the summary counters
// MessageCount/PendingApprovals/LastActiveAt) is preserved, rail_snapshot + the
// flat usage metrics are added, and the fields the server never emits are
// dropped. See internal/apiclient/chat.go for the per-field wire docs — and for
// the card answer-path accessors (RequestID/ApprovalStatus/Resolved) that ride
// on ChatMessage now that Message is that wire type by alias.
type (
	// Session is the FULL GET /v1/chat/sessions/:id struct — the D14 continuity
	// set + message tail + rail_snapshot + usage metrics.
	Session = apiclient.ChatSession
	// SessionSummary is the sidebar row (GET /v1/chat/sessions): NO
	// draft/rail/choices (the D14 vacuous-green trap), so resume must re-GET.
	SessionSummary = apiclient.ChatSessionSummary
	// Message is one persisted transcript row; assistant rows carry `blocks`.
	Message = apiclient.ChatMessage
	// SessionWorkflow is the compact pre-folded epic-cycle summary the list wire
	// carries per workflow row (wsc D3/D10/D12) — the session card's two lines,
	// decoded straight off the summary. NOT rail_snapshot (the list never carries
	// that, D14): no Go fold, no decodeRail on the list path.
	SessionWorkflow = apiclient.ChatWorkflowSummary
	// EpicGoal is the second card line's task-spine truth (wsc D9): epic title +
	// slices closed/total. Absent "PRs open" is deliberate (D8: no data source).
	EpicGoal = apiclient.ChatEpicGoal
	// Attachment is ONE chat attachment reference (ct-bl-chat-attachments): the
	// same {id, media_type, byte_size, url} shape Studio projects onto a
	// transcript row and the upload/read routes answer with. By ALIAS, like every
	// other wire type here — a second Go struct for this shape is exactly the
	// per-surface fork the "one reference shape" requirement rules out.
	Attachment = apiclient.ChatAttachment
)

// isCard reports whether this row is one of the three interactive card roles.
// The card-role SET is single-sourced in render.go's cardRoles map (the same map
// that carries each card's display title), so "what is a card" has one owner.
func isCard(m Message) bool { _, ok := cardRoles[m.Role]; return ok }

// answerable is true for a card row still awaiting a decision (pending + a
// request_id to answer). A resolved card, or a malformed one with no request_id,
// is not answerable — the answer keys skip it.
func answerable(m Message) bool {
	return isCard(m) && m.ApprovalStatus() == "pending" && m.RequestID() != ""
}

// RailEntry is one decoded row of the agents rail (charter D47), keyed by
// task_id. It mirrors the fields Studio's rail_entry renders from the SAME
// rail_snapshot map: a status glyph, a label (the sub-agent's description /
// task_type), and its token usage. The rich workflow-journey (phases) is
// deliberately NOT decoded here — the header line is the honest MVP the terminal
// rail band shows; the phase tree stays a Studio-only richness this wave. This
// is the render projection of the rail; apiclient.ChatRailEntry is the raw wire
// shape — decodeRail is the terminal-render decode.
type RailEntry struct {
	TaskID    string
	Status    string // "running" | "completed" | "interrupted"
	Label     string // row.description || row.task_type || "agent"
	Tokens    int    // usage.total_tokens
	HasTokens bool
}

// decodeRail turns the rail_snapshot map (task_id => entry) into a task-id-sorted
// slice — stable order so a resumed session's rail reads identically every paint.
// Malformed entries are skipped (forward-compatible, same tolerance as the rest
// of the decoder); an empty/absent snapshot yields nil (no rail band). It
// projects from decodeRailWire (workflow.go) — the ONE parsing of the rail wire
// shape, shared with the below-composer workflow panel's decodeWorkflow.
func decodeRail(raw json.RawMessage) []RailEntry {
	m := decodeRailWire(raw)
	if len(m) == 0 {
		return nil
	}
	entries := make([]RailEntry, 0, len(m))
	for tid, e := range m {
		label := e.Row.Description
		if label == "" {
			label = e.Row.TaskType
		}
		if label == "" {
			label = "agent"
		}
		re := RailEntry{TaskID: tid, Status: e.Status, Label: label}
		if e.Usage.TotalTokens != nil {
			re.Tokens, re.HasTokens = *e.Usage.TotalTokens, true
		}
		entries = append(entries, re)
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].TaskID < entries[j].TaskID })
	return entries
}
