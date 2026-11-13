package chathost

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// leaseServer plays the server's side of one lease: it hands the lease out on
// every poll until it holds a completed event (ChatHosts.next_commands/1), takes
// an event only at last_cursor+1, answers a repeat of a taken cursor as a
// duplicate, and refuses a gap (ChatHosts.reconcile_event/4).
type leaseServer struct {
	mu         sync.Mutex
	lastCursor uint64
	completed  bool
	kinds      []string
	refuse     func(cursor uint64) int // non-zero: answer this attempt with that status
	posts      int                     // event POSTs received
	// staleListings: polls that still list the lease after it completed, as a
	// poll answered just before the last event landed does.
	staleListings int
}

func (s *leaseServer) handler(t *testing.T) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		s.mu.Lock()
		defer s.mu.Unlock()
		switch r.URL.Path {
		case "/v1/chat-host/heartbeat":
			_, _ = w.Write([]byte(`{"host":{"id":"host-1"}}`))
		case "/v1/chat-host/commands":
			if s.completed && s.staleListings == 0 {
				_, _ = w.Write([]byte(`{"commands":[]}`))
				return
			}
			if s.completed {
				s.staleListings--
				fmt.Fprintf(w, `{"commands":[{"lease_id":"lease-1","epoch":1,"last_cursor":%d,"command":{"provider":"claude","operation":"send_turn","session_id":"session-1"}}]}`, s.lastCursor-1)
				return
			}
			fmt.Fprintf(w, `{"commands":[{"lease_id":"lease-1","epoch":1,"last_cursor":%d,"command":{"provider":"claude","operation":"send_turn","session_id":"session-1"}}]}`, s.lastCursor)
		case "/v1/chat-host/events":
			var payload struct {
				Cursor uint64         `json:"cursor"`
				Event  map[string]any `json:"event"`
			}
			if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
				t.Error(err)
				return
			}
			s.posts++
			status := 0
			if s.refuse != nil {
				status = s.refuse(payload.Cursor)
			}
			switch {
			case status != 0:
				w.WriteHeader(status)
				_, _ = w.Write([]byte(`{"error":{"code":"refused"}}`))
			case payload.Cursor <= s.lastCursor && s.completed:
				w.WriteHeader(http.StatusUnprocessableEntity)
				_, _ = w.Write([]byte(`{"error":{"code":"unprocessable","message":":cursor_conflict"}}`))
				s.kinds = append(s.kinds, "refused-after-completed")
			case payload.Cursor <= s.lastCursor:
				_, _ = w.Write([]byte(`{"accepted":false,"duplicate":true}`))
			case payload.Cursor != s.lastCursor+1:
				w.WriteHeader(http.StatusUnprocessableEntity)
				_, _ = w.Write([]byte(`{"error":{"code":"unprocessable","message":":cursor_gap"}}`))
			default:
				s.lastCursor = payload.Cursor
				kind, _ := payload.Event["kind"].(string)
				s.kinds = append(s.kinds, kind)
				if kind == "turn_completed" || kind == "terminal" {
					s.completed = true
				}
				w.WriteHeader(http.StatusAccepted)
				_, _ = w.Write([]byte(`{"accepted":true}`))
			}
		}
	})
}

func (s *leaseServer) snapshot() (bool, []string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.completed, append([]string(nil), s.kinds...)
}

// turnHandler is one provider run per call: a reply of three deltas.
type turnHandler struct{ runs atomic.Int32 }

func (h *turnHandler) Handle(_ context.Context, _ RemoteCommand, emit func(map[string]any) error) error {
	h.runs.Add(1)
	for _, event := range []map[string]any{
		{"kind": "session_started"},
		{"kind": "turn_started"},
		{"kind": "text_delta", "delta": "one "},
		{"kind": "text_delta", "delta": "two "},
		{"kind": "text_delta", "delta": "three"},
		{"kind": "turn_completed", "terminal_state": "completed"},
	} {
		if err := emit(event); err != nil {
			return err
		}
	}
	return nil
}

// failingHandler is a provider run that dies before it emits anything, as
// claude does when it exits before the turn starts.
type failingHandler struct{ runs atomic.Int32 }

func (h *failingHandler) Handle(context.Context, RemoteCommand, func(map[string]any) error) error {
	h.runs.Add(1)
	return fmt.Errorf("claude exited before turn completion")
}

func startRunner(t *testing.T, server *leaseServer, handler Handler) (context.Context, func()) {
	t.Helper()
	ts := httptest.NewServer(server.handler(t))
	runner := Runner{
		Client:       &Client{BaseURL: ts.URL, Credential: "host-secret", HTTPClient: ts.Client(), AllowInsecureLoopback: true},
		Handler:      handler,
		PollInterval: time.Millisecond,
		Log:          &syncBuffer{},
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	result := make(chan error, 1)
	go func() { result <- runner.Run(ctx) }()
	return ctx, func() {
		cancel()
		if err := <-result; err != nil && ctx.Err() == nil {
			t.Errorf("Run ended: %v", err)
		}
		ts.Close()
	}
}

func runUntilCompleted(t *testing.T, server *leaseServer, handler Handler) {
	t.Helper()
	ctx, stop := startRunner(t, server, handler)
	defer stop()
	for {
		if done, _ := server.snapshot(); done {
			break
		}
		select {
		case <-ctx.Done():
			_, kinds := server.snapshot()
			t.Fatalf("the lease never completed; events taken: %v", kinds)
		case <-time.After(time.Millisecond):
		}
	}
	// Let the polls hand out whatever the server still lists.
	for i := 0; i < 50; i++ {
		server.mu.Lock()
		stale := server.staleListings
		server.mu.Unlock()
		if stale == 0 {
			break
		}
		time.Sleep(time.Millisecond)
	}
	time.Sleep(30 * time.Millisecond)
}

// The live failure on guerrilla (task-1fa6009d589cd92a): a long reply spent
// the write budget, an event POST answered 429, the turn ended, the next poll
// handed the same lease out again and the host ran the turn again from the
// top, every few seconds, until someone pressed stop. A refused event must be
// retried inside the one run: the provider runs once and the reply is stored
// once.
func TestRunnerRefusedEventDoesNotRestartTheTurn(t *testing.T) {
	var attempts sync.Map
	server := &leaseServer{refuse: func(cursor uint64) int {
		if cursor != 3 {
			return 0
		}
		n, _ := attempts.LoadOrStore(cursor, new(atomic.Int32))
		if n.(*atomic.Int32).Add(1) <= 2 {
			return http.StatusTooManyRequests
		}
		return 0
	}}
	handler := &turnHandler{}
	runUntilCompleted(t, server, handler)

	if got := handler.runs.Load(); got != 1 {
		t.Fatalf("provider runs=%d want 1: a refused event restarted the turn", got)
	}
	_, kinds := server.snapshot()
	want := []string{"session_started", "turn_started", "text_delta", "text_delta", "text_delta", "turn_completed"}
	if fmt.Sprint(kinds) != fmt.Sprint(want) {
		t.Fatalf("events taken=%v want %v", kinds, want)
	}
}

// A lease the server already took events for was started before: by this
// process, or by a host process that is gone. It is closed, never run again.
func TestRunnerClosesALeaseItAlreadyStartedInsteadOfRunningItAgain(t *testing.T) {
	server := &leaseServer{lastCursor: 4}
	handler := &turnHandler{}
	runUntilCompleted(t, server, handler)

	if got := handler.runs.Load(); got != 0 {
		t.Fatalf("provider runs=%d want 0: a lease with 4 events taken was run again", got)
	}
	if _, kinds := server.snapshot(); fmt.Sprint(kinds) != "[terminal]" {
		t.Fatalf("events taken=%v want one terminal", kinds)
	}
}

// A poll answered just before a turn's last event landed still lists the
// lease. The turn this process just finished is neither run again nor closed
// a second time.
func TestRunnerDoesNotRestartALeaseItJustFinished(t *testing.T) {
	server := &leaseServer{staleListings: 3}
	handler := &turnHandler{}
	runUntilCompleted(t, server, handler)

	if got := handler.runs.Load(); got != 1 {
		t.Fatalf("provider runs=%d want 1", got)
	}
	_, kinds := server.snapshot()
	want := []string{"session_started", "turn_started", "text_delta", "text_delta", "text_delta", "turn_completed"}
	if fmt.Sprint(kinds) != fmt.Sprint(want) {
		t.Fatalf("events=%v want %v: a finished lease was posted to again", kinds, want)
	}
}

// A run that died before the server took any of its events, whose terminal
// was refused too, is listed again with last_cursor 0. This process started
// it, so it is closed, never handed to the provider a second time.
func TestRunnerNeverRunsALeaseTwiceEvenWhenNoEventWasTaken(t *testing.T) {
	defer func(old time.Duration) { terminalPublishTimeout = old }(terminalPublishTimeout)
	terminalPublishTimeout = 20 * time.Millisecond
	opened := time.Now()
	server := &leaseServer{refuse: func(uint64) int {
		if time.Since(opened) < 150*time.Millisecond {
			return http.StatusServiceUnavailable
		}
		return 0
	}}
	handler := &failingHandler{}
	runUntilCompleted(t, server, handler)

	if got := handler.runs.Load(); got != 1 {
		t.Fatalf("provider runs=%d want 1: a lease this process started was run again", got)
	}
	if _, kinds := server.snapshot(); fmt.Sprint(kinds) != "[terminal]" {
		t.Fatalf("events taken=%v want one terminal", kinds)
	}
}

// A close the server refuses for good (409: the lease expired) is sent once.
// Sent again on every poll, each try spends the write budget that started the
// incident and logs two lines.
func TestRunnerDoesNotRepeatACloseTheServerRefusedForGood(t *testing.T) {
	server := &leaseServer{lastCursor: 4, refuse: func(uint64) int { return http.StatusConflict }}
	handler := &turnHandler{}
	_, stop := startRunner(t, server, handler)
	time.Sleep(150 * time.Millisecond)
	stop()

	server.mu.Lock()
	posts := server.posts
	server.mu.Unlock()
	if posts != 1 {
		t.Fatalf("close POSTs=%d want 1", posts)
	}
	if got := handler.runs.Load(); got != 0 {
		t.Fatalf("provider runs=%d want 0", got)
	}
}
