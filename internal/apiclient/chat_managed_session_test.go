package apiclient

import (
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

// ManagedChatSession (wsc-steer-open-session-managed): a 200 is the session, the
// server's single indistinct 404 is "no session" (not an error), anything else
// is an error, and the task id reaches the query escaped.
func TestManagedChatSession(t *testing.T) {
	var gotQuery string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotQuery = r.URL.RawQuery
		if r.URL.Path != "/v1/chat/managed-session" {
			w.WriteHeader(http.StatusTeapot)
			return
		}
		switch r.URL.Query().Get("task") {
		case "t-managed":
			_, _ = io.WriteString(w, `{"task_id":"t-managed","session_id":"sess-1"}`)
		case "t-boom":
			w.WriteHeader(http.StatusInternalServerError)
			_, _ = io.WriteString(w, `{"error":{"code":"internal_error"}}`)
		default:
			w.WriteHeader(http.StatusNotFound)
			_, _ = io.WriteString(w, `{"error":{"code":"not_found","message":"no managed session for this task"}}`)
		}
	}))
	defer srv.Close()
	c := newChatClient(srv.URL)

	sid, ok, err := c.ManagedChatSession("t-managed")
	if err != nil || !ok || sid != "sess-1" {
		t.Fatalf("200: got (%q, %v, %v), want (sess-1, true, nil)", sid, ok, err)
	}

	sid, ok, err = c.ManagedChatSession("t-claude")
	if err != nil || ok || sid != "" {
		t.Fatalf("404: got (%q, %v, %v), want (\"\", false, nil) — a miss is not an error", sid, ok, err)
	}

	if _, ok, err = c.ManagedChatSession("t-boom"); err == nil || ok {
		t.Fatalf("500: got (ok=%v, err=%v), want an error", ok, err)
	}

	if _, _, err = c.ManagedChatSession("a&b=c"); err != nil {
		t.Fatalf("escaped id: %v", err)
	}
	if gotQuery != "task=a%26b%3Dc" {
		t.Errorf("task id must be query-escaped, got %q", gotQuery)
	}
}
