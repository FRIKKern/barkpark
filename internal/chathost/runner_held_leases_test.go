package chathost

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// gatedTurnHandler starts a turn, says so on started, and closes it only once
// release is closed.
type gatedTurnHandler struct {
	started chan struct{}
	release chan struct{}
}

func (h *gatedTurnHandler) Handle(ctx context.Context, _ RemoteCommand, emit func(map[string]any) error) error {
	if err := emit(map[string]any{"kind": "turn_started"}); err != nil {
		return err
	}
	close(h.started)
	select {
	case <-h.release:
	case <-ctx.Done():
		return ctx.Err()
	}
	return emit(map[string]any{"kind": "turn_completed", "terminal_state": "completed"})
}

// waitHeldList waits for a heartbeat after the first from heldLists to carry
// want. It reports whether one did before ctx ended, and the lists so far.
func waitHeldList(ctx context.Context, server *leaseServer, from int, want string) (bool, []string) {
	for {
		lists := heldListsOf(server)
		for i := from; i < len(lists); i++ {
			if lists[i] == want {
				return true, lists
			}
		}
		select {
		case <-ctx.Done():
			return false, lists
		case <-time.After(time.Millisecond):
		}
	}
}

// lastLists is the last few of lists, for a failure message.
func lastLists(lists []string) []string {
	return lists[max(0, len(lists)-5):]
}

func heldListsOf(server *leaseServer) []string {
	server.mu.Lock()
	defer server.mu.Unlock()
	return append([]string(nil), server.heldLists...)
}

// Each heartbeat lists the leases this process still runs, and a lease leaves
// the list once its run, close included, has ended. The server renews only
// the listed running leases, so one the host gave up on is closed by the
// server's expiry sweep instead of staying working while the host heartbeats
// (task-e8a91dd731695004).
func TestTheHeartbeatListsTheLeasesTheRunnerStillHolds(t *testing.T) {
	server := &leaseServer{heartbeatEvery: 5 * time.Millisecond, runFor: 20 * time.Second}
	handler := &gatedTurnHandler{started: make(chan struct{}), release: make(chan struct{})}
	ctx, stop := startRunner(t, server, handler)
	defer stop()

	select {
	case <-handler.started:
	case <-ctx.Done():
		t.Fatal("the turn never started")
	}
	if ok, lists := waitHeldList(ctx, server, len(heldListsOf(server)), "[lease-1]"); !ok {
		t.Fatalf("no heartbeat while the turn ran listed its lease; last lists: %v", lastLists(lists))
	}

	close(handler.release)
	if !waitCompleted(ctx, server) {
		t.Fatal("the turn was never closed")
	}
	if ok, lists := waitHeldList(ctx, server, len(heldListsOf(server)), "[]"); !ok {
		t.Fatalf("no heartbeat after the lease's close listed none; last lists: %v", lastLists(lists))
	}
}

// A heartbeat with nothing held sends an empty list, not null: null is what a
// host older than the key sends, and the server renews every lease for it.
func TestAHeartbeatHoldingNothingSendsAnEmptyList(t *testing.T) {
	bodies := make(chan map[string]any, 1)
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		var body map[string]any
		_ = json.Unmarshal(raw, &body)
		bodies <- body
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"host":{"id":"host-1"}}`))
	}))
	defer ts.Close()

	client := &Client{BaseURL: ts.URL, Credential: "host-secret", HTTPClient: ts.Client(), AllowInsecureLoopback: true}
	if err := client.Heartbeat(context.Background(), map[string]any{}, nil); err != nil {
		t.Fatal(err)
	}
	held, ok := (<-bodies)["held_leases"].([]any)
	if !ok || len(held) != 0 {
		t.Fatalf("held_leases = %#v; want []", held)
	}
}
