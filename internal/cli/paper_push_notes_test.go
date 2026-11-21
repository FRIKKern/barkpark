package cli

import (
	"bytes"
	"net/http/httptest"
	"strings"
	"testing"
)

// A push answer's notes (a callout whose stored body the server kept, task
// 4c27) reach the author, one line each, on an unchanged push and an applied one.
func TestPaperPushPrintsTheServersNotes(t *testing.T) {
	note := `callout c1 kept its stored body: the inline form never changes a body; ` +
		`to delete it, take <slot name="body"> out of the structured form`
	fake := &fakePaperServer{
		rev:   "7",
		bpml:  "<paper slug=\"p1\" title=\"T\">\n  <p id=\"a\">hello world</p>\n</paper>\n",
		notes: []string{note},
	}
	srv := httptest.NewServer(fake.handler())
	defer srv.Close()

	_, g := paperTestEnv(t, srv.URL)
	var so, se bytes.Buffer
	out := newWriter(&so, &se)

	if code := runPaper(out, g, []string{"pull", "p1"}); code != exitOK {
		t.Fatalf("pull exit = %d; stderr=%s", code, se.String())
	}

	so.Reset()
	if code := runPaper(out, g, []string{"push", "p1"}); code != exitOK {
		t.Fatalf("push exit = %d; stderr=%s", code, se.String())
	}
	got := so.String()
	if !strings.Contains(got, "p1: "+note) || !strings.Contains(got, "nothing to push") {
		t.Fatalf("unchanged push did not print the note:\n%s", got)
	}
}
