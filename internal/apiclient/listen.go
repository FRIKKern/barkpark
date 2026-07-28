// Package apiclient — user-facing SSE listen. `Listen` streams the change feed
// and hands each event to a callback (the `bp listen` command prints them),
// distinct from the TUI's internal change-detection in change.go.
package apiclient

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// maxSSELineBytes caps a single SSE line the shared reader will assemble. It
// follows the in-tree precedent for the same class of problem: export.go raises
// bufio's 64KB default to 8 MiB so one oversized record cannot truncate a whole
// stream. A line of maxSSELineBytes-1 bytes is the largest bufio.Scanner can
// deliver (the newline must still fit in the buffer), so that byte is the real
// ceiling — see TestScanListenFramesByteBoundary.
//
// Raising this cap does NOT retire the server-side 262144-byte per-frame bound
// (charter D64): binaries already installed in the field carry the OLD cap and
// can never be fixed there, so the server must keep every frame inside the
// smallest cap any shipped client has. The client cap is a safety net, not a
// licence for the server to emit bigger frames.
const maxSSELineBytes = 8 * 1024 * 1024

// ErrFrameTooLarge reports that one SSE line exceeded maxSSELineBytes, so the
// scanner aborted and the rest of that HTTP response was discarded. It exists to
// be DISTINGUISHABLE: before it, an over-cap frame and a dropped connection both
// ended the read with a bare nil, so callers answered permanent data loss with a
// reconnect and no diagnosis. Test with errors.Is.
var ErrFrameTooLarge = errors.New("sse frame line too large")

// Listen opens the SSE change stream for `types` (comma-separated document types,
// or "" for all) and invokes onEvent for each event. onEvent receives the event
// name (e.g. "mutation") and its `data:` payload (multi-line frames are joined
// with "\n"). Returning an error from onEvent stops the stream.
//
// The stream is resilient: after the FIRST successful 200 connection, an
// unexpected drop (server EOF on restart/deploy, proxy idle timeout, or a read
// error) is not fatal — Listen backs off (1s floored, doubling to a 30s cap) and
// reconnects, resuming keyset replay from the last event `id:` it saw via the
// Last-Event-ID header, so events emitted during the gap are not lost. It calls
// onReconnect (nil-safe) at the start of each reconnect attempt so a caller can
// surface the gap to the user. The INITIAL connect stays strict: a transport
// error or a non-200 on the first attempt returns immediately (bad creds fail
// fast, they don't retry forever). Once connected, a 5xx answered mid-reconnect
// (a control-plane deploy/restart blip) is treated as a transient drop too —
// backed off and retried up to a small cap before the real error surfaces — but
// a 4xx mid-life (401/404) stays immediately fatal. ctx cancellation (Ctrl-C)
// always exits nil.
func (c *Client) Listen(ctx context.Context, types string, onEvent func(event, data string) error, onReconnect func()) error {
	suffix := "/v1/data/listen/" + c.Dataset
	if types != "" {
		suffix += "?types=" + url.QueryEscape(types)
	}

	const (
		maxBackoff      = 30 * time.Second
		maxTransient5xx = 5 // consecutive 5xx-on-reconnect before the error surfaces
	)
	floorBackoff := c.listenBackoffFloor
	if floorBackoff <= 0 {
		floorBackoff = time.Second
	}

	var lastEventID string
	backoff := floorBackoff
	connected := false  // set once a 200 stream has been established at least once
	consecutive5xx := 0 // 5xx blips since the last healthy 200 stream

	for attempt := 0; ; attempt++ {
		if attempt > 0 && onReconnect != nil {
			onReconnect()
		}

		req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.scopedURL(suffix), nil)
		if err != nil {
			return err
		}
		if c.token != "" {
			req.Header.Set("Authorization", "Bearer "+c.token)
		}
		req.Header.Set("Accept", "text/event-stream")
		if lastEventID != "" {
			// Resume the server's keyset replay from the last id we saw, so
			// events emitted during the drop are delivered on reconnect.
			req.Header.Set("Last-Event-ID", lastEventID)
		}

		// No client timeout — the stream is long-lived; ctx cancellation ends it.
		resp, err := (&http.Client{Timeout: 0}).Do(req)
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			// Keep the initial connect strict: a transport error before we ever
			// reached a 200 stream fails fast (unreachable server / bad host
			// must not retry forever). Once connected, a Do error is just
			// another drop to back off and reconnect through.
			if !connected {
				return err
			}
			if !sleepBackoff(ctx, &backoff, maxBackoff) {
				return nil
			}
			continue
		}

		if resp.StatusCode != http.StatusOK {
			body, _ := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
			resp.Body.Close()
			// The initial connect is strict, and a mid-life 4xx (401/404) is a
			// real error too — both fail fast. But once connected, a 5xx is the
			// shape of a control-plane deploy/restart answering mid-reconnect:
			// the same transient drop the reconnect machinery exists for. Back
			// off and retry up to a small cap; a persistently-down server past
			// the cap surfaces the real error.
			// No "listen: " wrap: listen_cmd already prefixes the message.
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
		consecutive5xx = 0 // a healthy 200 stream clears the 5xx blip streak
		cbErr := scanListenFrames(resp.Body, &lastEventID, &backoff, floorBackoff, onEvent, nil)
		resp.Body.Close()

		// onEvent asked to stop (e.g. a broken stdout pipe), or the reader hit
		// ErrFrameTooLarge — permanent loss, not a drop. Either way, propagate:
		// reconnecting past an over-cap frame would silently skip it forever.
		if cbErr != nil {
			return cbErr
		}
		// Ctrl-C (a cancelled ctx) is the one intentional stop: exit cleanly.
		//
		// Check ctx BEFORE reconnecting: when ctx is cancelled mid-read the
		// scanner surfaces the cancellation as the scan-loop end, which is
		// otherwise indistinguishable from a server drop.
		if ctx.Err() != nil {
			return nil
		}
		// SSE has no server-side "done" frame, so a clean EOF (or a scanner read
		// error) on this long-lived stream is an unexpected drop (restart /
		// deploy / proxy idle timeout). Back off, then reconnect from lastEventID.
		if !sleepBackoff(ctx, &backoff, maxBackoff) {
			return nil
		}
	}
}

// scanListenFrames reads SSE frames from r, dispatching each complete event to
// onEvent and tracking the last `id:` seen so a reconnect can resume replay. A
// delivered event resets *backoff to floor (proof the stream is healthy, so the
// next drop retries fast). It returns only a non-nil error from onEvent; any
// other scan-loop end (EOF / read error / ctx cancel) simply returns nil and the
// caller decides whether to reconnect — with ONE exception: a line that exceeds
// maxSSELineBytes returns ErrFrameTooLarge. That case is not a drop and must not
// read like one: bufio has already thrown the giant line away and stopped, so
// every later frame in the same response is lost too, and if the oversize frame
// carried an id: line (the server writes it BEFORE the data line, and resumes
// strictly exclusive) the cursor has advanced past a row that never arrived —
// permanent loss, invisible behind a reconnect. Every OTHER scan-loop end (EOF,
// a mid-stream read error, ctx cancel) still returns nil, so the callers'
// reconnect ladders keep their existing resilience unchanged.
//
// onCursor (nil-safe, herd charter D76h) observes every cursor advance as it
// happens: it fires with the new value each time an id: line moves *lastEventID,
// and ONLY then — id-less frames (live deltas, heartbeats) never fire it, so a
// caller exposing the cursor (chat_wait_for_state's resumable bound) hands out a
// value pinned across id-less heartbeats, exactly the replay position the server
// honours on Last-Event-ID. Listen and ChatEvents pass nil (no exposure, byte-
// identical behaviour); FleetEventsWithCursor threads its caller's func through.
func scanListenFrames(r io.Reader, lastEventID *string, backoff *time.Duration, floor time.Duration, onEvent func(event, data string) error, onCursor func(cursor string)) error {
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 64*1024), maxSSELineBytes) // tolerate large event frames

	var event string
	var data []string
	for scanner.Scan() {
		line := scanner.Text()
		switch {
		case line == "": // blank line = frame boundary → dispatch
			if len(data) > 0 {
				if err := onEvent(event, strings.Join(data, "\n")); err != nil {
					return err
				}
				*backoff = floor // a delivered event proves the stream is healthy
			}
			event, data = "", nil
		case strings.HasPrefix(line, ":"): // comment / keep-alive — ignore
		case strings.HasPrefix(line, "event:"):
			event = strings.TrimSpace(line[len("event:"):])
		case strings.HasPrefix(line, "data:"):
			data = append(data, strings.TrimSpace(line[len("data:"):]))
		case strings.HasPrefix(line, "id:"):
			// The server tags each frame with a keyset id; remember it so the
			// reconnect's Last-Event-ID header resumes exactly after it.
			*lastEventID = strings.TrimSpace(line[len("id:"):])
			if onCursor != nil {
				onCursor(*lastEventID)
			}
		}
	}
	// Read scanner.Err(): an over-cap line is a diagnosable failure, not silence.
	if err := scanner.Err(); errors.Is(err, bufio.ErrTooLong) {
		return fmt.Errorf("%w: a single SSE line exceeded the %d-byte reader cap; that frame and every later frame in this response were discarded", ErrFrameTooLarge, maxSSELineBytes)
	}
	return nil
}

// sleepBackoff waits the current backoff before a reconnect, returning false if
// ctx ends during the wait (so Listen exits promptly on Ctrl-C). It then doubles
// the backoff up to max, so a server that stays down is retried ever less
// aggressively.
func sleepBackoff(ctx context.Context, backoff *time.Duration, max time.Duration) bool {
	t := time.NewTimer(*backoff)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-t.C:
	}
	*backoff *= 2
	if *backoff > max {
		*backoff = max
	}
	return true
}
