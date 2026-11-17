package chathost

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
)

// heartbeatBody posts one heartbeat listing `held` and answers the body the
// server saw.
func heartbeatBody(t *testing.T, held []string) map[string]json.RawMessage {
	t.Helper()
	var body map[string]json.RawMessage
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Errorf("decode heartbeat: %v", err)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"host":{"id":"host-1"}}`))
	}))
	defer server.Close()

	client := &Client{BaseURL: server.URL, Credential: "c", HTTPClient: server.Client(), AllowInsecureLoopback: true}
	if err := client.Heartbeat(context.Background(), map[string]any{}, held); err != nil {
		t.Fatal(err)
	}
	return body
}

func leaseIDs(n int) []string {
	ids := make([]string, n)
	for i := range ids {
		ids[i] = fmt.Sprintf("00000000-0000-4000-8000-%012d", i)
	}
	return ids
}

// The server refuses a heartbeat listing more than MaxHeldLeases ids
// (task-bbb32ae64e56c1e0). Past it the host leaves the list out, so the server
// renews every live lease, as it does for a host older than the key; it never
// sends a cut list, which would let leases it still runs expire.
func TestAHeartbeatOverTheHeldLeaseCapLeavesTheListOut(t *testing.T) {
	body := heartbeatBody(t, leaseIDs(MaxHeldLeases+1))
	if raw, ok := body["held_leases"]; ok {
		t.Fatalf("held_leases sent past the cap (%d bytes)", len(raw))
	}
	if _, ok := body["capabilities"]; !ok {
		t.Fatal("the heartbeat lost its capabilities")
	}
}

func TestAHeartbeatAtTheHeldLeaseCapSendsTheWholeList(t *testing.T) {
	body := heartbeatBody(t, leaseIDs(MaxHeldLeases))
	var held []string
	if err := json.Unmarshal(body["held_leases"], &held); err != nil {
		t.Fatalf("held_leases: %v", err)
	}
	if len(held) != MaxHeldLeases {
		t.Fatalf("sent %d ids, want %d", len(held), MaxHeldLeases)
	}
}
