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
	ID     string `json:"id"`
	Title  string `json:"title,omitempty"`
	Status string `json:"status,omitempty"`
	Cwd    string `json:"cwd,omitempty"`
	Mode   string `json:"mode,omitempty"`
	Model  string `json:"model,omitempty"`

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
}

// ChatSessionSummary is the sidebar shape from GET /v1/chat/sessions (the
// list_sessions/1 → sidebar_json projection). It intentionally lacks draft, the
// rail, and the model/effort choices — those live only on the full GET :id
// struct (D14). Keeping it a separate type makes "don't trust the list for
// continuity" a compile-time fact. The counters (message_count/pending_approvals)
// and last_active_at are what the picker renders per row.
type ChatSessionSummary struct {
	ID               string `json:"id"`
	Title            string `json:"title,omitempty"`
	Status           string `json:"status,omitempty"`
	Summary          string `json:"summary,omitempty"`
	MessageCount     int    `json:"message_count,omitempty"`
	PendingApprovals int    `json:"pending_approvals,omitempty"`
	LastActiveAt     string `json:"last_active_at,omitempty"`
	InsertedAt       string `json:"inserted_at,omitempty"`
	UpdatedAt        string `json:"updated_at,omitempty"`
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
	payload := map[string]string{}
	if mode != "" {
		payload["mode"] = mode
	}
	if model != "" {
		payload["model"] = model
	}
	if effort != "" {
		payload["effort"] = effort
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
		cbErr := scanListenFrames(resp.Body, &cursor, &backoff, floorBackoff, onEvent)
		resp.Body.Close()

		if cbErr != nil {
			return cbErr // onEvent asked to stop
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
