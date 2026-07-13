package chat

import "encoding/json"

// Wire types for the /v1/chat contract (charter §Wire contract v1). Field
// names mirror the server's chat_sessions/chat_messages JSON verbatim so the
// decoder is a straight unmarshal — no projection layer (charter D8).

// SessionSummary is one row of GET /v1/chat/sessions — the sidebar shape
// (`list_sessions/1`). It deliberately OMITS draft/model_choice/effort_choice:
// only the full GET carries those (charter D14's documented vacuous-green
// trap), so resume must always re-GET the session.
type SessionSummary struct {
	ID               string `json:"id"`
	Title            string `json:"title"`
	Status           string `json:"status"`
	MessageCount     int    `json:"message_count"`
	PendingApprovals int    `json:"pending_approvals"`
	LastActiveAt     string `json:"last_active_at"`
	Summary          string `json:"summary"`
}

// Session is the FULL session struct from GET /v1/chat/sessions/:id —
// including the D14 continuity set (draft, mode, model_choice, effort_choice)
// and the message rows seq-asc.
type Session struct {
	ID           string    `json:"id"`
	Title        string    `json:"title"`
	Draft        string    `json:"draft"`
	Mode         string    `json:"mode"`
	Model        string    `json:"model"`
	ModelChoice  string    `json:"model_choice"`
	EffortChoice string    `json:"effort_choice"`
	Status       string    `json:"status"`
	Cwd          string    `json:"cwd"`
	Messages     []Message `json:"messages"`
}

// Message is one persisted chat_messages row. Assistant rows additionally
// carry `blocks` — the server-computed PortableDoc block array
// (FromMarkdown.blocks/1, charter D8) — alongside the raw source_markdown.
// Role is a free string: user/assistant plus the structural rows the Recorder
// persists (tool, todo, thinking, approval, question, plan, system).
type Message struct {
	Seq            int             `json:"seq"`
	Role           string          `json:"role"`
	SourceMarkdown string          `json:"source_markdown"`
	Blocks         json.RawMessage `json:"blocks"`
	Metadata       map[string]any  `json:"metadata"`
}

// sessionsEnvelope is the GET /v1/chat/sessions response body.
type sessionsEnvelope struct {
	Sessions []SessionSummary `json:"sessions"`
}
