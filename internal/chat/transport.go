package chat

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// Transport is the client's single IO seam: every /v1/chat call the TUI makes,
// behind an interface so the reducer/model tests run against a fake and the
// whole surface can be re-based onto internal/apiclient's chat bindings
// (ct-w1-apiclient) without touching the state machine. The methods map 1:1
// onto the charter wire contract (§Wire contract v1).
type Transport interface {
	// CreateSession POSTs /v1/chat/sessions and returns the created session.
	CreateSession() (Session, error)
	// ListSessions GETs /v1/chat/sessions (non-archived).
	ListSessions() ([]SessionSummary, error)
	// GetSession GETs /v1/chat/sessions/:id — the FULL struct. sinceSeq > 0
	// appends ?since= so only newer message rows return (the turn-boundary
	// tail refetch, charter D8/D15).
	GetSession(id string, sinceSeq int) (Session, error)
	// PatchSession PATCHes draft/mode/model_choice/effort_choice/title.
	PatchSession(id string, fields map[string]any) error
	// SendMessage POSTs a user message; the server always 202s — queued-ness
	// is CLIENT state (charter D12).
	SendMessage(id, content string) error
	// Interrupt POSTs the interrupt; the ack is semantically EMPTY (charter
	// D11) — the real signal is the result frame on the event stream.
	Interrupt(id string) error
	// Events opens the per-session SSE stream and hands every frame to
	// onFrame(event, data). Replayed persisted rows arrive as event
	// "message" (with an id: line the transport uses for Last-Event-ID
	// resume); live frames as "chat"/"permission"/"exit". Blocks until ctx
	// is cancelled or the stream fails.
	Events(ctx context.Context, id string, lastSeq int, onFrame func(event string, data []byte)) error
}

// httpTransport implements Transport over stdlib net/http against the charter
// wire contract — the same shape as internal/apiclient's listen.go SSE client,
// scoped to the flat /v1/chat routes (admin-token gated, never workspace
// scoped).
type httpTransport struct {
	baseURL string
	token   string
	http    *http.Client
}

// NewHTTPTransport builds the real Transport for baseURL + data-plane bearer
// token (cfg.Token — NEVER the control-plane CloudToken, charter D3).
func NewHTTPTransport(baseURL, token string) Transport {
	return &httpTransport{
		baseURL: strings.TrimRight(baseURL, "/"),
		token:   token,
		// Verb calls are small and must fail honestly rather than wedge the
		// TUI; the SSE stream builds its own timeout-less client in Events.
		http: &http.Client{Timeout: 15 * time.Second},
	}
}

func (t *httpTransport) url(suffix string) string { return t.baseURL + "/v1/chat" + suffix }

// do issues one JSON verb call and decodes the response into out (nil out
// discards the body). Non-2xx statuses surface as one honest error line with
// the body head attached — the TUI shows it, never panics.
func (t *httpTransport) do(method, url string, body any, out any) error {
	var rdr io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			return err
		}
		rdr = bytes.NewReader(raw)
	}
	req, err := http.NewRequest(method, url, rdr)
	if err != nil {
		return err
	}
	if t.token != "" {
		req.Header.Set("Authorization", "Bearer "+t.token)
	}
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := t.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		head, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		return fmt.Errorf("%s %s: %s (%s)", method, url, resp.Status, strings.TrimSpace(string(head)))
	}
	if out == nil {
		return nil
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

func (t *httpTransport) CreateSession() (Session, error) {
	var s Session
	err := t.do(http.MethodPost, t.url("/sessions"), map[string]any{}, &s)
	return s, err
}

func (t *httpTransport) ListSessions() ([]SessionSummary, error) {
	var env sessionsEnvelope
	if err := t.do(http.MethodGet, t.url("/sessions"), nil, &env); err != nil {
		return nil, err
	}
	return env.Sessions, nil
}

func (t *httpTransport) GetSession(id string, sinceSeq int) (Session, error) {
	u := t.url("/sessions/" + id)
	if sinceSeq > 0 {
		u += fmt.Sprintf("?since=%d", sinceSeq)
	}
	var s Session
	err := t.do(http.MethodGet, u, nil, &s)
	return s, err
}

func (t *httpTransport) PatchSession(id string, fields map[string]any) error {
	return t.do(http.MethodPatch, t.url("/sessions/"+id), fields, nil)
}

func (t *httpTransport) SendMessage(id, content string) error {
	return t.do(http.MethodPost, t.url("/sessions/"+id+"/messages"), map[string]any{"content": content}, nil)
}

func (t *httpTransport) Interrupt(id string) error {
	return t.do(http.MethodPost, t.url("/sessions/"+id+"/interrupt"), map[string]any{}, nil)
}

// Events streams the per-session SSE feed. Resume is by TURN BOUNDARY
// (charter D5): only replayed persisted rows carry id: lines, so on a drop we
// reconnect with Last-Event-ID = the last replayed seq (or the caller's
// lastSeq baseline) and the server replays rows we missed; live deltas are
// unreplayable by design and simply resume from "now". The initial connect is
// strict (bad creds fail fast); after the first 200 the loop backs off
// (1s→30s doubling) and reconnects, exactly like apiclient.Listen.
func (t *httpTransport) Events(ctx context.Context, id string, lastSeq int, onFrame func(event string, data []byte)) error {
	const maxBackoff = 30 * time.Second
	lastEventID := ""
	if lastSeq > 0 {
		lastEventID = fmt.Sprintf("%d", lastSeq)
	}
	backoff := time.Second
	connected := false

	for {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, t.url("/sessions/"+id+"/events"), nil)
		if err != nil {
			return err
		}
		if t.token != "" {
			req.Header.Set("Authorization", "Bearer "+t.token)
		}
		// The canonical streaming Accept — the AcceptBarkparkVendor plug
		// admits it past the :accepts ["json"] matcher (charter D6).
		req.Header.Set("Accept", "text/event-stream")
		if lastEventID != "" {
			req.Header.Set("Last-Event-ID", lastEventID)
		}

		resp, err := (&http.Client{Timeout: 0}).Do(req)
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			if !connected {
				return err
			}
			if !sleepCtx(ctx, backoff) {
				return nil
			}
			backoff = minDur(backoff*2, maxBackoff)
			continue
		}
		if resp.StatusCode != http.StatusOK {
			head, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
			resp.Body.Close()
			return fmt.Errorf("chat events: %s (%s)", resp.Status, strings.TrimSpace(string(head)))
		}
		connected = true
		backoff = time.Second

		lastEventID = readSSE(resp.Body, lastEventID, onFrame)
		resp.Body.Close()
		if ctx.Err() != nil {
			return nil
		}
		// Stream dropped (deploy/restart/idle proxy) — back off, reconnect,
		// resume the row replay from the last id we saw.
		if !sleepCtx(ctx, backoff) {
			return nil
		}
		backoff = minDur(backoff*2, maxBackoff)
	}
}

// readSSE consumes one SSE stream: for each frame it joins multi-line data
// with \n and invokes onFrame(event, data). It returns the last id: value it
// saw (for Last-Event-ID resume). Comment lines (`: keepalive`) are skipped.
func readSSE(r io.Reader, lastEventID string, onFrame func(event string, data []byte)) string {
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 64*1024), 4*1024*1024)
	event := ""
	var data []string
	flush := func() {
		if event != "" || len(data) > 0 {
			onFrame(orMessage(event), []byte(strings.Join(data, "\n")))
		}
		event, data = "", nil
	}
	for scanner.Scan() {
		line := scanner.Text()
		switch {
		case line == "":
			flush()
		case strings.HasPrefix(line, ":"):
			// keepalive comment — liveness only, no payload
		case strings.HasPrefix(line, "event:"):
			event = strings.TrimSpace(strings.TrimPrefix(line, "event:"))
		case strings.HasPrefix(line, "data:"):
			data = append(data, strings.TrimSpace(strings.TrimPrefix(line, "data:")))
		case strings.HasPrefix(line, "id:"):
			lastEventID = strings.TrimSpace(strings.TrimPrefix(line, "id:"))
		}
	}
	flush()
	return lastEventID
}

// orMessage applies the SSE default event name.
func orMessage(event string) string {
	if event == "" {
		return "message"
	}
	return event
}

func sleepCtx(ctx context.Context, d time.Duration) bool {
	select {
	case <-ctx.Done():
		return false
	case <-time.After(d):
		return true
	}
}

func minDur(a, b time.Duration) time.Duration {
	if a < b {
		return a
	}
	return b
}
