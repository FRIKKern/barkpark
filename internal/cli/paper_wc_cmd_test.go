package cli

// The working-copy loop against a fake server: pull anchors, edit, push
// converges on canonical — and every refusal (stale anchor, teaching errors)
// renders the server's own words. The fake mirrors the real wire shapes:
// GET /papers/:slug/source?format=bpml (+x-paper-rev) and
// POST /v1/plugins/bulldocs/papers/:slug/sync.

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type fakePaperServer struct {
	rev       string
	bpml      string
	syncCalls int
	lastBase  string
	lastBpml  string
}

func (f *fakePaperServer) handler() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("/papers/", func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/source") || r.URL.Query().Get("format") != "bpml" {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", "text/bpml")
		w.Header().Set("x-paper-rev", f.rev)
		_, _ = w.Write([]byte(f.bpml))
	})

	mux.HandleFunc("/v1/plugins/bulldocs/papers/", func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/sync") {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		f.syncCalls++

		var body struct {
			Bpml    string `json:"bpml"`
			BaseRev string `json:"baseRev"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		f.lastBase = body.BaseRev
		f.lastBpml = body.Bpml

		w.Header().Set("Content-Type", "application/json")

		switch {
		case body.BaseRev != f.rev:
			w.WriteHeader(http.StatusPreconditionFailed)
			_, _ = w.Write([]byte(`{"error":{"code":"precondition_failed","message":"stale","hint":"bp paper pull to absorb the drift"}}`))

		case strings.Contains(body.Bpml, "<div>"):
			w.WriteHeader(http.StatusUnprocessableEntity)
			_, _ = w.Write([]byte(`{"error":{"code":"bpml","message":"the BPML document did not parse","errors":[{"code":"unknown-tag","message":"unknown tag <div>","line":2,"hint":"group content with <section>"}]}}`))

		case body.Bpml == f.bpml:
			_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "slug": "p1", "unchanged": true, "rev": f.rev, "op_count": 0})

		default:
			// applied: bump the rev, canonicalize (the fake canonical differs
			// from the client's edit so convergence is observable)
			f.rev = f.rev + "0"
			f.bpml = strings.ReplaceAll(body.Bpml, "edited", "edited-canonical")
			_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "slug": "p1", "rev": f.rev, "op_count": 1, "bpml": f.bpml})
		}
	})

	return mux
}

func paperTestEnv(t *testing.T, srvURL string) (dir string, g globals) {
	t.Helper()
	dir = t.TempDir()
	t.Setenv("BARKPARK_PAPER_DIR", dir)
	return dir, globals{server: srvURL}
}

func TestPaperPullEditPushConverges(t *testing.T) {
	fake := &fakePaperServer{rev: "7", bpml: "<paper slug=\"p1\" title=\"T\">\n  <p id=\"a\">hello world</p>\n</paper>\n"}
	srv := httptest.NewServer(fake.handler())
	defer srv.Close()

	dir, g := paperTestEnv(t, srv.URL)

	var so, se bytes.Buffer
	out := newWriter(&so, &se)

	if code := runPaper(out, g, []string{"pull", "p1"}); code != exitOK {
		t.Fatalf("pull exit = %d; stderr=%s", code, se.String())
	}

	// pull wrote file + pristine + anchor
	local := filepath.Join(dir, "p1.bpml")
	raw, err := os.ReadFile(local)
	if err != nil {
		t.Fatalf("pull wrote no file: %v", err)
	}
	if !strings.Contains(string(raw), "hello world") {
		t.Fatalf("pulled content wrong: %q", raw)
	}

	// edit the file
	edited := strings.Replace(string(raw), "hello world", "hello edited", 1)
	if err := os.WriteFile(local, []byte(edited), 0o644); err != nil {
		t.Fatal(err)
	}

	// diff shows the edit
	so.Reset()
	if code := runPaper(out, g, []string{"diff", "p1"}); code != exitOK {
		t.Fatalf("diff exit = %d; stderr=%s", code, se.String())
	}
	if !strings.Contains(so.String(), "+ ") || !strings.Contains(so.String(), "hello edited") {
		t.Fatalf("diff did not show the edit:\n%s", so.String())
	}

	// push applies, file converges on the server's canonical
	so.Reset()
	if code := runPaper(out, g, []string{"push", "p1"}); code != exitOK {
		t.Fatalf("push exit = %d; stderr=%s", code, se.String())
	}
	if fake.lastBase != "7" {
		t.Fatalf("push anchored on %q, want 7", fake.lastBase)
	}
	converged, _ := os.ReadFile(local)
	if !strings.Contains(string(converged), "edited-canonical") {
		t.Fatalf("file did not converge on canonical:\n%s", converged)
	}

	// state advanced to the new rev; a second push is a no-op
	so.Reset()
	if code := runPaper(out, g, []string{"push", "p1"}); code != exitOK {
		t.Fatalf("second push exit = %d; stderr=%s", code, se.String())
	}
	if !strings.Contains(so.String(), "nothing to push") {
		t.Fatalf("second push not a no-op:\n%s", so.String())
	}
	if fake.syncCalls != 2 {
		t.Fatalf("sync calls = %d, want 2", fake.syncCalls)
	}
}

func TestPaperPushStaleAnchorTeachesPullFirst(t *testing.T) {
	fake := &fakePaperServer{rev: "7", bpml: "<paper slug=\"p1\" title=\"T\">\n  <p id=\"a\">x</p>\n</paper>\n"}
	srv := httptest.NewServer(fake.handler())
	defer srv.Close()

	dir, g := paperTestEnv(t, srv.URL)

	var so, se bytes.Buffer
	out := newWriter(&so, &se)

	if code := runPaper(out, g, []string{"pull", "p1"}); code != exitOK {
		t.Fatalf("pull exit = %d; stderr=%s", code, se.String())
	}

	// someone else moved the server
	fake.rev = "9"

	local := filepath.Join(dir, "p1.bpml")
	raw, _ := os.ReadFile(local)
	_ = os.WriteFile(local, []byte(strings.Replace(string(raw), "x", "y", 1)), 0o644)

	if code := runPaper(out, g, []string{"push", "p1"}); code == exitOK {
		t.Fatal("stale push must not exit 0")
	}
	if !strings.Contains(se.String(), "precondition_failed") || !strings.Contains(se.String(), "pull") {
		t.Fatalf("stale push did not teach pull-first:\n%s", se.String())
	}
}

func TestPaperPushBrokenEditRendersTeachingErrors(t *testing.T) {
	fake := &fakePaperServer{rev: "7", bpml: "<paper slug=\"p1\" title=\"T\">\n  <p id=\"a\">x</p>\n</paper>\n"}
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
	_ = os.WriteFile(local, []byte(strings.Replace(string(raw), "<p id=\"a\">x</p>", "<div>x</div>", 1)), 0o644)

	if code := runPaper(out, g, []string{"push", "p1"}); code == exitOK {
		t.Fatal("broken push must not exit 0")
	}
	if !strings.Contains(se.String(), "line 2") || !strings.Contains(se.String(), "<section>") {
		t.Fatalf("teaching errors not rendered with line + hint:\n%s", se.String())
	}
}

func TestPaperPushWithoutPullTeaches(t *testing.T) {
	srv := httptest.NewServer((&fakePaperServer{rev: "1", bpml: "x"}).handler())
	defer srv.Close()
	_, g := paperTestEnv(t, srv.URL)

	var so, se bytes.Buffer
	out := newWriter(&so, &se)

	if code := runPaper(out, g, []string{"push", "nope"}); code == exitOK {
		t.Fatal("push without a working copy must not exit 0")
	}
	if !strings.Contains(se.String(), "pull") {
		t.Fatalf("missing pull-first hint:\n%s", se.String())
	}
}

func TestPaperStatusReportsEditedAndBehind(t *testing.T) {
	fake := &fakePaperServer{rev: "7", bpml: "<paper slug=\"p1\" title=\"T\">\n  <p id=\"a\">x</p>\n</paper>\n"}
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
	_ = os.WriteFile(local, []byte(string(raw)+"\n"), 0o644)
	fake.rev = "9"

	so.Reset()
	if code := runPaper(out, g, []string{"status"}); code != exitOK {
		t.Fatalf("status exit = %d; stderr=%s", code, se.String())
	}
	got := so.String()
	if !strings.Contains(got, "edited") || !strings.Contains(got, "behind") {
		t.Fatalf("status missed edited/behind:\n%s", got)
	}
}
