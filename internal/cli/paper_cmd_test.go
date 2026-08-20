package cli

import (
	"bytes"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

const (
	cliReleaseGate = "11111111-1111-4111-8111-111111111111"
	cliWaveRev     = "22222222-2222-4222-8222-222222222222"
	cliCandidate   = "33333333-3333-4333-8333-333333333333"
	cliDocument    = "44444444-4444-4444-8444-444444444444"
)

// A mistyped --perspective/--theme/--profile VALUE must be rejected by
// parsePaperArgs rather than captured verbatim — every resolver silently falls
// back (perspective → published, theme → auto, profile → auto), so an unchecked
// typo (e.g. singular "draft") would render the PUBLISHED paper instead of the
// caller's draft. Unknown flag NAMES already error; this covers unknown VALUES.
func TestParsePaperArgsRejectsInvalidValues(t *testing.T) {
	cases := []struct {
		name string
		args []string
		want string // substring the returned error must contain
	}{
		{"perspective typo", []string{"x", "--perspective", "draft"}, "invalid --perspective"},
		{"perspective empty", []string{"x", "--perspective", ""}, "invalid --perspective"},
		{"perspective mixed case", []string{"x", "--perspective", "Published"}, "invalid --perspective"},
		{"theme typo", []string{"x", "--theme", "solarized"}, "invalid --theme"},
		{"theme empty", []string{"x", "--theme", ""}, "invalid --theme"},
		{"profile typo", []string{"x", "--profile", "ansi9000"}, "invalid --profile"},
		{"profile empty", []string{"x", "--profile", ""}, "invalid --profile"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := parsePaperArgs(tc.args)
			if err == nil {
				t.Fatalf("parsePaperArgs(%v) = nil error, want one containing %q", tc.args, tc.want)
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("error = %q, want it to contain %q", err.Error(), tc.want)
			}
		})
	}
}

// Every valid alias the resolvers accept — including the numeric/short spellings
// (16, 256, 24bit), mixed case, and surrounding spaces the ToLower/TrimSpace
// normalization tolerates — must parse clean and round-trip verbatim into the
// parsed struct (the resolver re-normalizes downstream).
func TestParsePaperArgsAcceptsValidValues(t *testing.T) {
	perspectives := []string{"published", "drafts", "raw"}
	for _, v := range perspectives {
		t.Run("perspective/"+v, func(t *testing.T) {
			p, err := parsePaperArgs([]string{"x", "--perspective", v})
			if err != nil {
				t.Fatalf("parsePaperArgs(--perspective %q) = %v, want nil", v, err)
			}
			if p.perspective != v {
				t.Fatalf("perspective = %q, want %q", p.perspective, v)
			}
		})
	}

	themes := []string{"dark", "light", "auto", "Dark", "  light  "}
	for _, v := range themes {
		t.Run("theme/"+v, func(t *testing.T) {
			p, err := parsePaperArgs([]string{"x", "--theme", v})
			if err != nil {
				t.Fatalf("parsePaperArgs(--theme %q) = %v, want nil", v, err)
			}
			if p.theme != v {
				t.Fatalf("theme = %q, want %q (values round-trip verbatim)", p.theme, v)
			}
		})
	}

	profiles := []string{
		"auto", "none", "nocolor", "no-color", "plain",
		"ansi16", "16", "ansi256", "256", "truecolor", "24bit", "rgb",
		"ANSI256", "  truecolor  ",
	}
	for _, v := range profiles {
		t.Run("profile/"+v, func(t *testing.T) {
			p, err := parsePaperArgs([]string{"x", "--profile", v})
			if err != nil {
				t.Fatalf("parsePaperArgs(--profile %q) = %v, want nil", v, err)
			}
			if p.profile != v {
				t.Fatalf("profile = %q, want %q (values round-trip verbatim)", p.profile, v)
			}
		})
	}
}

// A full valid parse round-trips every flag plus the positional slug.
func TestParsePaperArgsFullRoundTrip(t *testing.T) {
	p, err := parsePaperArgs([]string{
		"my-slug",
		"--theme", "dark",
		"--perspective", "drafts",
		"--profile", "truecolor",
		"--width", "120",
		"-s", "prod",
	})
	if err != nil {
		t.Fatalf("parsePaperArgs full = %v, want nil", err)
	}
	if p.slug != "my-slug" {
		t.Fatalf("slug = %q, want %q", p.slug, "my-slug")
	}
	if p.theme != "dark" {
		t.Fatalf("theme = %q, want dark", p.theme)
	}
	if p.perspective != "drafts" {
		t.Fatalf("perspective = %q, want drafts", p.perspective)
	}
	if p.profile != "truecolor" {
		t.Fatalf("profile = %q, want truecolor", p.profile)
	}
	if !p.widthSet || p.width != 120 {
		t.Fatalf("width = %d (set=%v), want 120 (set)", p.width, p.widthSet)
	}
	if p.server != "prod" {
		t.Fatalf("server = %q, want prod", p.server)
	}
}

func TestRunPaperViewUsesImmutableReleasePins(t *testing.T) {
	var requested string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requested = r.URL.RequestURI()
		w.Header().Set("ETag", `"sha256:`+strings.Repeat("b", 64)+`"`)
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-Barkpark-Release-Gate", cliReleaseGate)
		w.Header().Set("X-Barkpark-Wave-Revision", cliWaveRev)
		w.Header().Set("X-Barkpark-Paper-Candidate", cliCandidate)
		w.Header().Set("X-Barkpark-Paper-Role", "successor")
		_, _ = fmt.Fprintf(w, `{"release_gate_id":%q,"wave_revision":%q,"candidate_id":%q,"role":"successor","document_id":%q,"doc_id":"successor-paper","title":"Successor","content_digest":%q,"source":{"kind":"blocks","blocks":[{"type":"paragraph","text":"proof"}]}}`,
			cliReleaseGate, cliWaveRev, cliCandidate, cliDocument, strings.Repeat("b", 64))
	}))
	defer srv.Close()

	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	out.output = "json"
	args := []string{srv.URL + "/w/acme/p/rocket/papers/successor-paper", "--epic-id", "epic-1",
		"--wave-id", "wave-4", "--release-gate-id", cliReleaseGate, "--revision-id", cliWaveRev,
		"--candidate-id", cliCandidate, "--paper-role", "successor"}
	if code := runPaperView(out, globals{outputSet: true}, args); code != exitOK {
		t.Fatalf("runPaperView exit = %d, stderr = %s", code, stderr.String())
	}
	want := "/w/acme/p/rocket/v1/cycles/epic-1/wave-4/release-gates/" + cliReleaseGate + "/papers/successor/source?candidate_id=" + cliCandidate + "&wave_revision=" + cliWaveRev
	if requested != want {
		t.Fatalf("request = %q, want exact immutable route %q", requested, want)
	}
	if !strings.Contains(stdout.String(), `"release_gate_id"`) || !strings.Contains(stdout.String(), cliWaveRev) {
		t.Fatalf("JSON output lost immutable source envelope: %s", stdout.String())
	}
}

func TestRunPaperViewRejectsPartialReleasePins(t *testing.T) {
	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	code := runPaperView(out, globals{}, []string{"paper", "--release-gate-id", cliReleaseGate})
	if code == exitOK || !strings.Contains(stderr.String(), "--epic-id is required") {
		t.Fatalf("partial release pins exit=%d stderr=%q", code, stderr.String())
	}
}

func TestNormalizePaperRef(t *testing.T) {
	cases := map[string]string{
		"paper-id":          "paper-id",
		"/papers/paper-id":  "paper-id",
		"/papers/paper-id/": "paper-id",
		"https://guerrilla.barkpark.cloud/papers/paper-id?view=tui#top":                           "paper-id",
		"https://guerrilla.barkpark.cloud/w/default/p/default/d/production/studio/paper/paper-id": "paper-id",
		"https://guerrilla.barkpark.cloud/w/default/p/default/papers/scoped-id":                   "scoped-id",
		"/papers/id%20with%20spaces": "id with spaces",
	}
	for input, want := range cases {
		if got := normalizePaperRef(input); got != want {
			t.Errorf("normalizePaperRef(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestParsePaperRefPreservesURLContext(t *testing.T) {
	got := parsePaperRef("https://guerrilla.barkpark.cloud/w/acme/p/rocket/d/staging/studio/paper/launch-plan")
	want := paperRef{
		id: "launch-plan", server: "https://guerrilla.barkpark.cloud",
		workspace: "acme", project: "rocket", dataset: "staging",
		browserPath: "/w/acme/p/rocket/d/staging/studio/paper/launch-plan",
	}
	if got != want {
		t.Fatalf("parsePaperRef context = %#v, want %#v", got, want)
	}

	got = parsePaperRef("https://guerrilla.barkpark.cloud/w/acme/p/rocket/papers/launch-plan")
	if got.server != "https://guerrilla.barkpark.cloud" || got.workspace != "acme" || got.project != "rocket" || got.dataset != "production" || got.id != "launch-plan" {
		t.Fatalf("scoped public Paper URL context lost: %#v", got)
	}

	got = parsePaperRef("https://guerrilla.barkpark.cloud/papers/launch-plan")
	if got.workspace != "default" || got.project != "default" || got.dataset != "production" {
		t.Fatalf("unscoped public Paper URL did not reset to its canonical tenant: %#v", got)
	}
}

func TestRunPaperViewUsesPastedURLOriginAndTenantPath(t *testing.T) {
	var requested string
	var authorization string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requested = r.URL.RequestURI()
		authorization = r.Header.Get("Authorization")
		w.Header().Set("content-type", "application/json")
		_, _ = w.Write([]byte(`{"result":{"_id":"launch-plan","_type":"paper","title":"Launch","blocks":[],"custom":"preserved"}}`))
	}))
	defer srv.Close()

	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "json"
	url := srv.URL + "/w/acme/p/rocket/d/staging/studio/paper/launch-plan"
	code := runPaperView(w, globals{outputSet: true}, []string{url})
	if code != exitOK {
		t.Fatalf("runPaperView exit = %d, stderr = %s", code, stderr.String())
	}
	wantPath := "/w/acme/p/rocket/v1/data/doc/staging/paper/launch-plan"
	if !strings.HasPrefix(requested, wantPath+"?") {
		t.Fatalf("request URI = %q, want prefix %q", requested, wantPath+"?")
	}
	if !strings.Contains(requested, "perspective=published") || !strings.Contains(requested, "resolve=tasks") {
		t.Fatalf("request URI missing reader query contract: %q", requested)
	}
	if authorization != "" {
		t.Fatalf("unknown pasted origin received active Authorization header %q", authorization)
	}
	if !strings.Contains(stdout.String(), `"custom":"preserved"`) {
		t.Fatalf("raw PaperDoc field lost from json output: %s", stdout.String())
	}
}

func TestRunPaperViewPreservesItemShareWithoutBearer(t *testing.T) {
	var requested, authorization, accept string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requested = r.URL.RequestURI()
		authorization = r.Header.Get("Authorization")
		accept = r.Header.Get("Accept")
		w.Header().Set("content-type", "application/json")
		_, _ = w.Write([]byte(`{"title":"Shared","source":{"kind":"blocks","blocks":[]}}`))
	}))
	defer srv.Close()

	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.output = "json"
	shared := srv.URL + "/w/acme/p/rocket/papers/shared-plan?share=cap-secret"
	if code := runPaperView(w, globals{outputSet: true}, []string{shared}); code != exitOK {
		t.Fatalf("runPaperView exit = %d, stderr = %s", code, stderr.String())
	}
	if requested != "/w/acme/p/rocket/papers/shared-plan/source?share=cap-secret" {
		t.Fatalf("share request URI = %q", requested)
	}
	if authorization != "" {
		t.Fatalf("share request received Authorization header %q", authorization)
	}
	if accept != "*/*" {
		t.Fatalf("share request Accept = %q, want */*", accept)
	}
}

func TestRunPaperViewFailsClosedOnCanonicalSourceRejection(t *testing.T) {
	for _, code := range []string{"semantic_empty", "ambiguous_source"} {
		t.Run(code, func(t *testing.T) {
			var requested string
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				requested = r.URL.RequestURI()
				w.Header().Set("content-type", "application/json")
				w.WriteHeader(http.StatusUnprocessableEntity)
				_, _ = w.Write([]byte(`{"error":{"code":"` + code + `"}}`))
			}))
			defer srv.Close()

			var stdout, stderr bytes.Buffer
			out := newWriter(&stdout, &stderr)
			got := runPaperView(out, globals{}, []string{srv.URL + "/papers/rejected", "--profile", "none"})
			if got == exitOK {
				t.Fatalf("runPaperView returned success for %s; stdout=%q", code, stdout.String())
			}
			if !strings.HasPrefix(requested, "/d/production/papers/rejected/source?") ||
				!strings.Contains(requested, "perspective=published") {
				t.Fatalf("request URI = %q, want canonical dataset source endpoint", requested)
			}
			if !strings.Contains(stderr.String(), "status 422") {
				t.Fatalf("stderr = %q, want explicit 422 source rejection", stderr.String())
			}
		})
	}
}
