package chat

import (
	"context"
	"os"
	"strconv"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// transport.go — the client's single IO seam. Every /v1/chat call the TUI makes
// goes through the Transport interface so the reducer/model tests run against a
// fake and no state machine touches the network directly. The real
// implementation is a THIN adapter over internal/apiclient's chat bindings (the
// one shared wire client) — this file no longer forks its own HTTP verbs, wire
// types, or SSE parser (charter D26 / ct-bl-tui-apiclient-dedup).

// Transport is the IO seam. Its methods map 1:1 onto the charter wire contract
// (§Wire contract v1) and onto apiclient.Client's chat methods.
type Transport interface {
	// CreateSession POSTs /v1/chat/sessions and returns the created session.
	CreateSession() (Session, error)
	// ListSessions GETs /v1/chat/sessions (non-archived).
	ListSessions() ([]SessionSummary, error)
	// ListArchivedSessions GETs /v1/chat/sessions?archived=true — the SHELF read.
	// It was removed from this interface once as an unread member; it is back
	// WITH ITS CALLER (the `s` shelf screen's loadShelfCmd), which is the only
	// condition under which a seam may advertise a capability.
	ListArchivedSessions() ([]SessionSummary, error)
	// Archive POSTs /v1/chat/sessions/:id/archive — DISMISSAL, orthogonal to
	// both status (liveness) and agent_state (attention). The server emits no
	// fleet frame for the flip, so the client removes the row optimistically
	// and reconciles on the next list read.
	Archive(id string) error
	// Unarchive POSTs /v1/chat/sessions/:id/unarchive — the shelf's way BACK, the
	// exact twin of Archive: idempotent, no fleet frame for the flip (the server
	// keeps archived sessions out of the fleet snapshot entirely), so the shelf
	// screen removes the row optimistically and re-reads the ACTIVE roster to
	// bring it home.
	Unarchive(id string) error
	// GetSession GETs /v1/chat/sessions/:id — the FULL struct (rail + continuity
	// + metrics). sinceSeq > 0 appends ?since= so only newer message rows return
	// (the turn-boundary tail refetch, charter D8/D15).
	GetSession(id string, sinceSeq int) (Session, error)
	// PatchSession PATCHes draft/mode/model_choice/effort_choice/title.
	PatchSession(id string, fields map[string]any) error
	// SendMessage POSTs a user message; the server always 202s — queued-ness is
	// CLIENT state (charter D12).
	SendMessage(id, content string) error
	// Interrupt POSTs the interrupt; the ack is semantically EMPTY (charter D11)
	// — the real signal is the result frame on the event stream.
	Interrupt(id string) error
	// UploadAttachment reads a LOCAL file and stores it in the session's
	// chat-owned attachment store: POST /v1/chat/sessions/:id/attachments
	// (charter D16, ct-bl-chat-attachments). It returns the wire REFERENCE —
	// an opaque content-addressed id, the server-sniffed media type, the byte
	// size, and the chat-owned read URL.
	//
	// The local path is an INPUT to this call and never an output: it is not in
	// the reference, so it can never reach a transcript, another client, or the
	// server's own store row. And the bytes never go near /media/upload — the
	// media plugin's read boundary (any-token-public) is the exact leak this
	// route family exists to avoid.
	UploadAttachment(sessionID, path string) (Attachment, error)
	// Approve answers a pending approval/question/plan card: POST
	// /v1/chat/sessions/:id/approval {request_id, decision} → 204. decision is
	// "allow" or "deny" ONLY (charter D22/D28 — allow echoes the server-held
	// original ask, no caller-supplied updatedInput). The persisted row flips to
	// allowed/denied server-side, so a full refetch surfaces the resolution. The
	// rail-carrying full GetSession + this verb are the seam the interactive
	// cards slice (ct-bl-cards-interactive) answers approvals through — no fork.
	Approve(id, requestID, decision string) error
	// Events opens the per-session SSE stream and hands every frame to
	// onFrame(event, data). Replayed persisted rows arrive as event "message"
	// (carrying an id: line the shared parser uses for Last-Event-ID resume);
	// live frames as "chat"/"permission"/"exit". Blocks until ctx is cancelled
	// or the stream fails.
	Events(ctx context.Context, id string, lastSeq int, onFrame func(event string, data []byte)) error
	// FleetEvents opens the ONE herd fleet stream (GET /v1/chat/events, herd
	// charter D45h/D54h): snapshot-then-live four-state frames for the whole
	// in-scope fleet. It is a thin wrap over apiclient.FleetEvents — the SAME
	// scanListenFrames parser as Events, no fork — and blocks until ctx is
	// cancelled or the transport's own reconnect/backoff gives up terminally.
	FleetEvents(ctx context.Context, lastEventID string, onFrame func(event string, data []byte)) error
}

// clientTransport implements Transport over the shared internal/apiclient chat
// bindings. There is no second SSE parser or forked wire-type set here: session
// CRUD, the control verbs, and the events stream all route through
// apiclient.Client, whose SSE scanner (scanListenFrames, shared with
// Client.Listen) brings 5xx-reconnect tolerance, backoff-reset-on-frame, and
// onReconnect for free.
type clientTransport struct {
	c *apiclient.Client
}

// NewHTTPTransport builds the real Transport for the resolved connection: the
// base URL plus the data-plane bearer token (cfg.Token — NEVER the
// control-plane CloudToken, charter D3; apiclient has no CloudToken field, so
// "only the data-plane token can be sent" is structurally guaranteed).
//
// The SCOPE is handed to the wire client too, even though the /v1/chat routes
// are flat and token-scoped and never read it (D3/D21). That is deliberate:
// apiclient.New substitutes default/default/production for an empty scope, so a
// client built without it reports "workspace default, dataset production" no
// matter what the operator configured. Passing the resolved scope makes what
// the client CARRIES equal to what the CLI RESOLVED, which is the only way
// Connection below can be an honest witness instead of a constant.
func NewHTTPTransport(cfg Config) Transport {
	return &clientTransport{c: apiclient.New(apiclient.Config{
		BaseURL:   cfg.BaseURL,
		Token:     cfg.Token,
		Workspace: cfg.Workspace,
		Project:   cfg.Project,
		Dataset:   cfg.Dataset,
	})}
}

// Connection reports what this transport ACTUALLY dials — read off the live
// apiclient.Client, never off the Config it was built from. It is the witness
// the context band reconciles against (context.go): if the client were ever
// built against a different server or a different scope than the config named,
// the launch screen says so instead of echoing the config back.
//
// The scope it returns is the client's EFFECTIVE scope, apiclient's silent
// default substitution included — that substitution is exactly the fact worth
// surfacing, and hiding it here would put it back beyond reach.
func (t *clientTransport) Connection() Connection {
	if t == nil || t.c == nil {
		return Connection{}
	}
	return Connection{
		Endpoint:  t.c.BaseURL(),
		Workspace: t.c.Workspace,
		Project:   t.c.Project,
		Dataset:   t.c.Dataset,
	}
}

func (t *clientTransport) CreateSession() (Session, error) {
	// The create body carries only session-shaping choices; the TUI takes the
	// server defaults (mode/model/effort empty → omitted, cwd never sent).
	return t.c.CreateChatSession("", "", "")
}

func (t *clientTransport) ListSessions() ([]SessionSummary, error) {
	return t.c.ListChatSessions(false)
}

func (t *clientTransport) ListArchivedSessions() ([]SessionSummary, error) {
	return t.c.ListChatSessions(true)
}

func (t *clientTransport) Unarchive(id string) error {
	// The refreshed session is discarded for the same reason Archive discards
	// its own: the row is leaving THIS shelf, and the active roster re-read is
	// what paints it next. The 200 is the whole signal.
	_, err := t.c.UnarchiveChatSession(id)
	return err
}

func (t *clientTransport) Archive(id string) error {
	// The returned session is discarded: the row is leaving this shelf, so its
	// refreshed fields have no reader. The 200 is the whole signal.
	_, err := t.c.ArchiveChatSession(id)
	return err
}

func (t *clientTransport) GetSession(id string, sinceSeq int) (Session, error) {
	return t.c.GetChatSession(id, sinceSeq)
}

func (t *clientTransport) PatchSession(id string, fields map[string]any) error {
	return t.c.UpdateChatSession(id, patchFromFields(fields))
}

func (t *clientTransport) SendMessage(id, content string) error {
	return t.c.SendChatMessage(id, content)
}

func (t *clientTransport) Interrupt(id string) error {
	// The control ack is semantically EMPTY (charter D11): the request_id is
	// discarded — the true signal is the result frame on the event stream.
	_, err := t.c.InterruptChat(id)
	return err
}

func (t *clientTransport) UploadAttachment(sessionID, path string) (Attachment, error) {
	// Read locally, POST the bytes, keep the path here. The size ceiling is the
	// SERVER's (3 MB, charter D25) and it is enforced there — the client does not
	// carry a second copy of that number to drift out of step, it just reports
	// the server's refusal.
	data, err := os.ReadFile(path)
	if err != nil {
		return Attachment{}, err
	}
	return t.c.UploadChatAttachment(sessionID, data)
}

func (t *clientTransport) Approve(id, requestID, decision string) error {
	return t.c.RespondChatApproval(id, requestID, decision)
}

func (t *clientTransport) Events(ctx context.Context, id string, lastSeq int, onFrame func(event string, data []byte)) error {
	// Resume is by turn boundary (charter D5): seed Last-Event-ID from the max
	// persisted seq the caller already holds. apiclient.ChatEvents advances the
	// cursor on each id:<seq> replay row and reconnects on a drop / transient 5xx
	// blip on its own — the resilience the fork parser lacked.
	last := ""
	if lastSeq > 0 {
		last = strconv.Itoa(lastSeq)
	}
	return t.c.ChatEvents(ctx, id, last, func(event, data string) error {
		onFrame(event, []byte(data))
		return nil
	}, nil)
}

func (t *clientTransport) FleetEvents(ctx context.Context, lastEventID string, onFrame func(event string, data []byte)) error {
	// The opaque epoch:seq cursor is threaded verbatim (D45h) and advanced by
	// the shared parser; onReconnect stays nil — the herd resets off the next
	// event:snapshot, never on reconnect (D49h).
	return t.c.FleetEvents(ctx, lastEventID, func(event, data string) error {
		onFrame(event, []byte(data))
		return nil
	}, nil)
}

// patchFromFields converts the shell's writable-continuity map (charter D14:
// draft always, mode/model_choice/effort_choice/title when set) into the typed
// apiclient patch, whose pointer fields distinguish "clear" (non-nil "") from
// "leave untouched" (nil). A key with a non-string value is skipped rather than
// coerced — the shell only ever writes strings here.
func patchFromFields(fields map[string]any) apiclient.ChatSessionPatch {
	var p apiclient.ChatSessionPatch
	if s, ok := stringField(fields, "draft"); ok {
		p.Draft = s
	}
	if s, ok := stringField(fields, "mode"); ok {
		p.Mode = s
	}
	if s, ok := stringField(fields, "model_choice"); ok {
		p.ModelChoice = s
	}
	if s, ok := stringField(fields, "effort_choice"); ok {
		p.EffortChoice = s
	}
	if s, ok := stringField(fields, "title"); ok {
		p.Title = s
	}
	return p
}

// stringField returns a pointer to the string at key (a fresh copy safe to take
// the address of) and true when present and string-typed; nil/false otherwise.
func stringField(fields map[string]any, key string) (*string, bool) {
	v, ok := fields[key]
	if !ok {
		return nil, false
	}
	s, ok := v.(string)
	if !ok {
		return nil, false
	}
	return &s, true
}
