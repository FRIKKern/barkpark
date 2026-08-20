package cli

// The one-door scaffold (charter D41): `bp paper new` writes a wall-passing
// BPML starter + rev-0 anchor with NO server call — proven by a trap server
// that fails the test on any request — and `bp paper push --check` runs the
// validate dry-run without touching the anchor. The create-on-push CLI leg is
// pinned against a fake sync endpoint that answers the created receipt.

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

// trapServer fails the test on ANY request — the hermeticity proof for the
// local-only scaffold.
func trapServer(t *testing.T) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Errorf("bp paper new must make NO server call; got %s %s", r.Method, r.URL)
		w.WriteHeader(http.StatusTeapot)
	}))
}

func readAnchor(t *testing.T, dir, slug string) paperAnchor {
	t.Helper()
	st, err := loadPaperWCState(dir)
	if err != nil {
		t.Fatalf("state unreadable: %v", err)
	}
	anchor, ok := st.Papers[slug]
	if !ok {
		t.Fatalf("no anchor for %s in %v", slug, st.Papers)
	}
	return anchor
}

func TestPaperNewIsLocalOnlyAndWallShaped(t *testing.T) {
	srv := trapServer(t)
	defer srv.Close()
	dir, g := paperTestEnv(t, srv.URL)

	var so, se bytes.Buffer
	out := newWriter(&so, &se)
	if code := runPaper(out, g, []string{"new", "door-proof"}); code != exitOK {
		t.Fatalf("new exit = %d; stderr=%s", code, se.String())
	}

	raw, err := os.ReadFile(filepath.Join(dir, "door-proof.bpml"))
	if err != nil {
		t.Fatalf("new wrote no working copy: %v", err)
	}
	bpml := string(raw)

	// The wall floor, in the starter's own bytes: title heading, a real
	// paragraph, a ≥20-char description, two REGISTERED placeholder tags with
	// DISTINCT strengths and ≥20-char rationales.
	for _, want := range []string{
		`<paper slug="door-proof" title="Door Proof">`,
		"<meta>",
		"<description>Door Proof: a scaffolded draft",
		`<tag tag="scaffold" strength="60">`,
		`<tag tag="article-draft" strength="40">`,
		`<h1 id="tpl-title">Door Proof</h1>`,
		"<p>Replace this paragraph",
	} {
		if !strings.Contains(bpml, want) {
			t.Errorf("starter missing %q:\n%s", want, bpml)
		}
	}
	if !strings.Contains(bpml, paperStarterRationale) {
		t.Errorf("starter rationale missing (%q):\n%s", paperStarterRationale, bpml)
	}
	if len(paperStarterRationale) < 20 {
		t.Errorf("placeholder rationale under the wall's 20-char floor: %q", paperStarterRationale)
	}
	// The heading is the first body block (after meta) — index order in the file.
	if h, p := strings.Index(bpml, "<h1"), strings.Index(bpml, "<p>"); h == -1 || p == -1 || h > p {
		t.Errorf("h1 must precede the paragraph (h1@%d, p@%d)", h, p)
	}
	// Distinct strengths — a LabelSpine rule the starter must clear.
	if strings.Count(bpml, `strength="60"`) != 1 || strings.Count(bpml, `strength="40"`) != 1 {
		t.Errorf("placeholder tags must carry DISTINCT strengths 60/40:\n%s", bpml)
	}

	// Pristine snapshot exists and matches — diff shows edits vs the starter.
	pristine, err := os.ReadFile(paperWCPristine(dir, "door-proof"))
	if err != nil || string(pristine) != bpml {
		t.Errorf("pristine snapshot missing or diverged: err=%v", err)
	}

	// The rev-0 anchor, unbound to any server (none was called).
	anchor := readAnchor(t, dir, "door-proof")
	if anchor.Rev != "0" {
		t.Errorf("anchor rev = %q, want \"0\"", anchor.Rev)
	}
	if anchor.Server != "" {
		t.Errorf("anchor server = %q, want empty (no server call happened)", anchor.Server)
	}

	// The next-steps teach the registry swap and the validate dry-run — the
	// never-invent-a-tag doctrine at the point of use.
	for _, want := range []string{"bp doc ls tag", "unknown_tag", "--check", "bp paper push door-proof"} {
		if !strings.Contains(so.String(), want) {
			t.Errorf("next-steps missing %q:\n%s", want, so.String())
		}
	}
}

func TestPaperNewVariesTitlePerSlug(t *testing.T) {
	srv := trapServer(t)
	defer srv.Close()
	dir, g := paperTestEnv(t, srv.URL)

	var so, se bytes.Buffer
	out := newWriter(&so, &se)
	for _, slug := range []string{"alpha-one", "beta-two"} {
		if code := runPaper(out, g, []string{"new", slug}); code != exitOK {
			t.Fatalf("new %s exit != 0; stderr=%s", slug, se.String())
		}
	}
	a, _ := os.ReadFile(filepath.Join(dir, "alpha-one.bpml"))
	b, _ := os.ReadFile(filepath.Join(dir, "beta-two.bpml"))
	if !strings.Contains(string(a), `title="Alpha One"`) || !strings.Contains(string(b), `title="Beta Two"`) {
		t.Errorf("titles must derive from the slug (E4 dedup scores title similarity):\n%s\n%s", a, b)
	}
}

func TestPaperNewRefusesOverwriteWithoutForce(t *testing.T) {
	srv := trapServer(t)
	defer srv.Close()
	dir, g := paperTestEnv(t, srv.URL)

	var so, se bytes.Buffer
	out := newWriter(&so, &se)
	if code := runPaper(out, g, []string{"new", "keep-my-edits"}); code != exitOK {
		t.Fatalf("first new failed: %s", se.String())
	}

	path := filepath.Join(dir, "keep-my-edits.bpml")
	edited := "<paper slug=\"keep-my-edits\" title=\"Edited\">\n  <h1>Edited</h1>\n</paper>\n"
	if err := os.WriteFile(path, []byte(edited), 0o644); err != nil {
		t.Fatal(err)
	}

	se.Reset()
	if code := runPaper(out, g, []string{"new", "keep-my-edits"}); code == exitOK {
		t.Fatalf("second new must refuse without --force")
	}
	if !strings.Contains(se.String(), "already exists") {
		t.Errorf("refusal must say the file exists: %s", se.String())
	}
	if raw, _ := os.ReadFile(path); string(raw) != edited {
		t.Errorf("refused overwrite must leave the edit untouched")
	}

	// --force rewrites the starter.
	if code := runPaper(out, g, []string{"new", "keep-my-edits", "--force"}); code != exitOK {
		t.Fatalf("--force new failed: %s", se.String())
	}
	if raw, _ := os.ReadFile(path); !strings.Contains(string(raw), "scaffolded draft") {
		t.Errorf("--force must write a fresh starter")
	}
}

func TestPaperNewRejectsBadSlug(t *testing.T) {
	srv := trapServer(t)
	defer srv.Close()
	_, g := paperTestEnv(t, srv.URL)

	var so, se bytes.Buffer
	out := newWriter(&so, &se)
	for _, bad := range []string{"Has-Caps", "spaced out", "trailing-", "-leading", "double--dash", "dot.slug"} {
		if code := runPaper(out, g, []string{"new", bad}); code != exitUsage {
			t.Errorf("slug %q: exit = %d, want %d", bad, code, exitUsage)
		}
	}
}

// fakeValidateServer answers the validate dry-run and records whether /sync
// was ever touched — --check must be read-only.
type fakeValidateServer struct {
	verdict   string
	syncCalls int
	lastBody  string
}

func (f *fakeValidateServer) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/plugins/bulldocs/papers/validate", func(w http.ResponseWriter, r *http.Request) {
		body, _ := readAll(r)
		f.lastBody = body
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(f.verdict))
	})
	mux.HandleFunc("/v1/plugins/bulldocs/papers/", func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/sync") {
			f.syncCalls++
		}
		w.WriteHeader(http.StatusNotFound)
	})
	return mux
}

func readAll(r *http.Request) (string, error) {
	var b bytes.Buffer
	_, err := b.ReadFrom(r.Body)
	return b.String(), err
}

func TestPaperPushCheckValidExitsZeroAndTouchesNothing(t *testing.T) {
	fake := &fakeValidateServer{verdict: `{"valid":true,"violations":[]}`}
	srv := httptest.NewServer(fake.handler())
	defer srv.Close()
	dir, g := paperTestEnv(t, srv.URL)

	var so, se bytes.Buffer
	out := newWriter(&so, &se)
	if code := runPaper(out, g, []string{"new", "check-me"}); code != exitOK {
		t.Fatalf("new failed: %s", se.String())
	}

	if code := runPaper(out, g, []string{"push", "check-me", "--check"}); code != exitOK {
		t.Fatalf("push --check exit = %d; stderr=%s", code, se.String())
	}
	if !strings.Contains(so.String(), "valid") {
		t.Errorf("verdict not rendered: %s", so.String())
	}
	if fake.syncCalls != 0 {
		t.Errorf("--check must never hit /sync (got %d calls)", fake.syncCalls)
	}
	if !strings.Contains(fake.lastBody, `"bpml"`) {
		t.Errorf("validate body must carry the working copy as bpml: %s", fake.lastBody)
	}
	if anchor := readAnchor(t, dir, "check-me"); anchor.Rev != "0" {
		t.Errorf("--check must not advance the anchor (rev=%q)", anchor.Rev)
	}
}

func TestPaperPushCheckRendersViolationsAndExitsNonzero(t *testing.T) {
	fake := &fakeValidateServer{verdict: `{"valid":false,"violations":[` +
		`{"code":"unknown_tag","message":"tag \"invented\" is not registered","hint":"bp doc ls tag"},` +
		`{"code":"hollow_paper","message":"the paper is a skeleton","hint":"add body blocks"}]}`}
	srv := httptest.NewServer(fake.handler())
	defer srv.Close()
	_, g := paperTestEnv(t, srv.URL)

	var so, se bytes.Buffer
	out := newWriter(&so, &se)
	if code := runPaper(out, g, []string{"new", "refused-draft"}); code != exitOK {
		t.Fatalf("new failed: %s", se.String())
	}
	if code := runPaper(out, g, []string{"push", "refused-draft", "--check"}); code != exitGeneric {
		t.Fatalf("push --check on violations: exit = %d, want %d", code, exitGeneric)
	}
	for _, want := range []string{"unknown_tag", "hollow_paper", "bp doc ls tag", "2 violation(s)"} {
		if !strings.Contains(se.String(), want) {
			t.Errorf("violation render missing %q:\n%s", want, se.String())
		}
	}
}

// The create-on-push CLI leg: a scaffolded (rev-0, server-less) paper pushes
// with baseRev "0"; the server's created receipt converges the file on the
// canonical BPML, advances the anchor, and binds it to the server.
func TestPaperPushCreateFlowFromScaffold(t *testing.T) {
	var gotBase string
	canonical := "<paper slug=\"born-by-push\" title=\"Born By Push\">\n  <h1 id=\"tpl-title\">Born By Push</h1>\n  <p>canonical spelling</p>\n</paper>\n"
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/plugins/bulldocs/papers/", func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/sync") {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		var body struct {
			Bpml    string `json:"bpml"`
			BaseRev string `json:"baseRev"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		gotBase = body.BaseRev
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"ok": true, "slug": "born-by-push", "created": true, "rev": "1", "op_count": 2, "bpml": canonical,
		})
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()
	dir, g := paperTestEnv(t, srv.URL)

	var so, se bytes.Buffer
	out := newWriter(&so, &se)
	if code := runPaper(out, g, []string{"new", "born-by-push"}); code != exitOK {
		t.Fatalf("new failed: %s", se.String())
	}
	if code := runPaper(out, g, []string{"push", "born-by-push"}); code != exitOK {
		t.Fatalf("push exit = %d; stderr=%s", code, se.String())
	}
	if gotBase != "0" {
		t.Errorf("scaffold push must anchor on baseRev \"0\", sent %q", gotBase)
	}
	if raw, _ := os.ReadFile(filepath.Join(dir, "born-by-push.bpml")); string(raw) != canonical {
		t.Errorf("working copy must converge on the server canonical:\n%s", raw)
	}
	anchor := readAnchor(t, dir, "born-by-push")
	if anchor.Rev != "1" {
		t.Errorf("anchor rev = %q, want \"1\"", anchor.Rev)
	}
	if anchor.Server != srv.URL {
		t.Errorf("first landed push must bind the anchor to the server (got %q, want %q)", anchor.Server, srv.URL)
	}
}
