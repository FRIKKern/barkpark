package cli

// The view fingerprint: pull keeps x-bpml-view with the anchor, push sends it
// back as bpmlView, and an applied push stores the fingerprint the server
// answers. A copy pulled from a server without it sends none.

import (
	"bytes"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func pullEditPush(t *testing.T, fake *fakePaperServer) string {
	t.Helper()
	srv := httptest.NewServer(fake.handler())
	t.Cleanup(srv.Close)
	dir, g := paperTestEnv(t, srv.URL)

	var so, se bytes.Buffer
	out := newWriter(&so, &se)
	if code := runPaper(out, g, []string{"pull", "p1"}); code != exitOK {
		t.Fatalf("pull exit = %d; stderr=%s", code, se.String())
	}

	local := filepath.Join(dir, "p1.bpml")
	raw, _ := os.ReadFile(local)
	if err := os.WriteFile(local, []byte(strings.Replace(string(raw), "hello", "hello edited", 1)), 0o644); err != nil {
		t.Fatal(err)
	}
	if code := runPaper(out, g, []string{"push", "p1"}); code != exitOK {
		t.Fatalf("push exit = %d; stderr=%s", code, se.String())
	}
	return dir
}

const viewTestBpml = "<paper slug=\"p1\" title=\"T\">\n  <p id=\"a\">hello</p>\n</paper>\n"

func TestPaperPushSendsTheViewItPulledAndKeepsTheAnsweredOne(t *testing.T) {
	fake := &fakePaperServer{rev: "7", view: "v1", nextView: "v2", bpml: viewTestBpml}
	dir := pullEditPush(t, fake)

	if !fake.sentView || fake.lastView != "v1" {
		t.Fatalf("push sent bpmlView=%q (sent=%v), want the pulled v1", fake.lastView, fake.sentView)
	}
	st, err := loadPaperWCState(dir)
	if err != nil {
		t.Fatal(err)
	}
	if got := st.Papers["p1"].View; got != "v2" {
		t.Fatalf("anchor view after push = %q, want the answered v2", got)
	}
}

func TestPaperPushFromAPullWithoutAViewSendsNone(t *testing.T) {
	fake := &fakePaperServer{rev: "7", bpml: viewTestBpml}
	pullEditPush(t, fake)

	if fake.sentView {
		t.Fatalf("push sent bpmlView=%q from a copy pulled without one", fake.lastView)
	}
}
