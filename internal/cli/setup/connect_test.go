package setup

import (
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// TestProbeCapabilities401ReturnsUnauthorizedError: a 401 from the server
// surfaces as a *probeError with unauthorized=true so executeConnect can emit
// the token-specific hint instead of the generic reachability hint.
func TestProbeCapabilities401ReturnsUnauthorizedError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	}))
	defer srv.Close()

	_, _, _, err := probeCapabilities(srv.URL, "bad-token")
	if err == nil {
		t.Fatal("expected an error for HTTP 401, got nil")
	}
	probe, ok := err.(*probeError)
	if !ok {
		t.Fatalf("expected *probeError, got %T: %v", err, err)
	}
	if !probe.unauthorized {
		t.Fatalf("expected unauthorized=true for HTTP 401, got false")
	}
}

// TestProbeCapabilitiesClosedPortReturnsGenericError: a connection refusal
// (closed port) surfaces as a plain error — not a *probeError — so
// executeConnect emits the reachability hint instead of the token hint.
func TestProbeCapabilitiesClosedPortReturnsGenericError(t *testing.T) {
	// Grab a free port, close the listener immediately, then probe it.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	addr := ln.Addr().String()
	ln.Close()

	_, _, _, probeErr := probeCapabilities("http://"+addr, "")
	if probeErr == nil {
		t.Fatal("expected an error for closed port, got nil")
	}
	if _, ok := probeErr.(*probeError); ok {
		t.Fatalf("closed-port error must NOT be *probeError, got %T: %v", probeErr, probeErr)
	}
}

// TestExecuteConnect401HintMentionsToken: end-to-end through executeConnect
// against a 401 server — the returned error must contain the token-specific
// hint copy and must NOT contain the reachability hint copy.
func TestExecuteConnect401HintMentionsToken(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	}))
	defer srv.Close()

	err := executeConnect(SetupPlan{Server: srv.URL, Token: "bad"}, Options{})
	if err == nil {
		t.Fatal("expected error for 401, got nil")
	}
	msg := err.Error()
	if !strings.Contains(msg, "rejected the token") {
		t.Fatalf("401 error must mention token rejection, got: %s", msg)
	}
	if strings.Contains(msg, "check the URL is reachable") {
		t.Fatalf("401 error must NOT use the reachability hint, got: %s", msg)
	}
}

// TestExecuteConnectClosedPortHintMentionsReachability: end-to-end through
// executeConnect against a closed port — the returned error must contain the
// reachability hint and must NOT contain the token-rejection hint.
func TestExecuteConnectClosedPortHintMentionsReachability(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	addr := ln.Addr().String()
	ln.Close()

	connErr := executeConnect(SetupPlan{Server: "http://" + addr, Token: ""}, Options{})
	if connErr == nil {
		t.Fatal("expected error for closed port, got nil")
	}
	msg := connErr.Error()
	if !strings.Contains(msg, "check the URL is reachable") {
		t.Fatalf("closed-port error must use reachability hint, got: %s", msg)
	}
	if strings.Contains(msg, "rejected the token") {
		t.Fatalf("closed-port error must NOT mention token rejection, got: %s", msg)
	}
}

// TestExecuteConnectTierNoneWithTokenFails: /v1/capabilities is public, so an
// invalid token never 401s — it resolves to the anonymous tier. When the user
// EXPLICITLY supplied a token, "connected as none" is a failure (every later
// write would 401), and connect must refuse with the token hint. A tokenless
// connect to the same server stays a legitimate anonymous connect.
func TestExecuteConnectTierNoneWithTokenFails(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"auth_tier":"none","manifest_version":"1","server":{"name":"barkpark","version":"0.1.0"},"commands":[]}`))
	}))
	defer srv.Close()

	err := executeConnect(SetupPlan{Server: srv.URL, Token: "stale-token"}, Options{})
	if err == nil {
		t.Fatal("expected error when a supplied token resolves to tier none, got nil")
	}
	if !strings.Contains(err.Error(), "was not accepted") {
		t.Fatalf("error must say the token was not accepted, got: %s", err.Error())
	}

	// Tokenless: anonymous connect to the same server stays legitimate.
	store := &memConfigStore{}
	if err := executeConnect(SetupPlan{Server: srv.URL}, Options{Store: store}); err != nil {
		t.Fatalf("tokenless anonymous connect must succeed, got: %v", err)
	}
	if store.saved == nil || store.saved.Tier != "none" {
		t.Fatalf("anonymous connect must save with the resolved tier, got %+v", store.saved)
	}
}

// memConfigStore is the minimal in-memory ConfigStore for connect tests.
type memConfigStore struct{ saved *SavedConfig }

func (m *memConfigStore) Save(c SavedConfig) error {
	m.saved = &c
	return nil
}
