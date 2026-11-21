package cli

// A landed push whose answer carries no BPML leaves the working copy and its
// anchor as they were, says to pull, and exits non-zero.

import (
	"bytes"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPaperPushAnswerWithoutTextKeepsTheCopyAndExitsNonZero(t *testing.T) {
	fake := &fakePaperServer{rev: "7", noText: true, bpml: "<paper slug=\"p1\" title=\"T\">\n  <p id=\"a\">hello</p>\n</paper>\n"}
	srv := httptest.NewServer(fake.handler())
	defer srv.Close()
	dir, g := paperTestEnv(t, srv.URL)

	var so, se bytes.Buffer
	out := newWriter(&so, &se)
	if code := runPaper(out, g, []string{"pull", "p1"}); code != exitOK {
		t.Fatalf("pull exit = %d; stderr=%s", code, se.String())
	}

	local := filepath.Join(dir, "p1.bpml")
	raw, _ := os.ReadFile(local)
	edited := strings.Replace(string(raw), "hello", "hello edited", 1)
	if err := os.WriteFile(local, []byte(edited), 0o644); err != nil {
		t.Fatal(err)
	}

	if code := runPaper(out, g, []string{"push", "p1"}); code == exitOK {
		t.Fatal("a push answered with no text must not exit 0")
	}
	if got, _ := os.ReadFile(local); string(got) != edited {
		t.Fatalf("working copy changed to %q, want the edited copy kept", got)
	}
	if !strings.Contains(se.String(), "bp paper pull p1") {
		t.Fatalf("push did not say to pull:\n%s", se.String())
	}
	st, err := loadPaperWCState(dir)
	if err != nil {
		t.Fatal(err)
	}
	if st.Papers["p1"].Rev != "7" {
		t.Fatalf("anchor rev = %q, want the pulled 7 kept", st.Papers["p1"].Rev)
	}
}
