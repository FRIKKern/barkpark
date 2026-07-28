package apiclient

import (
	"context"
	"io"
	"net/http"
	"time"
)

// FleetEvents opens the herd fleet SSE stream (GET /v1/chat/events) and
// dispatches each frame to onEvent(event, data). ONE connection carries the
// WHOLE in-scope herd (charter D45h) — a client watching N sessions holds this
// single stream, never N per-session ChatEvents streams. The event vocabulary
// from the wire contract:
//
//   - event:snapshot — the current scoped fleet as {sessions:[{session_id,
//     agent_state,ts,title}, …]}, carrying id:<epoch>:<seq>. The client RESETS
//     its fleet state whenever this arrives (a fresh connect, or a reconnect the
//     server degraded because the cursor fell out of the ring / crossed an epoch).
//   - event:state — a live four-state flip {session_id,agent_state,ts,title}
//     (title null on a live flip), carrying id:<epoch>:<seq> (replayable).
//   - event:heartbeat — an id-less {session_id,ts} liveness tick proving a long
//     tool call is not a dead BEAM; UNREPLAYABLE (never advances the cursor).
//   - `: keepalive` comments every 30s — swallowed by the parser.
//
// The cursor is opaque (charter D45h): lastEventID is the "<epoch>:<seq>" pair
// the caller last saw, threaded VERBATIM — this client never parses it.
// scanListenFrames (the SAME SSE parser Client.Listen and Client.ChatEvents use
// — no third parser is forked) stores each id: line as-is and advances the
// cursor, so a drop reconnects with Last-Event-ID set to the last flip actually
// seen; the server replays exactly the missed flips or degrades to a fresh
// snapshot. Live heartbeats carry no id, so the cursor only moves on flips.
//
// Resilience mirrors ChatEvents: the initial connect is strict (transport error
// or non-200 fails fast); once a 200 stream is established, an EOF/read error or
// a transient 5xx (a deploy/restart blip) is backed off (floored, doubling to a
// 30s cap) and reconnected, calling onReconnect (nil-safe) each attempt. The
// fleet state is reset off the next event:snapshot, NEVER in onReconnect
// (transport.go precedent) — a mid-ring reconnect that replays flips must not
// wipe state. A mid-life 4xx stays fatal. ctx cancellation always exits nil.
func (c *Client) FleetEvents(ctx context.Context, lastEventID string, onEvent func(event, data string) error, onReconnect func()) error {
	return c.FleetEventsWithCursor(ctx, lastEventID, onEvent, onReconnect, nil)
}

// FleetEventsWithCursor is FleetEvents with a nil-safe onCursor observer (herd
// charter D76h): onCursor fires with the fresh "<epoch>:<seq>" value each time
// an id-bearing frame advances the internal cursor — and only then, so the value
// stays pinned across id-less heartbeats. It exists for callers that must hand
// the resume position OUT mid-stream (chat_wait_for_state returns {resolved:
// false, cursor} on its bound so a re-call replays exactly the missed flips);
// callers that only need internal reconnect-resume keep calling FleetEvents,
// whose signature and behaviour are unchanged (nil onCursor is byte-identical).
func (c *Client) FleetEventsWithCursor(ctx context.Context, lastEventID string, onEvent func(event, data string) error, onReconnect func(), onCursor func(cursor string)) error {
	const (
		maxBackoff      = 30 * time.Second
		maxTransient5xx = 5
	)
	floorBackoff := c.listenBackoffFloor
	if floorBackoff <= 0 {
		floorBackoff = time.Second
	}

	// The caller owns the cursor: seed the resume position from the supplied
	// opaque epoch:seq rather than starting empty. scanListenFrames advances it
	// as id:<epoch>:<seq> frames arrive so reconnects resume exactly after the
	// last flip seen.
	cursor := lastEventID
	backoff := floorBackoff
	connected := false
	consecutive5xx := 0

	for attempt := 0; ; attempt++ {
		if attempt > 0 && onReconnect != nil {
			onReconnect()
		}

		req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.chatURL("/events"), nil)
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
		cbErr := scanListenFrames(resp.Body, &cursor, &backoff, floorBackoff, onEvent, onCursor)
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
