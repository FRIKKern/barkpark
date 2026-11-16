package chathost

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

// takenFirstServer fronts a leaseServer whose first session_started POST it
// lets the lease server TAKE, then answers badly (review of #26688):
//   - slow: the 2xx is held until the turn's close arrives (3 s backstop), as
//     when the server's Recorder call after the commit is slow;
//   - lost: the answer is a 503 (the 2xx was lost on the way), and every later
//     post of session_started is refused with 503.
//
// Either way the first-event bound cuts the publish while the server holds
// event 1, so a close sent at cursor 1 is refused as cursor_conflict.
type takenFirstServer struct {
	inner *leaseServer
	lost  bool

	mu         sync.Mutex
	firstPosts int
	closes     []int // the status each close POST got
	closeSeen  chan struct{}
	closeOnce  sync.Once
}

func (s *takenFirstServer) handler(t *testing.T) http.Handler {
	inner := s.inner.handler(t)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/chat-host/events" {
			inner.ServeHTTP(w, r)
			return
		}
		body, _ := io.ReadAll(r.Body)
		var payload struct {
			Event map[string]any `json:"event"`
		}
		_ = json.Unmarshal(body, &payload)
		r.Body = io.NopCloser(bytes.NewReader(body))
		kind, _ := payload.Event["kind"].(string)

		if kind == "session_started" {
			s.mu.Lock()
			s.firstPosts++
			n := s.firstPosts
			s.mu.Unlock()
			switch {
			case n == 1:
				taken := httptest.NewRecorder()
				inner.ServeHTTP(taken, r)
				if s.lost {
					w.WriteHeader(http.StatusServiceUnavailable)
					return
				}
				select {
				case <-s.closeSeen:
				case <-time.After(3 * time.Second):
				}
				w.WriteHeader(taken.Code)
				_, _ = w.Write(taken.Body.Bytes())
				return
			case s.lost:
				w.WriteHeader(http.StatusServiceUnavailable)
				return
			}
		}

		answer := httptest.NewRecorder()
		inner.ServeHTTP(answer, r)
		if kind == "terminal" {
			s.mu.Lock()
			s.closes = append(s.closes, answer.Code)
			s.mu.Unlock()
			s.closeOnce.Do(func() { close(s.closeSeen) })
		}
		w.WriteHeader(answer.Code)
		_, _ = w.Write(answer.Body.Bytes())
	})
}

// runTakenFirst runs one turn against server and checks that it ends with a
// close the server took after event 1: the person's turn is not left
// "working" with its provider dead.
func runTakenFirst(t *testing.T, server *takenFirstServer) {
	t.Helper()
	server.closeSeen = make(chan struct{})
	server.inner.firstEventDeadline = 100 * time.Millisecond
	server.inner.closeDeadline = 2 * time.Second
	handler := &turnHandler{}
	ctx, stop := startRunnerOn(t, server.handler(t), server.inner, handler)
	defer stop()

	completed := waitCompleted(ctx, server.inner)
	_, kinds := server.inner.snapshot()
	server.mu.Lock()
	closes := append([]int(nil), server.closes...)
	server.mu.Unlock()
	if !completed {
		t.Fatalf("the lease was never closed: events taken %v, close answers %v. The server holds event 1, the provider was stopped, and the close it was sent was refused for good", kinds, closes)
	}
	if fmt.Sprint(kinds) != "[session_started terminal]" {
		t.Fatalf("events taken %v; want [session_started terminal]", kinds)
	}
	if fmt.Sprint(closes) != fmt.Sprint([]int{http.StatusUnprocessableEntity, http.StatusAccepted}) {
		t.Fatalf("close answers %v; want 422 at cursor 1 (taken by event 1), then 202 at cursor 2", closes)
	}
	if got := handler.runs.Load(); got != 1 {
		t.Fatalf("provider runs=%d want 1", got)
	}
}

// The server took event 1, but its 2xx comes after the bound.
func TestRunnerClosesATurnWhoseFirstEventWasTakenButAnsweredTooLate(t *testing.T) {
	runTakenFirst(t, &takenFirstServer{inner: &leaseServer{}})
}

// The server took event 1, its 2xx was lost, and every retry meets a 503 until
// the bound.
func TestRunnerClosesATurnWhoseFirstEventWasTakenThenRefusedUntilTheBound(t *testing.T) {
	runTakenFirst(t, &takenFirstServer{inner: &leaseServer{}, lost: true})
}

// controlHandler answers a control lease with its one event.
type controlHandler struct{}

func (controlHandler) Handle(_ context.Context, remote RemoteCommand, emit func(map[string]any) error) error {
	operation, _ := remote.Command["operation"].(string)
	return emit(map[string]any{"kind": "control_completed", "operation": operation})
}

// A control lease starts no provider: its one event rides out an outage
// longer than FirstEventTimeout under the general bound, as before (from the
// review of #26688). Counted from the server's first refusal, so a bound
// applied here would have fired before the outage ends.
func TestRunnerControlLeaseRidesOutAnOutagePastTheFirstEventBound(t *testing.T) {
	const bound = 100 * time.Millisecond
	var firstRefusal time.Time
	server := &leaseServer{
		command:            `{"provider":"claude","operation":"interrupt","session_id":"session-1"}`,
		firstEventDeadline: bound,
		// Called with server.mu held.
		refuse: func(uint64) int {
			if firstRefusal.IsZero() {
				firstRefusal = time.Now()
			}
			if time.Since(firstRefusal) < 4*bound {
				return http.StatusServiceUnavailable
			}
			return 0
		},
	}
	ctx, stop := startRunner(t, server, controlHandler{})
	defer stop()
	// control_completed does not complete the fake lease: wait for any event.
	for ctx.Err() == nil {
		if _, kinds := server.snapshot(); len(kinds) > 0 {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if _, kinds := server.snapshot(); fmt.Sprint(kinds) != "[control_completed]" {
		t.Fatalf("events taken %v; want [control_completed]: the first-event bound cut a control lease", kinds)
	}
}

func TestFirstEventTimeoutFromEnv(t *testing.T) {
	for value, want := range map[string]time.Duration{
		"": 0, "250ms": 250 * time.Millisecond, " 30s ": 30 * time.Second,
		"0": 0, "-1s": 0, "ten seconds": 0,
	} {
		got := FirstEventTimeoutFromEnv(func(name string) string {
			if name == "BARKPARK_CHAT_HOST_FIRST_EVENT_TIMEOUT" {
				return value
			}
			return ""
		})
		if got != want {
			t.Errorf("BARKPARK_CHAT_HOST_FIRST_EVENT_TIMEOUT=%q: %v; want %v", value, got, want)
		}
	}
	if got := (&Runner{}).firstEventTimeout(); got != 10*time.Second {
		t.Fatalf("default first-event bound %v; want 10s", got)
	}
}
