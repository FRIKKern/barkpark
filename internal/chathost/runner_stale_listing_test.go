package chathost

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

// task-522b05a5c537bebd: a run's close whose POST the server took after the
// host's deadline cut it off has an unknown outcome to the host, so the lease
// is not marked done. A poll SENT before that run ended, but answered after,
// still lists the lease (the server answered it before the close landed). That
// listing started a second goroutine, which posted a second close.
//
// staleListingServer makes that order certain instead of timing it: the second
// poll is answered with the lease listed only after the run has ended, and the
// first close is taken only once that poll is being held, and is answered only
// after the host gave up on it.
type staleListingServer struct {
	runner *Runner

	mu          sync.Mutex
	polls       int
	completed   bool
	closesPosts int
	closesTaken int
	pollHeld    chan struct{}
	gaveUp      chan struct{}
}

func (s *staleListingServer) runEnded() bool {
	s.runner.mu.Lock()
	defer s.runner.mu.Unlock()
	_, running := s.runner.active["lease-1"]
	return !running
}

func (s *staleListingServer) handler() http.Handler {
	const listing = `{"commands":[{"lease_id":"lease-1","epoch":1,"last_cursor":0,"command":{"provider":"claude","operation":"send_turn","session_id":"session-1"}}]}`
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/v1/chat-host/heartbeat":
			_, _ = w.Write([]byte(`{"host":{"id":"host-1"}}`))
		case "/v1/chat-host/commands":
			s.mu.Lock()
			s.polls++
			n, completed := s.polls, s.completed
			s.mu.Unlock()
			switch {
			case completed:
				_, _ = w.Write([]byte(`{"commands":[]}`))
			case n == 1:
				_, _ = w.Write([]byte(listing))
			case n == 2:
				// Answered (the lease is not completed) before the close
				// lands; written only once the run that closes it has ended.
				close(s.pollHeld)
				select {
				case <-s.gaveUp:
				case <-time.After(3 * time.Second):
				}
				for deadline := time.Now().Add(3 * time.Second); !s.runEnded() && time.Now().Before(deadline); {
					time.Sleep(time.Millisecond)
				}
				_, _ = w.Write([]byte(listing))
			default:
				_, _ = w.Write([]byte(listing))
			}
		case "/v1/chat-host/events":
			// Read the body: the server sees the client go away (r.Context()
			// done) only once the body is consumed.
			_, _ = io.Copy(io.Discard, r.Body)
			s.mu.Lock()
			s.closesPosts++
			first := s.closesPosts == 1
			s.mu.Unlock()
			if !first {
				// A second close on a completed lease: its event is not the
				// one taken, so the server answers cursor_conflict.
				w.WriteHeader(http.StatusUnprocessableEntity)
				_, _ = w.Write([]byte(`{"error":{"code":"unprocessable","message":":cursor_conflict"}}`))
				return
			}
			select {
			case <-s.pollHeld:
			case <-time.After(3 * time.Second):
			}
			s.mu.Lock()
			s.completed = true
			s.closesTaken++
			s.mu.Unlock()
			// Taken; the answer never reaches the host before its deadline.
			select {
			case <-r.Context().Done():
			case <-time.After(3 * time.Second):
			}
			close(s.gaveUp)
		}
	})
}

func TestRunnerDoesNotCloseALeaseAgainFromAPollSentBeforeItsRunEnded(t *testing.T) {
	defer func(old time.Duration) { terminalPublishTimeout = old }(terminalPublishTimeout)
	terminalPublishTimeout = 100 * time.Millisecond

	handler := &failingHandler{}
	runner := &Runner{Handler: handler, PollInterval: time.Millisecond, Log: &syncBuffer{}}
	server := &staleListingServer{runner: runner, pollHeld: make(chan struct{}), gaveUp: make(chan struct{})}
	ts := httptest.NewServer(server.handler())
	defer ts.Close()
	runner.Client = &Client{BaseURL: ts.URL, Credential: "host-secret", HTTPClient: ts.Client(), AllowInsecureLoopback: true}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	result := make(chan error, 1)
	go func() { result <- runner.Run(ctx) }()

	select {
	case <-server.gaveUp:
	case <-ctx.Done():
		t.Fatal("the host never posted the close")
	}
	// Let the held poll be answered and a few more polls go by.
	time.Sleep(300 * time.Millisecond)
	cancel()
	<-result

	server.mu.Lock()
	defer server.mu.Unlock()
	if server.polls < 3 {
		t.Fatalf("polls=%d; the scenario needs the held poll answered and one after it", server.polls)
	}
	if got := handler.runs.Load(); got != 1 {
		t.Fatalf("provider runs=%d want 1", got)
	}
	if server.closesTaken != 1 || server.closesPosts != 1 {
		t.Fatalf("close POSTs=%d taken=%d; want 1 and 1: a poll sent before the run ended started a second close", server.closesPosts, server.closesTaken)
	}
}
