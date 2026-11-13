package chathost

import (
	"bytes"
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// syncBuffer lets the test read the runner's log while Run still writes to it.
type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

const oneCommand = `{"commands":[{"lease_id":"lease-1","epoch":1,"last_cursor":0,"command":{"provider":"claude"}}]}`

// The live failure: one "Client.Timeout exceeded while awaiting headers" on
// GET /v1/chat-host/commands ended Run and the host program exited. Here the
// first heartbeats answer 503 and the first polls time out; Run must outlast
// both and start the command the server hands out once it answers again.
func TestRunnerRetriesTransientHeartbeatAndPollFailures(t *testing.T) {
	const failures = 3
	var heartbeats, polls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/v1/chat-host/heartbeat":
			if heartbeats.Add(1) <= failures {
				w.WriteHeader(http.StatusServiceUnavailable)
				return
			}
			_, _ = w.Write([]byte(`{"host":{"id":"host-1"}}`))
		case "/v1/chat-host/commands":
			if polls.Add(1) <= failures {
				// Hold the answer past the client's timeout.
				select {
				case <-r.Context().Done():
				case <-time.After(300 * time.Millisecond):
				}
				return
			}
			_, _ = w.Write([]byte(oneCommand))
		case "/v1/chat-host/events":
			w.WriteHeader(http.StatusAccepted)
			_, _ = w.Write([]byte(`{"accepted":true}`))
		}
	}))
	defer server.Close()

	httpClient := server.Client()
	httpClient.Timeout = 30 * time.Millisecond
	handler := &blockingHandler{started: make(chan struct{}), canceled: make(chan struct{})}
	logs := &syncBuffer{}
	runner := Runner{
		Client:            &Client{BaseURL: server.URL, Credential: "host-secret", HTTPClient: httpClient, AllowInsecureLoopback: true},
		Handler:           handler,
		PollInterval:      time.Millisecond,
		HeartbeatInterval: 5 * time.Millisecond,
		Log:               logs,
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	result := make(chan error, 1)
	go func() { result <- runner.Run(ctx) }()

	select {
	case <-handler.started:
	case err := <-result:
		t.Fatalf("Run ended on a transient failure: %v", err)
	case <-ctx.Done():
		t.Fatal("the command served after the outage was never started")
	}
	if got := polls.Load(); got <= failures {
		t.Fatalf("polls=%d; the command started before the outage ended", got)
	}

	cancel()
	if err := <-result; !errors.Is(err, context.Canceled) {
		t.Fatalf("runner error=%v want context.Canceled", err)
	}
	out := logs.String()
	for _, want := range []string{"heartbeat failing", "heartbeat reconnected", "poll failing", "poll reconnected"} {
		if got := strings.Count(out, want); got != 1 {
			t.Errorf("log has %q %d times, want once per outage:\n%s", want, got, out)
		}
	}
}

// A command that is already running keeps running while polls fail.
func TestRunnerKeepsActiveCommandsThroughAnOutage(t *testing.T) {
	var polls atomic.Int32
	recovered := make(chan struct{})
	var once sync.Once
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/v1/chat-host/heartbeat":
			_, _ = w.Write([]byte(`{"host":{"id":"host-1"}}`))
		case "/v1/chat-host/commands":
			switch n := polls.Add(1); {
			case n == 1:
				_, _ = w.Write([]byte(oneCommand))
			case n <= 4:
				w.WriteHeader(http.StatusBadGateway)
			default:
				once.Do(func() { close(recovered) })
				_, _ = w.Write([]byte(`{"commands":[]}`))
			}
		case "/v1/chat-host/events":
			w.WriteHeader(http.StatusAccepted)
			_, _ = w.Write([]byte(`{"accepted":true}`))
		}
	}))
	defer server.Close()

	handler := &blockingHandler{started: make(chan struct{}), canceled: make(chan struct{})}
	runner := Runner{
		Client:       &Client{BaseURL: server.URL, Credential: "host-secret", HTTPClient: server.Client(), AllowInsecureLoopback: true},
		Handler:      handler,
		PollInterval: time.Millisecond,
		Log:          &syncBuffer{},
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	result := make(chan error, 1)
	go func() { result <- runner.Run(ctx) }()

	select {
	case <-recovered:
	case err := <-result:
		t.Fatalf("Run ended on a transient failure: %v", err)
	case <-ctx.Done():
		t.Fatal("polling never recovered")
	}
	select {
	case <-handler.started:
	case <-time.After(time.Second):
		t.Fatal("the command was never started")
	}
	select {
	case <-handler.canceled:
		t.Fatal("the outage cancelled a running command")
	default:
	}
	cancel()
	<-result
}

// Revocation that arrives after an outage still ends Run and cancels the work.
func TestRunnerRevokedAfterAnOutageStillEndsRun(t *testing.T) {
	var polls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/v1/chat-host/heartbeat":
			_, _ = w.Write([]byte(`{"host":{"id":"host-1"}}`))
		case "/v1/chat-host/commands":
			switch n := polls.Add(1); {
			case n == 1:
				_, _ = w.Write([]byte(oneCommand))
			case n <= 3:
				w.WriteHeader(http.StatusServiceUnavailable)
			default:
				w.WriteHeader(http.StatusUnauthorized)
			}
		case "/v1/chat-host/events":
			w.WriteHeader(http.StatusAccepted)
			_, _ = w.Write([]byte(`{"accepted":true}`))
		}
	}))
	defer server.Close()

	handler := &blockingHandler{started: make(chan struct{}), canceled: make(chan struct{})}
	runner := Runner{
		Client:       &Client{BaseURL: server.URL, Credential: "host-secret", HTTPClient: server.Client(), AllowInsecureLoopback: true},
		Handler:      handler,
		PollInterval: time.Millisecond,
		Log:          &syncBuffer{},
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := runner.Run(ctx); !errors.Is(err, ErrRevoked) {
		t.Fatalf("runner error=%v want ErrRevoked", err)
	}
	select {
	case <-handler.canceled:
	case <-time.After(time.Second):
		t.Fatal("revocation did not cancel the running command")
	}
}

// A 4xx that is not a revocation is the server refusing this host as it is
// configured; retrying cannot heal it, so Run ends, at startup too.
func TestRunnerEndsOnAClientErrorThatRetryingCannotHeal(t *testing.T) {
	var heartbeats atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		heartbeats.Add(1)
		w.WriteHeader(http.StatusForbidden)
	}))
	defer server.Close()

	runner := Runner{
		Client:       &Client{BaseURL: server.URL, Credential: "host-secret", HTTPClient: server.Client(), AllowInsecureLoopback: true},
		Handler:      emittingHandler{},
		PollInterval: time.Millisecond,
		Log:          &syncBuffer{},
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	err := runner.Run(ctx)
	if err == nil || !strings.Contains(err.Error(), "403") {
		t.Fatalf("runner error=%v want the 403", err)
	}
	if got := heartbeats.Load(); got != 1 {
		t.Fatalf("heartbeats=%d want 1 (no retry)", got)
	}

	// The same holds for a host with no usable configuration.
	runner.Client = &Client{BaseURL: "http://example.test", Credential: "host-secret"}
	if err := runner.Run(ctx); err == nil || !strings.Contains(err.Error(), "must use https") {
		t.Fatalf("runner error=%v want the server URL refusal", err)
	}
}
