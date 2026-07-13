package chat

import "github.com/FRIKKern/barkpark/internal/apiclient"

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
// dropped. See internal/apiclient/chat.go for the per-field wire docs.
type (
	// Session is the FULL GET /v1/chat/sessions/:id struct — the D14 continuity
	// set + message tail + rail_snapshot + usage metrics.
	Session = apiclient.ChatSession
	// SessionSummary is the sidebar row (GET /v1/chat/sessions): NO
	// draft/rail/choices (the D14 vacuous-green trap), so resume must re-GET.
	SessionSummary = apiclient.ChatSessionSummary
	// Message is one persisted transcript row; assistant rows carry `blocks`.
	Message = apiclient.ChatMessage
)
