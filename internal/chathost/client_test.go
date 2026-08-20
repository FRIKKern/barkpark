package chathost

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestClientAuthenticatedLifecycle(t *testing.T) {
	var sawEvent bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/chat-host/enroll" && r.Header.Get("Authorization") != "Host host-secret" {
			t.Fatalf("missing host authentication on %s", r.URL.Path)
		}
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/v1/chat-host/enroll":
			_, _ = w.Write([]byte(`{"host":{"id":"host-1","workspace_id":"ws-1","name":"laptop","approved_roots":["/tmp"],"protocol_version":1,"capabilities":{}},"credential":"host-secret"}`))
		case "/v1/chat-host/heartbeat":
			_, _ = w.Write([]byte(`{"host":{"id":"host-1"}}`))
		case "/v1/chat-host/commands":
			_, _ = w.Write([]byte(`{"commands":[{"lease_id":"lease-1","epoch":4,"command":{"provider":"claude"}}]}`))
		case "/v1/chat-host/events":
			sawEvent = true
			w.WriteHeader(http.StatusAccepted)
			_, _ = w.Write([]byte(`{"accepted":true}`))
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	client := &Client{BaseURL: server.URL, HTTPClient: server.Client(), AllowInsecureLoopback: true}
	result, err := client.Enroll(context.Background(), "one-time", []string{"/tmp"}, map[string]any{"providers": map[string]any{}})
	if err != nil {
		t.Fatal(err)
	}
	client.Credential = result.Credential
	if err := client.Heartbeat(context.Background(), map[string]any{}); err != nil {
		t.Fatal(err)
	}
	commands, err := client.Commands(context.Background())
	if err != nil || len(commands) != 1 {
		t.Fatalf("commands=%v err=%v", commands, err)
	}
	if err := client.Publish(context.Background(), commands[0], 1, "event-1", map[string]any{"kind": "terminal"}); err != nil {
		t.Fatal(err)
	}
	if !sawEvent {
		t.Fatal("event was not published")
	}
}

func TestClientTreatsUnauthorizedAsRevocation(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	}))
	defer server.Close()

	client := &Client{BaseURL: server.URL, Credential: "revoked", HTTPClient: server.Client(), AllowInsecureLoopback: true}
	if err := client.Heartbeat(context.Background(), nil); !errors.Is(err, ErrRevoked) {
		t.Fatalf("got %v want ErrRevoked", err)
	}
}

func TestClientRejectsPlaintextRemoteServer(t *testing.T) {
	client := &Client{BaseURL: "http://example.test", Credential: "secret"}
	if err := client.Heartbeat(context.Background(), nil); err == nil || !strings.Contains(err.Error(), "must use https") {
		t.Fatalf("expected TLS validation error, got %v", err)
	}
}

func TestStateIsStoredWithOwnerOnlyPermissions(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nested", "host.json")
	state := State{ServerURL: "https://example.test", Credential: "secret", Host: HostInfo{ID: "host-1"}}
	if err := SaveState(path, state); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != 0o600 {
		t.Fatalf("mode=%#o want 0600", got)
	}
	loaded, err := LoadState(path)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.Credential != state.Credential {
		t.Fatal("credential did not round-trip")
	}
}

type blockingHandler struct {
	started  chan struct{}
	canceled chan struct{}
	once     sync.Once
}

type emittingHandler struct{}

type cancelOnlyHandler struct {
	started  chan struct{}
	canceled chan struct{}
}

func (emittingHandler) Handle(_ context.Context, _ RemoteCommand, emit func(map[string]any) error) error {
	return emit(map[string]any{"kind": "terminal", "terminal_state": "completed"})
}

func (h *cancelOnlyHandler) Handle(ctx context.Context, _ RemoteCommand, _ func(map[string]any) error) error {
	close(h.started)
	<-ctx.Done()
	close(h.canceled)
	return nil
}

func (h *blockingHandler) Handle(ctx context.Context, _ RemoteCommand, _ func(map[string]any) error) error {
	h.once.Do(func() { close(h.started) })
	<-ctx.Done()
	close(h.canceled)
	return ctx.Err()
}

func TestRunnerCancelsProviderWorkWhenCredentialIsRevoked(t *testing.T) {
	var heartbeats atomic.Int32
	var commandSent atomic.Bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/v1/chat-host/heartbeat":
			if heartbeats.Add(1) > 1 {
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			_, _ = w.Write([]byte(`{"host":{"id":"host-1"}}`))
		case "/v1/chat-host/commands":
			if commandSent.CompareAndSwap(false, true) {
				_, _ = w.Write([]byte(`{"commands":[{"lease_id":"lease-1","epoch":1,"last_cursor":0,"command":{"provider":"claude"}}]}`))
			} else {
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
		Client:            &Client{BaseURL: server.URL, Credential: "host-secret", HTTPClient: server.Client(), AllowInsecureLoopback: true},
		Handler:           handler,
		PollInterval:      time.Millisecond,
		HeartbeatInterval: 20 * time.Millisecond,
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	result := make(chan error, 1)
	go func() { result <- runner.Run(ctx) }()

	select {
	case <-handler.started:
	case <-ctx.Done():
		t.Fatal("provider work did not start")
	}
	if err := <-result; !errors.Is(err, ErrRevoked) {
		t.Fatalf("runner error=%v want ErrRevoked", err)
	}
	select {
	case <-handler.canceled:
	case <-time.After(time.Second):
		t.Fatal("provider process context was not cancelled")
	}
}

func TestRunnerInterruptCancelsActiveSession(t *testing.T) {
	handler := &cancelOnlyHandler{started: make(chan struct{}), canceled: make(chan struct{})}
	runner := Runner{
		Handler: handler,
		active:  make(map[string]activeCommand),
	}

	runner.start(context.Background(), RemoteCommand{
		LeaseID: "turn-lease",
		Command: map[string]any{
			"operation":  "send_turn",
			"session_id": "session-1",
		},
	})
	select {
	case <-handler.started:
	case <-time.After(time.Second):
		t.Fatal("provider work did not start")
	}

	runner.cancelSession("session-1")
	select {
	case <-handler.canceled:
	case <-time.After(time.Second):
		t.Fatal("interrupt did not cancel active session")
	}
}

func TestRunnerPublishesInterruptedTerminalAfterCancel(t *testing.T) {
	event := make(chan map[string]any, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var payload struct {
			Event map[string]any `json:"event"`
		}
		if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
			t.Fatal(err)
		}
		event <- payload.Event
		w.WriteHeader(http.StatusAccepted)
		_, _ = w.Write([]byte(`{"accepted":true}`))
	}))
	defer server.Close()

	handler := &blockingHandler{started: make(chan struct{}), canceled: make(chan struct{})}
	runner := Runner{
		Client:  &Client{BaseURL: server.URL, Credential: "host-secret", HTTPClient: server.Client(), AllowInsecureLoopback: true},
		Handler: handler,
		active:  make(map[string]activeCommand),
	}
	runner.start(context.Background(), RemoteCommand{
		LeaseID: "turn-lease",
		Epoch:   1,
		Command: map[string]any{"operation": "send_turn", "session_id": "session-1"},
	})
	<-handler.started
	runner.cancelSession("session-1")

	select {
	case got := <-event:
		if got["kind"] != "terminal" || got["terminal_state"] != "interrupted" {
			t.Fatalf("unexpected terminal event: %#v", got)
		}
	case <-time.After(time.Second):
		t.Fatal("interrupted terminal event was not published")
	}
}

func TestRunnerResumesEventCursorAfterReconnect(t *testing.T) {
	var commandSent atomic.Bool
	cursorSeen := make(chan uint64, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/v1/chat-host/heartbeat":
			_, _ = w.Write([]byte(`{"host":{"id":"host-1"}}`))
		case "/v1/chat-host/commands":
			if commandSent.CompareAndSwap(false, true) {
				_, _ = w.Write([]byte(`{"commands":[{"lease_id":"lease-1","epoch":3,"last_cursor":5,"command":{"provider":"claude"}}]}`))
			} else {
				_, _ = w.Write([]byte(`{"commands":[]}`))
			}
		case "/v1/chat-host/events":
			var payload struct {
				Cursor uint64 `json:"cursor"`
			}
			if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
				t.Fatal(err)
			}
			cursorSeen <- payload.Cursor
			w.WriteHeader(http.StatusAccepted)
			_, _ = w.Write([]byte(`{"accepted":true}`))
		}
	}))
	defer server.Close()

	ctx, cancel := context.WithCancel(context.Background())
	runner := Runner{
		Client:       &Client{BaseURL: server.URL, Credential: "host-secret", HTTPClient: server.Client(), AllowInsecureLoopback: true},
		Handler:      emittingHandler{},
		PollInterval: time.Millisecond,
	}
	result := make(chan error, 1)
	go func() { result <- runner.Run(ctx) }()

	select {
	case cursor := <-cursorSeen:
		if cursor != 6 {
			t.Fatalf("cursor=%d want 6", cursor)
		}
		cancel()
	case <-time.After(time.Second):
		cancel()
		t.Fatal("reconnect event was not published")
	}
	<-result
}
