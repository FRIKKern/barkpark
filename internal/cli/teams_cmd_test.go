package cli

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// meBody is the two-membership /v1/me envelope the team-switcher tests resolve
// slugs against: the primary team plus a Docs team the user was invited into.
const meBody = `{
	"user":{"id":"u-1","email":"ada@example.com","confirmed":true,"two_factor_enabled":false},
	"team":{"id":"team-1","name":"Primary","slug":"primary"},
	"teams":[
		{"id":"team-1","name":"Primary","slug":"primary","role":"owner"},
		{"id":"team-docs","name":"Docs","slug":"docs","role":"admin"}
	],
	"role":"owner"
}`

// teamsHits records what a fake control plane saw so the team-switcher tests can
// assert the resolved team context reached /credentials.
type teamsHits struct {
	me             int
	credentials    int
	credentialTeam string
}

// newTeamsControlPlane stands up ONE httptest server that answers GET /v1/me
// (the membership list `bp teams` / `bp team use` read) AND
// GET /v1/barkparks/:id/credentials (so `--team` wiring is provable end-to-end),
// recording the X-Barkpark-Team header it was called with.
func newTeamsControlPlane(t *testing.T, hits *teamsHits) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/v1/me":
			hits.me++
			_, _ = io.WriteString(w, meBody)
		case strings.HasSuffix(r.URL.Path, "/credentials"):
			hits.credentials++
			hits.credentialTeam = r.Header.Get("X-Barkpark-Team")
			_, _ = io.WriteString(w, `{"admin_token":"admin-secret","url":"https://park.example.com","host":""}`)
		default:
			w.WriteHeader(http.StatusNotFound)
			_, _ = io.WriteString(w, `{"error":"not_found"}`)
		}
	}))
	t.Cleanup(srv.Close)
	return srv
}

// TestTeamsListJSONMarksActive: `bp teams -o json` emits every membership and
// flags the active team (cfg.CloudTeam) with active:true.
func TestTeamsListJSONMarksActive(t *testing.T) {
	withTempConfigHome(t)
	var hits teamsHits
	srv := newTeamsControlPlane(t, &hits)
	if err := SaveConfig(&Config{CloudURL: srv.URL, CloudToken: "sess", CloudTeam: "team-docs"}); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}

	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	out.output = "json"
	if code := runTeams(out, nil); code != exitOK {
		t.Fatalf("runTeams = %d, want exitOK\nstderr: %s", code, stderr.String())
	}
	if hits.me == 0 {
		t.Fatal("runTeams must read /v1/me")
	}

	var got struct {
		Teams []struct {
			ID     string `json:"id"`
			Slug   string `json:"slug"`
			Role   string `json:"role"`
			Active bool   `json:"active"`
		} `json:"teams"`
		ActiveTeam string `json:"active_team"`
	}
	if err := json.Unmarshal(stdout.Bytes(), &got); err != nil {
		t.Fatalf("decode output %q: %v", stdout.String(), err)
	}
	if len(got.Teams) != 2 || got.ActiveTeam != "team-docs" {
		t.Fatalf("teams payload = %+v", got)
	}
	for _, tm := range got.Teams {
		want := tm.ID == "team-docs"
		if tm.Active != want {
			t.Fatalf("team %s active = %v, want %v", tm.ID, tm.Active, want)
		}
	}
}

// TestTeamsListTableStarsActive: the human table marks the active team with '*'.
func TestTeamsListTableStarsActive(t *testing.T) {
	withTempConfigHome(t)
	var hits teamsHits
	srv := newTeamsControlPlane(t, &hits)
	if err := SaveConfig(&Config{CloudURL: srv.URL, CloudToken: "sess", CloudTeam: "team-1"}); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}

	var stdout, stderr bytes.Buffer
	out := ttyWriter(&stdout, &stderr)
	if code := runTeams(out, nil); code != exitOK {
		t.Fatalf("runTeams = %d, want exitOK\nstderr: %s", code, stderr.String())
	}
	lines := strings.Split(strings.TrimRight(stdout.String(), "\n"), "\n")
	var primaryLine, docsLine string
	for _, l := range lines {
		if strings.Contains(l, "primary") {
			primaryLine = l
		}
		if strings.Contains(l, "docs") {
			docsLine = l
		}
	}
	if !strings.HasPrefix(strings.TrimSpace(primaryLine), "*") {
		t.Fatalf("active (primary) row should be starred; got %q", primaryLine)
	}
	if strings.HasPrefix(strings.TrimSpace(docsLine), "*") {
		t.Fatalf("inactive (docs) row must NOT be starred; got %q", docsLine)
	}
}

// TestTeamsRequiresLogin: with no Cloud token, `bp teams` gates on login.
func TestTeamsRequiresLogin(t *testing.T) {
	withTempConfigHome(t)
	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	if code := runTeams(out, nil); code != exitAuth {
		t.Fatalf("runTeams without a token = %d, want exitAuth", code)
	}
}

// TestTeamUseResolvesSlugToUUID: `bp team use docs` resolves the slug to its UUID
// from the membership list and persists the UUID (not the slug) to cfg.CloudTeam.
func TestTeamUseResolvesSlugToUUID(t *testing.T) {
	withTempConfigHome(t)
	var hits teamsHits
	srv := newTeamsControlPlane(t, &hits)
	if err := SaveConfig(&Config{CloudURL: srv.URL, CloudToken: "sess", CloudTeam: "team-1"}); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}

	var stdout, stderr bytes.Buffer
	out := ttyWriter(&stdout, &stderr)
	if code := runTeam(out, []string{"use", "docs"}); code != exitOK {
		t.Fatalf("runTeam use docs = %d, want exitOK\nstderr: %s", code, stderr.String())
	}
	loaded, err := LoadConfig()
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	if loaded.CloudTeam != "team-docs" {
		t.Fatalf("cfg.CloudTeam = %q, want the resolved UUID team-docs", loaded.CloudTeam)
	}
}

// TestTeamUseRejectsNonMember: switching to a team you don't belong to is refused
// and leaves cfg.CloudTeam untouched (no silent write of an unknown team).
func TestTeamUseRejectsNonMember(t *testing.T) {
	withTempConfigHome(t)
	var hits teamsHits
	srv := newTeamsControlPlane(t, &hits)
	if err := SaveConfig(&Config{CloudURL: srv.URL, CloudToken: "sess", CloudTeam: "team-1"}); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}

	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	if code := runTeam(out, []string{"use", "marketing"}); code == exitOK {
		t.Fatalf("runTeam use of a non-member team should fail, got exitOK")
	}
	loaded, _ := LoadConfig()
	if loaded.CloudTeam != "team-1" {
		t.Fatalf("a refused switch must not mutate cfg.CloudTeam; got %q", loaded.CloudTeam)
	}
}

// TestInstanceCredentialsTeamFlagSendsResolvedHeader: `--team docs` resolves the
// slug and sends the resolved UUID as X-Barkpark-Team on the credentials request.
func TestInstanceCredentialsTeamFlagSendsResolvedHeader(t *testing.T) {
	withTempConfigHome(t)
	var hits teamsHits
	srv := newTeamsControlPlane(t, &hits)
	if err := SaveConfig(&Config{CloudURL: srv.URL, CloudToken: "sess", CloudTeam: "team-1"}); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}

	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	out.output = "json"
	if code := runInstanceCredentials(out, []string{"bp-9", "--team", "docs"}); code != exitOK {
		t.Fatalf("runInstanceCredentials = %d, want exitOK\nstderr: %s", code, stderr.String())
	}
	if hits.credentials != 1 {
		t.Fatalf("credentials request count = %d, want 1", hits.credentials)
	}
	if hits.credentialTeam != "team-docs" {
		t.Fatalf("X-Barkpark-Team = %q, want the resolved UUID team-docs", hits.credentialTeam)
	}
}

// TestInstanceCredentialsDefaultsToActiveTeam: with no --team, the credentials
// request carries the active team (cfg.CloudTeam) and never reads /v1/me.
func TestInstanceCredentialsDefaultsToActiveTeam(t *testing.T) {
	withTempConfigHome(t)
	var hits teamsHits
	srv := newTeamsControlPlane(t, &hits)
	if err := SaveConfig(&Config{CloudURL: srv.URL, CloudToken: "sess", CloudTeam: "team-docs"}); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}

	var stdout, stderr bytes.Buffer
	out := newWriter(&stdout, &stderr)
	out.output = "json"
	if code := runInstanceCredentials(out, []string{"bp-9"}); code != exitOK {
		t.Fatalf("runInstanceCredentials = %d, want exitOK\nstderr: %s", code, stderr.String())
	}
	if hits.credentialTeam != "team-docs" {
		t.Fatalf("default X-Barkpark-Team = %q, want cfg.CloudTeam team-docs", hits.credentialTeam)
	}
	if hits.me != 0 {
		t.Fatalf("no --team means no slug resolution; /v1/me hit %d times, want 0", hits.me)
	}
}
