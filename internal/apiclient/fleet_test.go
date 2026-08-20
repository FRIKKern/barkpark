package apiclient

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

// FleetEvents holds ONE connection for the whole herd: a single stream carries
// the snapshot for N sessions plus live flips for several of them (charter D45h
// — a client tracking N sessions does NOT open N streams). The opaque epoch:seq
// cursor advances only on id-bearing flip frames; the id-less heartbeat never
// moves it.
func TestFleetEventsSnapshotThenFlips(t *testing.T) {
	var (
		seededCursor string
		conns        int
		mu           sync.Mutex
	)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		conns++
		mu.Unlock()
		seededCursor = r.Header.Get("Last-Event-ID")
		if r.URL.Path != "/v1/chat/events" {
			t.Errorf("path = %s, want /v1/chat/events (fleet route)", r.URL.Path)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer "+chatTestToken {
			t.Errorf("fleet auth = %q", got)
		}
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		fl, _ := w.(http.Flusher)
		// Snapshot: the whole in-scope herd (N sessions) on this ONE connection.
		_, _ = io.WriteString(w, "id: 1700:0\nevent: snapshot\ndata: {\"sessions\":[{\"session_id\":\"s1\",\"agent_state\":\"working\",\"ts\":\"2026-07-18T00:00:00Z\",\"title\":\"one\"},{\"session_id\":\"s2\",\"agent_state\":\"idle\",\"ts\":null,\"title\":\"two\"}]}\n\n")
		_, _ = io.WriteString(w, ": keepalive\n\n") // comment — ignored
		// A heartbeat tick — id-less, must NOT advance the cursor.
		_, _ = io.WriteString(w, "event: heartbeat\ndata: {\"session_id\":\"s1\",\"ts\":\"2026-07-18T00:00:30Z\"}\n\n")
		// Two live flips for different sessions, each id: epoch:seq.
		_, _ = io.WriteString(w, "id: 1700:1\nevent: state\ndata: {\"session_id\":\"s1\",\"agent_state\":\"idle\",\"ts\":\"2026-07-18T00:01:00Z\",\"title\":null}\n\n")
		_, _ = io.WriteString(w, "id: 1700:2\nevent: state\ndata: {\"session_id\":\"s2\",\"agent_state\":\"working\",\"ts\":\"2026-07-18T00:01:05Z\",\"title\":null}\n\n")
		if fl != nil {
			fl.Flush()
		}
		<-r.Context().Done()
	}))
	defer srv.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	var evmu sync.Mutex
	var events []string
	err := newChatClient(srv.URL).FleetEvents(ctx, "", func(event, data string) error {
		evmu.Lock()
		events = append(events, event+"|"+data)
		n := len(events)
		evmu.Unlock()
		if n == 4 {
			cancel()
		}
		return nil
	}, nil)
	if err != nil {
		t.Fatalf("FleetEvents: %v", err)
	}
	if seededCursor != "" {
		t.Errorf("fresh connect must send no cursor, got Last-Event-ID = %q", seededCursor)
	}
	if conns != 1 {
		t.Errorf("N sessions must ride ONE connection, got %d connections", conns)
	}
	want := []string{
		`snapshot|{"sessions":[{"session_id":"s1","agent_state":"working","ts":"2026-07-18T00:00:00Z","title":"one"},{"session_id":"s2","agent_state":"idle","ts":null,"title":"two"}]}`,
		`heartbeat|{"session_id":"s1","ts":"2026-07-18T00:00:30Z"}`,
		`state|{"session_id":"s1","agent_state":"idle","ts":"2026-07-18T00:01:00Z","title":null}`,
		`state|{"session_id":"s2","agent_state":"working","ts":"2026-07-18T00:01:05Z","title":null}`,
	}
	if len(events) != len(want) {
		t.Fatalf("got %d events, want %d: %v", len(events), len(want), events)
	}
	for i := range want {
		if events[i] != want[i] {
			t.Errorf("event[%d] = %q, want %q", i, events[i], want[i])
		}
	}
}

// PROTECTIVE: the first connection replays a snapshot + one flip (id:1700:5) then
// drops (EOF). FleetEvents must reconnect carrying Last-Event-ID:1700:5 — the
// opaque cursor ADVANCED from the caller's seed (1700:3) by the flip's id,
// proving resume is by the last flip actually seen, and onReconnect fires. The
// id-less heartbeat in between must NOT have moved the cursor.
func TestFleetEventsReconnectAdvancesCursor(t *testing.T) {
	var (
		mu           sync.Mutex
		firstResume  string
		secondResume string
		attempts     int
	)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		attempts++
		n := attempts
		mu.Unlock()

		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		fl, _ := w.(http.Flusher)

		switch n {
		case 1:
			mu.Lock()
			firstResume = r.Header.Get("Last-Event-ID")
			mu.Unlock()
			_, _ = io.WriteString(w, "id: 1700:4\nevent: snapshot\ndata: {\"sessions\":[]}\n\n")
			_, _ = io.WriteString(w, "event: heartbeat\ndata: {\"session_id\":\"s1\",\"ts\":\"2026-07-18T00:00:30Z\"}\n\n")
			_, _ = io.WriteString(w, "id: 1700:5\nevent: state\ndata: {\"session_id\":\"s1\",\"agent_state\":\"blocked\",\"ts\":\"2026-07-18T00:01:00Z\",\"title\":null}\n\n")
			if fl != nil {
				fl.Flush()
			}
			// drop → EOF, forcing a reconnect
		default:
			mu.Lock()
			secondResume = r.Header.Get("Last-Event-ID")
			mu.Unlock()
			_, _ = io.WriteString(w, "id: 1700:6\nevent: state\ndata: {\"session_id\":\"s2\",\"agent_state\":\"idle\",\"ts\":\"2026-07-18T00:02:00Z\",\"title\":null}\n\n")
			if fl != nil {
				fl.Flush()
			}
			<-r.Context().Done()
		}
	}))
	defer srv.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	c := newChatClient(srv.URL)
	c.listenBackoffFloor = time.Millisecond // fast reconnect for the test

	var reconnects int
	err := c.FleetEvents(ctx, "1700:3", func(event, data string) error {
		mu.Lock()
		defer mu.Unlock()
		if event == "state" && secondResume != "" {
			cancel() // saw the post-reconnect flip
		}
		return nil
	}, func() { mu.Lock(); reconnects++; mu.Unlock() })
	if err != nil {
		t.Fatalf("FleetEvents: %v", err)
	}
	if firstResume != "1700:3" {
		t.Errorf("first connect Last-Event-ID = %q, want the caller seed 1700:3", firstResume)
	}
	if secondResume != "1700:5" {
		t.Errorf("reconnect Last-Event-ID = %q, want 1700:5 (advanced by the flip id, NOT the heartbeat)", secondResume)
	}
	if reconnects == 0 {
		t.Errorf("onReconnect never fired")
	}
}

// FleetEventsWithCursor (herd charter D76h) exposes every cursor advance to the
// caller AS IT HAPPENS: onCursor fires once per id-bearing frame with the fresh
// "<epoch>:<seq>" value, and never for the id-less heartbeat — so the handed-out
// cursor stays pinned across heartbeats, exactly the replay position the server
// honours. The plain FleetEvents path (nil onCursor) is pinned unchanged by the
// tests above; this one proves the observing variant.
func TestFleetEventsWithCursorObservesAdvances(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		fl, _ := w.(http.Flusher)
		_, _ = io.WriteString(w, "id: 1700:0\nevent: snapshot\ndata: {\"sessions\":[]}\n\n")
		_, _ = io.WriteString(w, "event: heartbeat\ndata: {\"session_id\":\"s1\",\"ts\":\"2026-07-22T00:00:30Z\"}\n\n")
		_, _ = io.WriteString(w, "id: 1700:1\nevent: state\ndata: {\"session_id\":\"s1\",\"agent_state\":\"idle\",\"ts\":\"2026-07-22T00:01:00Z\",\"title\":null}\n\n")
		if fl != nil {
			fl.Flush()
		}
		<-r.Context().Done()
	}))
	defer srv.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	var mu sync.Mutex
	var cursors []string
	var events int
	err := newChatClient(srv.URL).FleetEventsWithCursor(ctx, "", func(event, data string) error {
		mu.Lock()
		events++
		n := events
		mu.Unlock()
		if n == 3 { // snapshot + heartbeat + state all delivered
			cancel()
		}
		return nil
	}, nil, func(cursor string) {
		mu.Lock()
		cursors = append(cursors, cursor)
		mu.Unlock()
	})
	if err != nil {
		t.Fatalf("FleetEventsWithCursor: %v", err)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(cursors) != 2 || cursors[0] != "1700:0" || cursors[1] != "1700:1" {
		t.Fatalf("onCursor observed %v, want [1700:0 1700:1] — one firing per id-bearing frame, none for the heartbeat", cursors)
	}
}

// Ctrl-C mid-stream is INSTANT, and it tears the server side down with it. Herd
// charter D76h claims ctx cancellation exits sub-millisecond "on both paths";
// this is the first of the two paths — cancelled while a 200 stream is open and
// being read. FleetEvents must return nil promptly (bound generously at 500ms so
// the assertion is about promptness, not about a machine's scheduler), and the
// httptest handler must observe its OWN request context close: the cancel
// propagates through the in-flight HTTP request, so a long-poll handler blocked
// on <-r.Context().Done() wakes up rather than leaking until keepalive timeout.
//
// The backoff floor is pinned at 30s so any accidental reconnect-then-sleep path
// would blow the bound instead of hiding inside a millisecond retry.
func TestFleetEventsCancelMidStreamReturnsPromptlyAndClosesServerCtx(t *testing.T) {
	var closeOnce sync.Once
	handlerCtxClosed := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		fl, _ := w.(http.Flusher)
		_, _ = io.WriteString(w, "id: 1700:0\nevent: snapshot\ndata: {\"sessions\":[]}\n\n")
		if fl != nil {
			fl.Flush()
		}
		select {
		case <-r.Context().Done(): // the client's cancel must wake this
			closeOnce.Do(func() { close(handlerCtxClosed) })
		case <-time.After(10 * time.Second):
			// Escape hatch: if the cancel never arrives the assertions below have
			// already failed — don't also wedge srv.Close() on this handler.
		}
	}))
	defer srv.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	c := newChatClient(srv.URL)
	c.listenBackoffFloor = 30 * time.Second // a reconnect+sleep would be unmissable

	var (
		mu       sync.Mutex
		cancelAt time.Time
	)
	done := make(chan error, 1)
	go func() {
		done <- c.FleetEvents(ctx, "", func(event, data string) error {
			mu.Lock()
			cancelAt = time.Now()
			mu.Unlock()
			cancel() // Ctrl-C, mid-stream, with the connection live
			return nil
		}, nil)
	}()

	select {
	case err := <-done:
		returnedAt := time.Now()
		if err != nil {
			t.Fatalf("FleetEvents after mid-stream ctx cancel = %v, want nil (cancellation is a clean exit)", err)
		}
		mu.Lock()
		elapsed := returnedAt.Sub(cancelAt)
		mu.Unlock()
		if elapsed > 500*time.Millisecond {
			t.Fatalf("returned %s after mid-stream cancel, want < 500ms", elapsed)
		}
		t.Logf("mid-stream cancel → return in %s", elapsed)
	case <-time.After(5 * time.Second):
		t.Fatal("FleetEvents never returned within 5s of a mid-stream ctx cancel")
	}

	select {
	case <-handlerCtxClosed:
	case <-time.After(2 * time.Second):
		t.Fatal("server handler's request context never closed — the cancel did not reach the in-flight request")
	}
}

// The SECOND path of herd charter D76h's cancellation claim, and the one that
// used to have no committed proof: cancelled while PARKED IN THE BACKOFF SLEEP
// between reconnects. The handler serves one frame and returns (EOF), so the
// client falls into sleepBackoff with a 30s floor — a sleep that ignored ctx
// would hold the process for half a minute after Ctrl-C. The cancel must break
// it in well under a second, and `attempts` must still be 1: the return came out
// of the sleep, not out of a reconnect that raced ahead of the assertion.
func TestFleetEventsCancelDuringBackoffSleepReturnsImmediately(t *testing.T) {
	var (
		mu       sync.Mutex
		attempts int
	)
	dropped := make(chan struct{}, 1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		attempts++
		mu.Unlock()
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		fl, _ := w.(http.Flusher)
		_, _ = io.WriteString(w, "id: 1700:0\nevent: snapshot\ndata: {\"sessions\":[]}\n\n")
		if fl != nil {
			fl.Flush()
		}
		// Return → EOF while ctx is still alive: the client enters the backoff
		// sleep before its next connect attempt.
		select {
		case dropped <- struct{}{}:
		default:
		}
	}))
	defer srv.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	c := newChatClient(srv.URL)
	c.listenBackoffFloor = 30 * time.Second // the sleep we must be able to break

	delivered := make(chan struct{}, 1)
	done := make(chan error, 1)
	go func() {
		done <- c.FleetEvents(ctx, "", func(event, data string) error {
			select {
			case delivered <- struct{}{}:
			default:
			}
			return nil
		}, nil)
	}()

	select {
	case <-delivered:
	case <-time.After(5 * time.Second):
		t.Fatal("no frame delivered — never reached a live stream")
	}
	select {
	case <-dropped:
	case <-time.After(5 * time.Second):
		t.Fatal("handler never returned — no EOF, so no backoff sleep to cancel")
	}
	// Let the client notice the EOF and settle INTO the 30s sleep.
	time.Sleep(100 * time.Millisecond)
	mu.Lock()
	settled := attempts
	mu.Unlock()
	if settled != 1 {
		t.Fatalf("attempts = %d before the cancel, want 1 (a 30s floor must not have reconnected yet)", settled)
	}

	cancelAt := time.Now()
	cancel()
	select {
	case err := <-done:
		elapsed := time.Since(cancelAt)
		if err != nil {
			t.Fatalf("FleetEvents after ctx cancel in the backoff sleep = %v, want nil", err)
		}
		if elapsed > time.Second {
			t.Fatalf("returned %s after cancelling during a 30s backoff sleep, want < 1s", elapsed)
		}
		t.Logf("backoff-sleep cancel → return in %s (floor was 30s)", elapsed)
	case <-time.After(5 * time.Second):
		t.Fatal("FleetEvents did not return within 5s of a ctx cancel during the 30s backoff sleep — the sleep is not ctx-aware")
	}
	mu.Lock()
	defer mu.Unlock()
	if attempts != 1 {
		t.Errorf("attempts = %d, want 1 — the cancel must break the sleep, never wait it out into another connect", attempts)
	}
}

// A first-attempt non-200 fails fast (bad creds don't retry forever).
func TestFleetEventsInitialErrorFailsFast(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = io.WriteString(w, `{"error":{"code":"unauthorized"}}`)
	}))
	defer srv.Close()

	err := newChatClient(srv.URL).FleetEvents(context.Background(), "", func(string, string) error {
		return nil
	}, nil)
	if err == nil {
		t.Fatalf("a 401 on the initial connect must fail fast, got nil")
	}
}
