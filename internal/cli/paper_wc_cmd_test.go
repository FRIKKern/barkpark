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
	"strconv"
	"strings"
	"testing"
)

type fakePaperServer struct {
	rev       string
	bpml      string
	syncCalls int
	lastBase  string
	lastBpml  string
	// noText plays a server whose applied answer carries no BPML (the
	// reader's view of the paper does not print).
	noText bool
	// notes are the lines every sync answer carries (a kept callout body).
	notes []string
	// view is the fingerprint pull answers (x-bpml-view) and nextView the one
	// an applied sync answers (bpmlView); "" plays a server from before it.
	view     string
	nextView string
	lastView string
	sentView bool
	// carried are the items the pull counts (x-bpml-carried-count) and
	// format=carried names; nil plays a server from before it. carriedView,
	// when set, is the fingerprint the carried read answers instead of view;
	// carriedRev, when set, is the rev it answers instead of rev.
	carried     []map[string]string
	carriedView string
	carriedRev  string
}

func (f *fakePaperServer) handler() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("/papers/", func(w http.ResponseWriter, r *http.Request) {
		format := r.URL.Query().Get("format")
		if !strings.HasSuffix(r.URL.Path, "/source") || (format != "bpml" && format != "carried") {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		w.Header().Set("x-paper-rev", f.rev)
		if f.carried != nil {
			w.Header().Set("x-bpml-carried-count", strconv.Itoa(len(f.carried)))
		}
		if format == "carried" {
			view := f.view
			if f.carriedView != "" {
				view = f.carriedView
			}
			if f.carriedRev != "" {
				w.Header().Set("x-paper-rev", f.carriedRev)
			}
			w.Header().Set("x-bpml-view", view)
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(map[string]any{"count": len(f.carried), "carried": f.carried})
			return
		}
		w.Header().Set("Content-Type", "text/bpml")
		if f.view != "" {
			w.Header().Set("x-bpml-view", f.view)
		}
		_, _ = w.Write([]byte(f.bpml))
	})

	mux.HandleFunc("/v1/plugins/bulldocs/papers/", func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/sync") {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		f.syncCalls++

		var body struct {
			Bpml    string  `json:"bpml"`
			BaseRev string  `json:"baseRev"`
			View    *string `json:"bpmlView"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		f.lastBase = body.BaseRev
		f.lastBpml = body.Bpml
		f.sentView = body.View != nil
		f.lastView = ""
		if body.View != nil {
			f.lastView = *body.View
		}

		w.Header().Set("Content-Type", "application/json")

		switch {
		case body.BaseRev != f.rev:
			w.WriteHeader(http.StatusPreconditionFailed)
			_, _ = w.Write([]byte(`{"error":{"code":"precondition_failed","message":"stale","hint":"bp paper pull to absorb the drift"}}`))

		case strings.Contains(body.Bpml, "<div>"):
			w.WriteHeader(http.StatusUnprocessableEntity)
			_, _ = w.Write([]byte(`{"error":{"code":"bpml","message":"the BPML document did not parse","errors":[{"code":"unknown-tag","message":"unknown tag <div>","line":2,"hint":"group content with <section>"}]}}`))

		case body.Bpml == f.bpml:
			_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "slug": "p1", "unchanged": true, "rev": f.rev, "op_count": 0, "notes": f.notes})

		default:
			// applied: bump the rev, canonicalize (the fake canonical differs
			// from the client's edit so convergence is observable)
			f.rev = f.rev + "0"
			f.bpml = strings.ReplaceAll(body.Bpml, "edited", "edited-canonical")
			answer := map[string]any{"ok": true, "slug": "p1", "rev": f.rev, "op_count": 1, "bpml": f.bpml, "notes": f.notes}
			if f.noText {
				answer["bpml"] = nil
				answer["bpml_unprintable"] = "kind: block"
			}
			if f.nextView != "" {
				answer["bpmlView"] = f.nextView
			}
			_ = json.NewEncoder(w).Encode(answer)
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
