package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// Discard twin-guard pins (TUI long-tail, 2026-07-16): armDiscard's published-
// twin probe used to collapse a network timeout and a genuine 404 into the
// same "no published twin" copy — misleading, since D then deletes the draft
// outright on the false premise that no twin exists. NotFound and Unreachable
// must render distinct copy; NotFound stays byte-identical to today's.

func TestDiscardTwinStatusMessageDistinguishesNotFoundFromUnreachable(t *testing.T) {
	notFound := discardTwinStatusMessage(apiclient.DocReadNotFound)
	unreachable := discardTwinStatusMessage(apiclient.DocReadUnreachable)

	if notFound == unreachable {
		t.Fatalf("NotFound and Unreachable must render distinct copy, both got %q", notFound)
	}
	if notFound != "no published twin — D deletes the draft outright" {
		t.Errorf("NotFound copy must stay byte-identical to today's, got %q", notFound)
	}
	if strings.Contains(unreachable, "no published twin") {
		t.Errorf("Unreachable must not assert the twin is absent, got %q", unreachable)
	}
}

// TestArmDiscardUnreachableTwinDoesNotClaimNoTwin is the fails-before-fix
// case: an unreachable twin probe (transport error, not a 404) must not arm
// the discard confirm AND must not say "no published twin" — that copy is
// reserved for a genuine 404 (D's job).
func TestArmDiscardUnreachableTwinDoesNotClaimNoTwin(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {}))
	srv.Close() // closed before use: any request now hits connection-refused

	m := model{ds: apiclient.New(apiclient.Config{BaseURL: srv.URL, Token: "t"})}
	doc := &Doc{ID: "drafts.post-1", Status: "draft", Title: "Hello"}
	m.armDiscard(doc, "post")

	if m.discardArmed {
		t.Error("armDiscard must not arm when the twin probe is unreachable")
	}
	if strings.Contains(m.status, "no published twin") {
		t.Errorf("unreachable probe must not claim no published twin, got %q", m.status)
	}
	if !m.statusErr {
		t.Errorf("unreachable probe should render as an error status, got statusErr=%v msg=%q", m.statusErr, m.status)
	}
}
