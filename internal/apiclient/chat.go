// Package apiclient — chat bindings for the `bp chat` TUI (One Chat, Two
// Surfaces). These are the Go client of the `/v1/chat` transport: session CRUD,
// send/interrupt/approval control verbs, and the SSE events stream. They mirror
// the Studio chat GUI's server calls so the terminal client is a second client
// of the one engine, not a lookalike.
//
// Charter decisions this file implements (`.claude/workflows/bp-chat-tui-charter.md`):
//
//   - D3 — Auth is the DATA-PLANE bearer token (c.token, i.e. cfg.Token set by
//     `bp setup --target connect` / `bp attach`). The control-plane token that
//     `bp login` writes lives in a DIFFERENT config field (CloudToken) that never
//     rides a data-plane Authorization header — and apiclient.Client has no such
//     field, so "never CloudToken" is structurally guaranteed here: the only
//     token this client can send is c.token.
//   - D5 — Resume is by TURN BOUNDARY, not token-level replay. Persisted message
//     rows carry `seq`; live deltas are ephemeral and carry NO id. The caller
//     OWNS the Last-Event-ID cursor (= the max persisted seq it already holds)
//     and hands it to ChatEvents; the stream never inherits a stale internal
//     cursor the way a general listener might.
//   - D8 — Settled assistant messages carry a `blocks` field (server-side
//     FromMarkdown.blocks JSON). This client passes that through UNTYPED as raw
//     JSON (ChatMessage.Blocks) so the TUI feeds it straight to pdrender.Decode
//     with zero projection/shape-mismatch layer.
package apiclient

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// ChatSession is the FULL session struct returned by GET /v1/chat/sessions/:id
// (chat_controller full_session_json). It carries the D14 Law-2 continuity
// round-trip set (draft, rail_snapshot, mode/model_choice/effort_choice) plus
// title/status, the FLAT usage metrics the TUI status rail reads, and the
// message tail. The lighter sidebar shape returned by ListChatSessions is
// ChatSessionSummary — list_sessions deliberately OMITS draft/rail/choices (the
// documented vacuous-green trap, D14), so the two shapes are distinct types on
// purpose: never read continuity state off a summary.
//
// This is the ONE wire struct set for /v1/chat (charter D26 / the dedup slice):
// the TUI aliases these instead of forking its own. The field set is a 3-WAY
// MERGE against the live server projection — the fork's render-bearing shape is
// preserved, rail_snapshot + the flat metrics the server actually emits are
// added, and the keys the server NEVER sends (token_metrics/context_metrics/an
// `archived` bool/`created_at`) are dropped: a wholesale swap would have decoded
// them to nil forever while missing the real ones. Timestamps are `inserted_at`,
// not created_at.
type ChatSession struct {
	ID                string `json:"id"`
	Provider          string `json:"provider,omitempty"`
	ExecutionTarget   string `json:"execution_target,omitempty"`
	ExecutionHostID   string `json:"execution_host_id,omitempty"`
	ProviderSessionID string `json:"provider_session_id,omitempty"`
	Title             string `json:"title,omitempty"`
	Status            string `json:"status,omitempty"`
	Cwd               string `json:"cwd,omitempty"`
	Mode              string `json:"mode,omitempty"`
	Model             string `json:"model,omitempty"`

	// D14 continuity round-trip set (present on GET :id, absent on list).
	// RailSnapshot stays raw JSON so an unknown future rail key never breaks the
	// whole session decode; Rail() is the typed view.
	Draft        string          `json:"draft,omitempty"`
	RailSnapshot json.RawMessage `json:"rail_snapshot,omitempty"`
	ModelChoice  string          `json:"model_choice,omitempty"`
	EffortChoice string          `json:"effort_choice,omitempty"`

	// Denormalised sidebar counters the full struct also carries.
	Summary          string `json:"summary,omitempty"`
	MessageCount     int    `json:"message_count,omitempty"`
	PendingApprovals int    `json:"pending_approvals,omitempty"`

	// FLAT usage metrics — the server emits these TOP-LEVEL (not nested under
	// token_metrics/context_metrics, which it never sends). The TUI status rail
	// reads them directly; an absent key is a harmless zero.
	InputTokens       int     `json:"input_tokens,omitempty"`
	OutputTokens      int     `json:"output_tokens,omitempty"`
	TotalCostUSD      float64 `json:"total_cost_usd,omitempty"`
	ContextWindow     int     `json:"context_window,omitempty"`
	LastContextTokens int     `json:"last_context_tokens,omitempty"`

	LastActiveAt string `json:"last_active_at,omitempty"`
	InsertedAt   string `json:"inserted_at,omitempty"`
	UpdatedAt    string `json:"updated_at,omitempty"`

	// Messages is the seq-ascending transcript tail. On a ?since= refetch it
	// holds only rows newer than the supplied seq.
	Messages []ChatMessage `json:"messages,omitempty"`
}

// ChatMessage is one persisted transcript row (seq-ascending) from
// chat_controller message_json. Assistant rows carry `blocks` — the server-side
// FromMarkdown.blocks JSON — which this client forwards UNTYPED (D8) so the TUI
// hands it straight to pdrender.Decode with no projection layer. SourceMarkdown
// is the same body pre-render (kept for the golden-transcript parity harness);
// Metadata is the raw per-row map the read-only cards read
// (approval/question/plan). There is NO `content` field on the wire — the server
// emits source_markdown only — and the row timestamp is `inserted_at`.
type ChatMessage struct {
	Seq            int             `json:"seq"`
	Role           string          `json:"role"`
	SourceMarkdown string          `json:"source_markdown,omitempty"`
	Blocks         json.RawMessage `json:"blocks,omitempty"`
	Metadata       map[string]any  `json:"metadata,omitempty"`
	InsertedAt     string          `json:"inserted_at,omitempty"`

	// Attachments is the chat-owned attachment REFERENCE list
	// (ct-bl-chat-attachments). It is a sibling of Metadata, not a key inside
	// it, because the server LIFTS it out: the persisted jsonb pointer carries
	// the server's store path and the wire projection drops that, so the only
	// attachment shape a client ever sees is this one — an opaque id, the
	// sniffed media type, the byte size, and the chat-owned read URL. No local
	// path, no bearer token, no bytes.
	Attachments []ChatAttachment `json:"attachments,omitempty"`
}

// ChatAttachment is the ONE attachment shape on the wire — the same JSON Studio
// projects onto a transcript row and the same JSON the upload/read routes
// answer with. Data is populated ONLY by GetChatAttachment (the read route);
// on a transcript row it is empty, because raw bytes never ride a message
// (charter D7/D25).
//
// URL is deliberately RELATIVE and token-free: the caller attaches its own
// Authorization header, so a bearer can never be baked into a stored transcript.
type ChatAttachment struct {
	ID        string `json:"id"`
	MediaType string `json:"media_type,omitempty"`
	ByteSize  int    `json:"byte_size,omitempty"`
	URL       string `json:"url,omitempty"`
	Data      string `json:"data,omitempty"`
}

// Bytes decodes the base64 payload a read returned. It is empty (with no error)
// for a transcript-row reference, which never carries bytes.
func (a ChatAttachment) Bytes() ([]byte, error) {
	if a.Data == "" {
		return nil, nil
	}
	return base64.StdEncoding.DecodeString(a.Data)
}

// metaString reads a string field off the row's raw metadata map — "" when the
// key is absent or non-string. The approval/question/plan rows carry their
// answer state here verbatim from the Recorder (persist_approval_ask): the wire
// keys are request_id, tool_name, input, and approval_status.
func (m ChatMessage) metaString(key string) string {
	if m.Metadata == nil {
		return ""
	}
	if v, ok := m.Metadata[key].(string); ok {
		return v
	}
	return ""
}

// RequestID is the approval ask's request_id — the id the answer POST carries so
// the engine (and the persisted row) resolve the SAME ask (Law-2: one truth).
func (m ChatMessage) RequestID() string { return m.metaString("request_id") }

// ApprovalStatus is the card's lifecycle: "pending" until answered, then the
// server terminal enum "allowed" | "denied" | "canceled"
// (StudioChat.@approval_terminal). A Studio answer flips it via
// update_approval_status/3, so the TUI reads the resolution off the same row.
func (m ChatMessage) ApprovalStatus() string { return m.metaString("approval_status") }

// Resolved is true once a card has reached a terminal decision (allowed/denied/
// canceled) — the render flips from an answer affordance to a resolution badge.
func (m ChatMessage) Resolved() bool {
	switch m.ApprovalStatus() {
	case "allowed", "denied", "canceled":
		return true
	}
	return false
}

// ChatSessionSummary is the sidebar shape from GET /v1/chat/sessions (the
// list_sessions/1 → sidebar_json projection). It intentionally lacks draft, the
// rail, and the model/effort choices — those live only on the full GET :id
// struct (D14). Keeping it a separate type makes "don't trust the list for
// continuity" a compile-time fact. The counters (message_count/pending_approvals)
// and last_active_at are what the picker renders per row.
//
// Workflow is the ONE addition the list wire may carry beyond the continuity
// omission (wsc epic D10/D12): a COMPACT, server-side pre-folded epic-cycle
// summary — NOT rail_snapshot. The list still never carries rail_snapshot (D14,
// enforced at three layers: Ecto select / sidebar_json / this struct), because
// the raw 29-agent rail encodes to 38KB — fails the minimalism contract. Instead
// the server folds StudioChat.workflow_summary/1 to the tiny D3 shape and the TUI
// renders the two session-card lines straight from it: no Go fold, no rail decode
// on the list path. A nil Workflow is a plain session — it renders as it does
// today.
type ChatSessionSummary struct {
	ID               string `json:"id"`
	Provider         string `json:"provider,omitempty"`
	ExecutionTarget  string `json:"execution_target,omitempty"`
	ExecutionHostID  string `json:"execution_host_id,omitempty"`
	Title            string `json:"title,omitempty"`
	Status           string `json:"status,omitempty"`
	Summary          string `json:"summary,omitempty"`
	MessageCount     int    `json:"message_count,omitempty"`
	PendingApprovals int    `json:"pending_approvals,omitempty"`
	LastActiveAt     string `json:"last_active_at,omitempty"`
	InsertedAt       string `json:"inserted_at,omitempty"`
	UpdatedAt        string `json:"updated_at,omitempty"`
	// ArchivedAt is the DISMISSAL stamp (charter D28) — sidebar_json has always
	// emitted it; only this client type discarded it. Its reader is the TUI shelf
	// screen's "shelved <age>" tail. It is NOT the answer to "is this archived":
	// that is answered by WHICH list you asked for (?archived=), the same law the
	// mobile client's shelf follows — a stale row can contradict its own stamp.
	ArchivedAt string `json:"archived_at,omitempty"`

	// AgentState/AgentStateAt are the herd cold-mount fields (herd charter
	// D50h): the four-state autopilot truth (working|blocked|idle|unknown) the
	// wave-5 substrate persists on the session row, plus its flip timestamp —
	// what `bp chat`'s herd home sorts and badges from before the fleet stream
	// delivers its first frame. Additive: an older server that omits them
	// decodes to "" (the herd mounts those rows honestly as unknown).
	AgentState   string `json:"agent_state,omitempty"`
	AgentStateAt string `json:"agent_state_at,omitempty"`
	// TotalCostUSD is the session's cumulative spend — sidebar_json has always
	// emitted it; the herd row is the first Go surface to render it.
	TotalCostUSD float64 `json:"total_cost_usd,omitempty"`

	// Workflow is the compact epic-cycle summary (wsc D10/D12). Present only for
	// a session running/settling a workflow; nil for plain chats.
	Workflow *ChatWorkflowSummary `json:"workflow,omitempty"`
	// Epic is the epic-goal line (wsc D9), a SIBLING of workflow on the wire —
	// present only when the ledger resolves the session's one-hop epic chain.
	Epic *ChatEpicGoal `json:"epic,omitempty"`
}

// ChatWorkflowSummary is the COMPACT, pre-folded epic-cycle workflow summary the
// list wire carries per workflow row (wsc epic D3/D10/D12; the server-side
// StudioChat.workflow_summary/1 projection over the highest-seq workflow rail
// entry). It is DERIVED — never the raw rail_snapshot (38,308 bytes measured for
// a 29-agent rail; the list omits that by design, D10). The TUI decodes this and
// paints the two session-card lines directly; there is deliberately NO Go fold
// and NO decodeRail on the list path. Honesty is wire-carried, never synthesised
// (D15): tokens render only when Tokens > 0, elapsed is omitted on list rows, and
// an interrupted wave carries Terminal=true with Outcome "interrupted".
type ChatWorkflowSummary struct {
	// Label is the workflow's "slug — one-liner" combined string. It is OPAQUE
	// (never split on the em-dash, per the survey's naming correction).
	Label string `json:"label,omitempty"`
	// Ticks are the per-phase journey states in phase order — the D58 truth
	// table's vocabulary: "done" | "active" | "interrupted" | "future" |
	// "skipped" | "unreached". The picker renders one glyph per tick. When
	// absent, the render falls back to PhaseIndex/PhasesTotal
	// (presentation-only, not a rail fold).
	Ticks []string `json:"ticks,omitempty"`
	// Phase/PhaseIndex name the breathing (active/interrupted) phase; both are
	// null on the wire once the cycle settles (PhaseIndex is 1-based).
	Phase       string `json:"phase,omitempty"`
	PhaseIndex  int    `json:"phase_index,omitempty"`
	PhasesTotal int    `json:"phases_total,omitempty"`
	// AgentsDone counts settled agents = done+failed (so 13/17 settles honestly,
	// Claude-Code-style); AgentsTotal is the fleet size.
	AgentsDone  int `json:"agents_done,omitempty"`
	AgentsTotal int `json:"agents_total,omitempty"`
	Running     int `json:"running,omitempty"`
	// Terminal is true once the wave has settled (the wire key is the Elixir
	// atom `terminal?` verbatim); Outcome is the entry lifecycle word:
	// "live" | "completed" | "interrupted".
	Terminal bool   `json:"terminal?,omitempty"`
	Outcome  string `json:"outcome,omitempty"`
	// Tokens is the settle-on-state fleet token total; 0/absent => not rendered.
	Tokens int `json:"tokens,omitempty"`
	// StartedAt/EndedAt are wire-carried epoch-ms figures (min agent startedAt /
	// the entry's stamped end_time); nil on the wire when absent — never
	// synthesised (D15).
	StartedAt *int64 `json:"started_at,omitempty"`
	EndedAt   *int64 `json:"ended_at,omitempty"`
}

// ChatEpicGoal is the epic-goal line's compact projection (wsc D9): the epic
// task id/title, its slices-done/total counter, and the epic's wave_status
// heartbeat. "PRs open" is intentionally ABSENT — it has no data source
// anywhere in the tree (wsc D8: dropped, never synthesised — fabricating it
// would violate the honesty north star).
type ChatEpicGoal struct {
	ID          string `json:"id,omitempty"`
	Title       string `json:"title,omitempty"`
	SlicesDone  int    `json:"slices_done,omitempty"`
	SlicesTotal int    `json:"slices_total,omitempty"`
	WaveStatus  string `json:"wave_status,omitempty"`
}

// ChatRailEntry is one task's cell of the agents-rail snapshot (charter D47):
// rail_snapshot is a task_id-keyed map of these, replayed for free on resume so
// a reopened mid-run session shows what every spawned task was doing (Law 2
// continuity). Fields mirror the server rail entry (studio_chat rail_entry/*):
// the lifecycle status, the optional background origin + description, the seq
// the rail sorts by, and the last-known usage/workflow passed through untyped.
type ChatRailEntry struct {
	Status      string          `json:"status,omitempty"`
	Origin      string          `json:"origin,omitempty"`
	Description string          `json:"description,omitempty"`
	Seq         int             `json:"seq,omitempty"`
	Usage       json.RawMessage `json:"usage,omitempty"`
	Workflow    json.RawMessage `json:"workflow,omitempty"`
}

// Rail decodes the session's rail_snapshot into its task_id-keyed entries. An
// absent/empty/`{}` snapshot yields a nil map and no error (the common idle
// case) — RailSnapshot is left untouched for callers wanting the bytes verbatim.
// This is the ONE typed view of the rail; the transport keeps it as RawMessage
// so an unknown future rail key never breaks the whole session decode.
func (s ChatSession) Rail() (map[string]ChatRailEntry, error) {
	trimmed := bytes.TrimSpace(s.RailSnapshot)
	if len(trimmed) == 0 || string(trimmed) == "{}" || string(trimmed) == "null" {
		return nil, nil
	}
	var rail map[string]ChatRailEntry
	if err := json.Unmarshal(trimmed, &rail); err != nil {
		return nil, fmt.Errorf("decode rail_snapshot: %w", err)
	}
	return rail, nil
}

// ChatSessionPatch is the PATCH body for UpdateChatSession. Every field is a
// pointer so a nil field is omitted from the request while a non-nil field is
// sent even when it points at the empty string — that is how a draft is CLEARED
// (draft:="") versus left untouched (nil). Only draft, mode, model_choice,
// effort_choice, and title are writable per the wire contract.
type ChatSessionPatch struct {
	Draft        *string `json:"draft,omitempty"`
	Mode         *string `json:"mode,omitempty"`
	ModelChoice  *string `json:"model_choice,omitempty"`
	EffortChoice *string `json:"effort_choice,omitempty"`
	Title        *string `json:"title,omitempty"`
}

// chatURL builds an absolute URL under /v1/chat. The chat routes are NOT
// workspace/project-scoped (the wire contract fixes them at bare /v1/chat/…),
// so this deliberately does NOT go through scopedURL.
func (c *Client) chatURL(suffix string) string {
	return strings.TrimRight(c.baseURL, "/") + "/v1/chat" + suffix
}

// chatSend issues a request to a chat endpoint with the data-plane bearer token
// (D3) attached, marshalling payload as JSON when non-nil. It reads the full
// response body and returns it on any of okStatuses; otherwise it maps the
// server's error envelope through humanAPIError (the same one-line-message path
// the rest of the client uses). The caller decodes the returned bytes.
func (c *Client) chatSend(method, endpoint string, payload interface{}, okStatuses ...int) ([]byte, error) {
	var bodyReader io.Reader
	if payload != nil {
		b, err := json.Marshal(payload)
		if err != nil {
			return nil, err
		}
		bodyReader = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, endpoint, bodyReader)
	if err != nil {
		return nil, err
	}
	if payload != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}
	resp, err := c.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	for _, s := range okStatuses {
		if resp.StatusCode == s {
			return respBody, nil
		}
	}
	return nil, humanAPIError(resp.StatusCode, respBody)
}

// CreateChatSession opens a new chat session. mode/model/effort are all
// optional; empty values are omitted so the server applies its own defaults.
// The create body carries ONLY these session-shaping choices — never cwd or any
// launcher/session/token/bypass control (C0): the working directory is the
// server's to decide, not a client-settable launcher knob, so it is not sent
// here even though the returned session may report a read-only Cwd. Returns the
// full session JSON the server mints (201).
func (c *Client) CreateChatSession(mode, model, effort string) (ChatSession, error) {
	return c.CreateChatSessionWithOptions(ChatSessionCreateOptions{Mode: mode, Model: model, Effort: effort})
}

type ChatSessionCreateOptions struct {
	Provider        string `json:"provider,omitempty"`
	ExecutionTarget string `json:"execution_target,omitempty"`
	ExecutionHostID string `json:"execution_host_id,omitempty"`
	Mode            string `json:"mode,omitempty"`
	Model           string `json:"model,omitempty"`
	Effort          string `json:"effort,omitempty"`
}

func (c *Client) CreateChatSessionWithOptions(opts ChatSessionCreateOptions) (ChatSession, error) {
	payload := map[string]string{}
	if opts.Provider != "" {
		payload["provider"] = opts.Provider
	}
	if opts.ExecutionTarget != "" {
		payload["execution_target"] = opts.ExecutionTarget
	}
	if opts.ExecutionHostID != "" {
		payload["execution_host_id"] = opts.ExecutionHostID
	}
	if opts.Mode != "" {
		payload["mode"] = opts.Mode
	}
	if opts.Model != "" {
		payload["model"] = opts.Model
	}
	if opts.Effort != "" {
		payload["effort"] = opts.Effort
	}
	body, err := c.chatSend(http.MethodPost, c.chatURL("/sessions"), payload, http.StatusCreated, http.StatusOK)
	if err != nil {
		return ChatSession{}, err
	}
	var s ChatSession
	if err := json.Unmarshal(body, &s); err != nil {
		return ChatSession{}, fmt.Errorf("decode create-session response: %w", err)
	}
	return s, nil
}

// ListChatSessions returns the sidebar list. archived selects the active set
// (false) or the archived set (true); the flag is always sent explicitly so the
// server never has to guess a default.
func (c *Client) ListChatSessions(archived bool) ([]ChatSessionSummary, error) {
	endpoint := c.chatURL("/sessions") + "?archived=" + strconv.FormatBool(archived)
	body, err := c.chatSend(http.MethodGet, endpoint, nil, http.StatusOK)
	if err != nil {
		return nil, err
	}
	var out struct {
		Sessions []ChatSessionSummary `json:"sessions"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, fmt.Errorf("decode session list: %w", err)
	}
	return out.Sessions, nil
}

// GetChatSession fetches the FULL session (continuity fields + message tail).
// sinceSeq > 0 maps to ?since=<seq>, the turn-boundary tail refetch that returns
// only rows newer than the caller's max persisted seq (D5/D8) — pass 0 for the
// initial full load. Assistant message blocks come back as raw JSON for
// pdrender.Decode (D8); this method never inspects them.
func (c *Client) GetChatSession(id string, sinceSeq int) (ChatSession, error) {
	endpoint := c.chatURL("/sessions/" + url.PathEscape(id))
	if sinceSeq > 0 {
		endpoint += "?since=" + strconv.Itoa(sinceSeq)
	}
	body, err := c.chatSend(http.MethodGet, endpoint, nil, http.StatusOK)
	if err != nil {
		return ChatSession{}, err
	}
	var s ChatSession
	if err := json.Unmarshal(body, &s); err != nil {
		return ChatSession{}, fmt.Errorf("decode session: %w", err)
	}
	return s, nil
}

// UpdateChatSession patches the writable session fields (draft/mode/
// model_choice/effort_choice/title). Only the non-nil fields of patch are sent;
// see ChatSessionPatch for the clear-vs-untouched pointer semantics.
func (c *Client) UpdateChatSession(id string, patch ChatSessionPatch) error {
	_, err := c.chatSend(http.MethodPatch, c.chatURL("/sessions/"+url.PathEscape(id)), patch, http.StatusOK)
	return err
}

// SendChatMessage enqueues a user turn (202 accepted:true). The server does not
// distinguish a fresh turn from a mid-turn queued steer (D12) — the client
// badges "queued" from its own local turn state, not from this response.
func (c *Client) SendChatMessage(id, content string) error {
	payload := map[string]string{"content": content}
	_, err := c.chatSend(http.MethodPost, c.chatURL("/sessions/"+url.PathEscape(id)+"/messages"), payload, http.StatusAccepted, http.StatusOK)
	return err
}

// UploadChatAttachment stores one attachment in a session's CHAT-OWNED store
// and returns its reference (charter D16, ct-bl-chat-attachments).
//
// It posts to /v1/chat/sessions/:id/attachments — never to /media/upload. That
// is the whole point of the verb: `GET /media/files/*` is any-token-public, so
// an attachment that rode the media plugin would be readable by a token class
// that cannot reach the conversation. These bytes are gated by the same chat
// tenant oracle as every other /v1/chat/sessions/:id call.
//
// The body is base64 JSON rather than multipart, and the server SNIFFS the media
// type from the bytes themselves — a client-declared content type is not part of
// the contract, so there is nothing here to spoof.
func (c *Client) UploadChatAttachment(sessionID string, data []byte) (ChatAttachment, error) {
	payload := map[string]string{"data": base64.StdEncoding.EncodeToString(data)}
	body, err := c.chatSend(
		http.MethodPost,
		c.chatURL("/sessions/"+url.PathEscape(sessionID)+"/attachments"),
		payload,
		http.StatusCreated, http.StatusOK,
	)
	if err != nil {
		return ChatAttachment{}, err
	}
	return decodeChatAttachment(body)
}

// GetChatAttachment reads one attachment back by its opaque id. The returned
// ChatAttachment carries Data (base64); use Bytes() for the decoded payload.
func (c *Client) GetChatAttachment(sessionID, attachmentID string) (ChatAttachment, error) {
	body, err := c.chatSend(
		http.MethodGet,
		c.chatURL("/sessions/"+url.PathEscape(sessionID)+"/attachments/"+url.PathEscape(attachmentID)),
		nil,
		http.StatusOK,
	)
	if err != nil {
		return ChatAttachment{}, err
	}
	return decodeChatAttachment(body)
}

// decodeChatAttachment unwraps the {"attachment": {...}} envelope both routes
// answer with. A 2xx whose body carries no id is an error rather than a
// zero-valued success — a silently empty reference would be indistinguishable
// from a working upload at every later call site.
func decodeChatAttachment(body []byte) (ChatAttachment, error) {
	var wrapper struct {
		Attachment ChatAttachment `json:"attachment"`
	}
	if err := json.Unmarshal(body, &wrapper); err != nil {
		return ChatAttachment{}, err
	}
	if wrapper.Attachment.ID == "" {
		return ChatAttachment{}, fmt.Errorf("chat attachment response carried no id")
	}
	return wrapper.Attachment, nil
}

// InterruptChat requests a mid-turn interrupt (202 {request_id}). The control
// ack is semantically EMPTY (D11): the request_id is returned best-effort and a
// missing/empty one is NOT an error — the true "interrupted" signal is the
// terminal result frame on the events stream, not this response. Esc with no
// active turn is a benign no-op server-side.
func (c *Client) InterruptChat(id string) (string, error) {
	body, err := c.chatSend(http.MethodPost, c.chatURL("/sessions/"+url.PathEscape(id)+"/interrupt"), nil, http.StatusAccepted, http.StatusOK)
	if err != nil {
		return "", err
	}
	var out struct {
		RequestID string `json:"request_id"`
	}
	_ = json.Unmarshal(body, &out) // empty/omitted request_id is fine (D11)
	return out.RequestID, nil
}

// ArchiveChatSession shelves a session: POST /v1/chat/sessions/:id/archive →
// 200 {session}. Idempotent (re-archiving re-stamps archived_at).
//
// Archive is a lifecycle ACTION, not a continuity field — which is why it is a
// POST verb and NOT a key on UpdateChatSession's patch: the server's PATCH
// allowlist deliberately excludes `archived`, and routing it through the patch
// would mix a dismissal into the continuity-keys allowlist.
//
// Orthogonal to `status` (liveness) and to `agent_state` (attention): a running
// session keeps running when archived, and a blocked one keeps needing you.
// Only which LIST it appears in changes.
//
// The 404 is the not-found ORACLE: a foreign tenant's session and a missing id
// are deliberately indistinguishable, so callers must not read a 404 as "it
// exists but you may not touch it".
func (c *Client) ArchiveChatSession(id string) (ChatSession, error) {
	return c.chatArchiveFlip(id, "archive")
}

// UnarchiveChatSession clears archived_at: POST /v1/chat/sessions/:id/unarchive
// → 200 {session}. Same oracle, same idempotency (unarchiving a live session is
// a no-op that still 200s).
func (c *Client) UnarchiveChatSession(id string) (ChatSession, error) {
	return c.chatArchiveFlip(id, "unarchive")
}

// chatArchiveFlip is the shared body of the two archive verbs — they differ by
// one path segment and nothing else, so they are one implementation.
func (c *Client) chatArchiveFlip(id, verb string) (ChatSession, error) {
	body, err := c.chatSend(http.MethodPost, c.chatURL("/sessions/"+url.PathEscape(id)+"/"+verb), nil, http.StatusOK)
	if err != nil {
		return ChatSession{}, err
	}
	var s ChatSession
	if err := json.Unmarshal(body, &s); err != nil {
		return ChatSession{}, fmt.Errorf("decode %s response: %w", verb, err)
	}
	return s, nil
}

// RespondChatApproval answers a pending permission request (204). decision is
// the engine's decision string (e.g. "allow"/"deny"); requestID is the id the
// permission event carried.
func (c *Client) RespondChatApproval(id, requestID, decision string) error {
	payload := map[string]string{"request_id": requestID, "decision": decision}
	_, err := c.chatSend(http.MethodPost, c.chatURL("/sessions/"+url.PathEscape(id)+"/approval"), payload, http.StatusNoContent, http.StatusOK)
	return err
}

// ChatEvents opens the session's SSE stream and dispatches each frame to
// onEvent(event, data). The event vocabulary from the wire contract:
//
//   - event:message — a replayed persisted row, carrying id:<seq> (replay phase,
//     emitted when Last-Event-ID is present on connect).
//   - event:chat    — a live raw claude stream-json delta, NO id (unreplayable
//     by design, D5).
//   - event:permission — a pending approval ask.
//   - event:workflow — a live COMPACT workflow-summary delta (ChatWorkflowSummary,
//     wsc-bl-workflow-sse), NO id (unreplayable, like chat/permission/exit); it
//     refreshes the collapsed workflow strip mid-turn without a rail refetch.
//     Workflow-only — no epic sibling; a Terminal summary drops the strip.
//   - event:exit    — the session process ended, carrying a PUBLIC
//     {status, reason} only (raw process error output is an internal detail the
//     transport deliberately withholds); the client forwards the frame verbatim
//     to the TUI's status rail.
//   - `: keepalive`  comments every 30s — swallowed by the parser.
//
// The caller OWNS the cursor (D5): lastEventID is the max persisted seq the
// caller already holds, seeded into the resume position instead of inheriting a
// stale internal one. As replayed id:<seq> frames arrive, scanListenFrames (the
// SAME SSE parser Client.Listen uses — no second parser is forked here) advances
// the cursor, so an unexpected drop reconnects with Last-Event-ID set to the
// last row actually seen and replays exactly the gap. Live deltas carry no id,
// so the cursor only moves on turn-boundary message rows.
//
// Resilience mirrors Listen: the initial connect is strict (transport error or
// non-200 fails fast — bad creds don't retry forever), but once a 200 stream has
// been established, an EOF/read error or a transient 5xx (a deploy/restart blip)
// is backed off (floored, doubling to a 30s cap) and reconnected, calling
// onReconnect (nil-safe) each attempt. A mid-life 4xx stays fatal. ctx
// cancellation (Ctrl-C / Esc-quit) always exits nil.
func (c *Client) ChatEvents(ctx context.Context, id, lastEventID string, onEvent func(event, data string) error, onReconnect func()) error {
	suffix := "/sessions/" + url.PathEscape(id) + "/events"

	const (
		maxBackoff      = 30 * time.Second
		maxTransient5xx = 5
	)
	floorBackoff := c.listenBackoffFloor
	if floorBackoff <= 0 {
		floorBackoff = time.Second
	}

	// The caller owns the cursor: seed the resume position from the supplied
	// max-persisted-seq rather than starting empty. scanListenFrames advances it
	// as id:<seq> frames arrive so reconnects resume exactly after the last seen.
	cursor := lastEventID
	backoff := floorBackoff
	connected := false
	consecutive5xx := 0

	for attempt := 0; ; attempt++ {
		if attempt > 0 && onReconnect != nil {
			onReconnect()
		}

		req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.chatURL(suffix), nil)
		if err != nil {
			return err
		}
		if c.token != "" {
			req.Header.Set("Authorization", "Bearer "+c.token)
		}
		req.Header.Set("Accept", "text/event-stream")
		if cursor != "" {
			req.Header.Set("Last-Event-ID", cursor)
		}

		// No client timeout — the stream is long-lived; ctx cancellation ends it.
		resp, err := (&http.Client{Timeout: 0}).Do(req)
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			if !connected {
				return err // strict initial connect
			}
			if !sleepBackoff(ctx, &backoff, maxBackoff) {
				return nil
			}
			continue
		}

		if resp.StatusCode != http.StatusOK {
			body, _ := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
			resp.Body.Close()
			// Once connected, a 5xx is the shape of a control-plane restart
			// answering mid-reconnect — back off and retry up to a small cap. A
			// mid-life 4xx (401/404) and any first-attempt non-200 stay fatal.
			if connected && resp.StatusCode >= 500 {
				consecutive5xx++
				if consecutive5xx <= maxTransient5xx {
					if !sleepBackoff(ctx, &backoff, maxBackoff) {
						return nil
					}
					continue
				}
			}
			return humanAPIError(resp.StatusCode, body)
		}

		connected = true
		consecutive5xx = 0
		cbErr := scanListenFrames(resp.Body, &cursor, &backoff, floorBackoff, onEvent, nil)
		resp.Body.Close()

		if cbErr != nil {
			return cbErr // onEvent asked to stop, or ErrFrameTooLarge (permanent loss, not a drop)
		}
		// Check ctx BEFORE reconnecting: a cancelled ctx mid-read surfaces as the
		// scan-loop end, otherwise indistinguishable from a server drop.
		if ctx.Err() != nil {
			return nil
		}
		if !sleepBackoff(ctx, &backoff, maxBackoff) {
			return nil
		}
	}
}
