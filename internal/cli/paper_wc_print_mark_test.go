package cli

// The print mark: pull keeps x-bpml-print with the anchor, push sends it back
// as bpmlPrint, and an applied push stores the mark the server answers. A copy
// pulled from a server without the mark sends none, so the server can refuse
// removals that copy may never have shown.

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

func TestPaperPushSendsThePrintMarkItPulled(t *testing.T) {
	fake := &fakePaperServer{rev: "7", mark: "1", bpml: "<paper slug=\"p1\" title=\"T\">\n  <p id=\"a\">hello</p>\n</paper>\n"}
	dir := pullEditPush(t, fake)

	if !fake.sentPrint || fake.lastPrint != "1" {
		t.Fatalf("push sent bpmlPrint=%q (sent=%v), want the pulled mark 1", fake.lastPrint, fake.sentPrint)
	}
	st, err := loadPaperWCState(dir)
	if err != nil {
		t.Fatal(err)
	}
	if got := st.Papers["p1"].Print; got != "1" {
		t.Fatalf("anchor print after push = %q, want the answered mark 1", got)
	}
}

func TestPaperPushFromAnUnmarkedPullSendsNoMark(t *testing.T) {
	fake := &fakePaperServer{rev: "7", bpml: "<paper slug=\"p1\" title=\"T\">\n  <p id=\"a\">hello</p>\n</paper>\n"}
	pullEditPush(t, fake)

	if fake.sentPrint {
		t.Fatalf("push sent bpmlPrint=%q from a copy pulled without a mark", fake.lastPrint)
	}
}
