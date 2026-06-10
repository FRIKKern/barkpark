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
