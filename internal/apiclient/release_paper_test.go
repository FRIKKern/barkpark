package apiclient

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

const (
	testReleaseGate = "11111111-1111-4111-8111-111111111111"
	testWaveRev     = "22222222-2222-4222-8222-222222222222"
	testCandidate   = "33333333-3333-4333-8333-333333333333"
	testDocument    = "44444444-4444-4444-8444-444444444444"
)

func releasePaperResponse(w http.ResponseWriter, gate, revision string) {
	releasePaperResponseWithRevisionHeader(w, gate, revision, revision)
}

func releasePaperResponseWithRevisionHeader(w http.ResponseWriter, gate, revision, headerRevision string) {
	if w.Header().Get("Content-Type") == "" {
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
	}
	w.Header().Set("ETag", `"sha256:`+strings.Repeat("b", 64)+`"`)
	w.Header().Set("X-Barkpark-Release-Gate", gate)
	w.Header().Set("X-Barkpark-Wave-Revision", headerRevision)
	w.Header().Set("X-Barkpark-Paper-Candidate", testCandidate)
	w.Header().Set("X-Barkpark-Paper-Role", "campaign")
	_, _ = w.Write([]byte(`{"release_gate_id":"` + gate + `","wave_revision":"` + revision +
		`","candidate_id":"` + testCandidate + `","role":"campaign","document_id":"` + testDocument +
		`","doc_id":"campaign-paper","title":"Campaign","content_digest":"` + strings.Repeat("b", 64) +
		`","source":{"kind":"blocks","blocks":[{"type":"paragraph","text":"proof"}]}}`))
}

func TestPaperReleaseSourceRejectsDriftedRevisionHeader(t *testing.T) {
	drifted := "55555555-5555-4555-8555-555555555555"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		releasePaperResponseWithRevisionHeader(w, testReleaseGate, testWaveRev, drifted)
	}))
	defer srv.Close()
	c := New(Config{BaseURL: srv.URL, Workspace: "acme", Project: "rocket"})
	ref := ReleasePaperRef{EpicID: "epic", WaveID: "wave", ReleaseGateID: testReleaseGate,
		RevisionID: testWaveRev, CandidateID: testCandidate, Role: "campaign"}
	if _, err := c.PaperReleaseSource(ref); err == nil || !strings.Contains(err.Error(), "pin headers") {
		t.Fatalf("drifted Wave revision header error = %v", err)
	}
}

func TestPaperReleaseSourcePinsRequestPathScopeAndHeaders(t *testing.T) {
	var seen url.URL
	var auth string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen = *r.URL
		auth = r.Header.Get("Authorization")
		releasePaperResponse(w, testReleaseGate, testWaveRev)
	}))
	defer srv.Close()
	c := New(Config{BaseURL: srv.URL, Token: "token", Workspace: "acme", Project: "rocket"})
	ref := ReleasePaperRef{EpicID: "epic-one", WaveID: "wave-next", ReleaseGateID: testReleaseGate,
		RevisionID: testWaveRev, CandidateID: testCandidate, Role: "campaign"}

	got, err := c.PaperReleaseSource(ref)
	if err != nil {
		t.Fatalf("PaperReleaseSource: %v", err)
	}
	wantPath := "/w/acme/p/rocket/v1/cycles/epic-one/wave-next/release-gates/" + testReleaseGate + "/papers/campaign/source"
	if seen.Path != wantPath || seen.Query().Get("wave_revision") != testWaveRev ||
		seen.Query().Get("candidate_id") != testCandidate || len(seen.Query()) != 2 {
		t.Fatalf("request = %q, want path %q with exact revision and candidate pins", seen.RequestURI(), wantPath)
	}
	if auth != "Bearer token" {
		t.Fatalf("Authorization = %q", auth)
	}
	if got.DocID != "campaign-paper" || got.Rev != testCandidate || string(got.Raw) == "" {
		t.Fatalf("release source lost immutable identity/raw bytes: %+v", got)
	}
}

func TestPaperReleaseSourceRejectsOriginScopeAndRedirectFallback(t *testing.T) {
	c := New(Config{BaseURL: "https://api.example", Workspace: "acme", Project: "rocket"})
	base := ReleasePaperRef{Origin: "https://api.example", Workspace: "acme", Project: "rocket",
		EpicID: "epic", WaveID: "wave", ReleaseGateID: testReleaseGate, RevisionID: testWaveRev,
		CandidateID: testCandidate, Role: "campaign"}
	for name, mutate := range map[string]func(*ReleasePaperRef){
		"origin":    func(r *ReleasePaperRef) { r.Origin = "https://other.example" },
		"workspace": func(r *ReleasePaperRef) { r.Workspace = "other" },
		"project":   func(r *ReleasePaperRef) { r.Project = "other" },
	} {
		t.Run(name, func(t *testing.T) {
			ref := base
			mutate(&ref)
			if _, err := c.PaperReleaseSource(ref); err == nil {
				t.Fatal("scope/origin drift was accepted")
			}
		})
	}

	redirectTargetHit := false
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		redirectTargetHit = true
		releasePaperResponse(w, testReleaseGate, testWaveRev)
	}))
	defer target.Close()
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, target.URL+r.URL.RequestURI(), http.StatusTemporaryRedirect)
	}))
	defer origin.Close()
	redirectClient := New(Config{BaseURL: origin.URL, Workspace: "acme", Project: "rocket"})
	base.Origin = ""
	if _, err := redirectClient.PaperReleaseSource(base); err == nil {
		t.Fatal("redirected release read was accepted")
	}
	if redirectTargetHit {
		t.Fatal("release read followed redirect to alternate origin")
	}
}

func TestPaperReleaseSourceFailsClosedOnMissingOrDriftedPins(t *testing.T) {
	for _, header := range []string{"ETag", "X-Barkpark-Release-Gate", "X-Barkpark-Wave-Revision", "X-Barkpark-Paper-Candidate", "X-Barkpark-Paper-Role"} {
		t.Run(header, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				releasePaperResponse(w, testReleaseGate, testWaveRev)
			}))
			// Replace the handler so the selected pin is absent before WriteHeader.
			srv.Config.Handler = http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				w.Header().Set("ETag", `"sha256:`+strings.Repeat("b", 64)+`"`)
				w.Header().Set("X-Barkpark-Release-Gate", testReleaseGate)
				w.Header().Set("X-Barkpark-Wave-Revision", testWaveRev)
				w.Header().Set("X-Barkpark-Paper-Candidate", testCandidate)
				w.Header().Set("X-Barkpark-Paper-Role", "campaign")
				w.Header().Del(header)
				_, _ = w.Write([]byte(`{}`))
			})
			defer srv.Close()
			c := New(Config{BaseURL: srv.URL, Workspace: "acme", Project: "rocket"})
			ref := ReleasePaperRef{EpicID: "epic", WaveID: "wave", ReleaseGateID: testReleaseGate,
				RevisionID: testWaveRev, CandidateID: testCandidate, Role: "campaign"}
			if _, err := c.PaperReleaseSource(ref); err == nil || !strings.Contains(err.Error(), "pin headers") {
				t.Fatalf("missing %s error = %v", header, err)
			}
		})
	}
}

func TestPaperReleaseSourceRejectsNonJSONContentType(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/html")
		releasePaperResponse(w, testReleaseGate, testWaveRev)
	}))
	defer srv.Close()
	c := New(Config{BaseURL: srv.URL, Workspace: "acme", Project: "rocket"})
	ref := ReleasePaperRef{EpicID: "epic", WaveID: "wave", ReleaseGateID: testReleaseGate,
		RevisionID: testWaveRev, CandidateID: testCandidate, Role: "campaign"}
	if _, err := c.PaperReleaseSource(ref); err == nil || !strings.Contains(err.Error(), "Content-Type") {
		t.Fatalf("non-JSON Content-Type error = %v", err)
	}
}

func TestParseReleasePaperRefRequiresCanonicalPins(t *testing.T) {
	value := "https://api.example/w/acme/p/rocket/v1/cycles/epic/wave/release-gates/" + testReleaseGate +
		"/papers/campaign/source?wave_revision=" + testWaveRev + "&candidate_id=" + testCandidate
	ref, ok, err := ParseReleasePaperRef(value)
	if err != nil || !ok || ref.Origin != "https://api.example" || ref.Workspace != "acme" || ref.RevisionID != testWaveRev {
		t.Fatalf("ParseReleasePaperRef = %+v, %v, %v", ref, ok, err)
	}
	for _, bad := range []string{
		strings.Split(value, "?")[0],
		value + "&perspective=published",
		strings.Replace(value, "&candidate_id="+testCandidate, "", 1),
		strings.Replace(value, testWaveRev, "latest", 1),
		strings.Replace(value, "/epic/wave/", "/epic%2Fforeign/wave/", 1),
		strings.Replace(value, "/w/acme/", "/w/acme%2Fforeign/", 1),
		strings.Replace(value, "/p/rocket/", "/p/rocket%5Cforeign/", 1),
	} {
		if _, recognized, parseErr := ParseReleasePaperRef(bad); !recognized || parseErr == nil {
			t.Fatalf("malformed canonical release ref did not fail closed: %q", bad)
		}
	}
}
