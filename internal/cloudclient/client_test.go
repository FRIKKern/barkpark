package cloudclient

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"go/ast"
	"go/parser"
	"go/printer"
	"go/token"
	"io"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"
	"time"
	"unicode/utf8"
)

// newFake spins up an httptest.Server with handler h and returns a Client pointed
// at it (token preset, the server's own http.Client injected). The caller closes
// the server via t.Cleanup.
func newFake(t *testing.T, token string, h http.HandlerFunc) *Client {
	t.Helper()
	srv := httptest.NewServer(h)
	t.Cleanup(srv.Close)
	return &Client{BaseURL: srv.URL, Token: token, HTTP: srv.Client()}
}

// readJSON decodes the request body into a generic map for assertions.
func readJSON(t *testing.T, r *http.Request) map[string]any {
	t.Helper()
	raw, err := io.ReadAll(r.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	if len(raw) == 0 {
		return map[string]any{}
	}
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		t.Fatalf("decode body %q: %v", raw, err)
	}
	return m
}

func TestLoginSuccess(t *testing.T) {
	var gotMethod, gotPath, gotAuth string
	var gotBody map[string]any
	c := newFake(t, "", func(w http.ResponseWriter, r *http.Request) {
		gotMethod, gotPath, gotAuth = r.Method, r.URL.Path, r.Header.Get("Authorization")
		gotBody = readJSON(t, r)
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, `{"token":"sess-abc","team_id":"team-1"}`)
	})

	resp, err := c.Login(context.Background(), "a@b.com", "hunter2")
	if err != nil {
		t.Fatalf("Login: %v", err)
	}
	if resp.Token != "sess-abc" || resp.TeamID != "team-1" {
		t.Fatalf("decoded LoginResp = %+v", resp)
	}
	// Request assertions: method/path/body, and NO bearer (login is unauthed).
	if gotMethod != "POST" || gotPath != "/v1/auth/login" {
		t.Fatalf("request = %s %s, want POST /v1/auth/login", gotMethod, gotPath)
	}
	if gotAuth != "" {
		t.Fatalf("login must not send a bearer; got %q", gotAuth)
	}
	if gotBody["email"] != "a@b.com" || gotBody["password"] != "hunter2" {
		t.Fatalf("login body = %v", gotBody)
	}
}

func TestLogin401SurfacesAuthError(t *testing.T) {
	c := newFake(t, "", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = io.WriteString(w, `{"error":"invalid_credentials"}`)
	})
	_, err := c.Login(context.Background(), "a@b.com", "wrong")
	if err == nil {
		t.Fatal("Login with 401 must error")
	}
	if !strings.Contains(err.Error(), "unauthorized") || !strings.Contains(err.Error(), "invalid_credentials") {
		t.Fatalf("401 error = %q, want it to surface unauthorized + the message", err)
	}
}

func TestRegisterSuccess(t *testing.T) {
	var gotMethod, gotPath, gotAuth string
	var gotBody map[string]any
	c := newFake(t, "", func(w http.ResponseWriter, r *http.Request) {
		gotMethod, gotPath, gotAuth = r.Method, r.URL.Path, r.Header.Get("Authorization")
		gotBody = readJSON(t, r)
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, `{"token":"sess-new","team_id":"team-7"}`)
	})

	resp, err := c.Register(context.Background(), "ada@x.com", "hunter2pw!", "ada")
	if err != nil {
		t.Fatalf("Register: %v", err)
	}
	if resp.Token != "sess-new" || resp.TeamID != "team-7" {
		t.Fatalf("decoded RegisterResp = %+v", resp)
	}
	// Mirror of login: POST /v1/auth/register, NO bearer (register is unauthed),
	// body carries email/password/team_name.
	if gotMethod != "POST" || gotPath != "/v1/auth/register" {
		t.Fatalf("request = %s %s, want POST /v1/auth/register", gotMethod, gotPath)
	}
	if gotAuth != "" {
		t.Fatalf("register must not send a bearer; got %q", gotAuth)
	}
	if gotBody["email"] != "ada@x.com" || gotBody["password"] != "hunter2pw!" || gotBody["team_name"] != "ada" {
		t.Fatalf("register body = %v", gotBody)
	}
}

func TestRegisterOmitsEmptyTeam(t *testing.T) {
	var gotBody map[string]any
	c := newFake(t, "", func(w http.ResponseWriter, r *http.Request) {
		gotBody = readJSON(t, r)
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, `{"token":"sess-new","team_id":"team-8"}`)
	})
	if _, err := c.Register(context.Background(), "ada@x.com", "hunter2pw!", ""); err != nil {
		t.Fatalf("Register: %v", err)
	}
	if _, present := gotBody["team_name"]; present {
		t.Fatalf("empty team must be omitted from the request body; got %v", gotBody)
	}
}

func TestRegister409SurfacesEmailTaken(t *testing.T) {
	c := newFake(t, "", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusConflict)
		_, _ = io.WriteString(w, `{"error":"email_taken"}`)
	})
	_, err := c.Register(context.Background(), "ada@x.com", "hunter2pw!", "")
	if err == nil {
		t.Fatal("Register with 409 must error")
	}
	if err.Error() != "email_taken" {
		t.Fatalf("409 error = %q, want exactly email_taken", err)
	}
}

func TestRegister422SurfacesValidation(t *testing.T) {
	c := newFake(t, "", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnprocessableEntity)
		_, _ = io.WriteString(w, `{"error":"password_invalid"}`)
	})
	_, err := c.Register(context.Background(), "ada@x.com", "weak", "")
	if err == nil {
		t.Fatal("Register with 422 must error")
	}
	if err.Error() != "password_invalid" {
		t.Fatalf("422 error = %q, want exactly password_invalid", err)
	}
}

func TestListBarkparks(t *testing.T) {
	var gotAuth, gotMethod, gotPath string
	c := newFake(t, "sess-abc", func(w http.ResponseWriter, r *http.Request) {
		gotAuth, gotMethod, gotPath = r.Header.Get("Authorization"), r.Method, r.URL.Path
		_, _ = io.WriteString(w, `{"barkparks":[
			{"id":"bp-1","name":"prod","slug":"prod","url":"https://prod.example.com","host":"prod.example.com","mode":"managed","health_status":"up","agent_status":"online","version":"1.2.3","git_commit":"abc123","last_seen_at":"2026-06-26T00:00:00Z","team_id":"team-1","inserted_at":"2026-06-01T00:00:00Z"},
			{"id":"bp-2","name":"staging","slug":"staging","url":"","host":"staging.example.com","mode":"byo","health_status":"unknown","agent_status":"offline","version":"","git_commit":"","last_seen_at":null,"team_id":"team-1","inserted_at":"2026-06-02T00:00:00Z"}
		]}`)
	})

	list, err := c.ListBarkparks(context.Background())
	if err != nil {
		t.Fatalf("ListBarkparks: %v", err)
	}
	if gotMethod != "GET" || gotPath != "/v1/barkparks" {
		t.Fatalf("request = %s %s, want GET /v1/barkparks", gotMethod, gotPath)
	}
	if gotAuth != "Bearer sess-abc" {
		t.Fatalf("auth header = %q, want Bearer sess-abc", gotAuth)
	}
	if len(list) != 2 {
		t.Fatalf("got %d barkparks, want 2", len(list))
	}
	b := list[0]
	if b.ID != "bp-1" || b.Name != "prod" || b.HealthStatus != "up" || b.AgentStatus != "online" || b.Mode != "managed" {
		t.Fatalf("barkpark[0] decoded wrong: %+v", b)
	}
	if list[1].Mode != "byo" || list[1].HealthStatus != "unknown" {
		t.Fatalf("barkpark[1] decoded wrong: %+v", list[1])
	}
}

func TestBarkparkQueuedDeployAgeWirePresence(t *testing.T) {
	cases := []struct {
		name           string
		raw            string
		wantMissing    bool
		wantAge        float64
		wantAgePresent bool
	}{
		{name: "field omitted", raw: `{}`, wantMissing: true},
		{name: "explicit null means nothing queued", raw: `{"queued_deploy_age_seconds":null}`},
		{name: "measured young queue", raw: `{"queued_deploy_age_seconds":90}`, wantAge: 90, wantAgePresent: true},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var b Barkpark
			if err := json.Unmarshal([]byte(tc.raw), &b); err != nil {
				t.Fatalf("decode Barkpark: %v", err)
			}
			if b.QueuedDeployAgeSecondsMissing != tc.wantMissing {
				t.Fatalf("QueuedDeployAgeSecondsMissing = %v, want %v", b.QueuedDeployAgeSecondsMissing, tc.wantMissing)
			}
			if !tc.wantAgePresent {
				if b.QueuedDeployAgeSeconds != nil {
					t.Fatalf("QueuedDeployAgeSeconds = %v, want nil", *b.QueuedDeployAgeSeconds)
				}
				return
			}
			if b.QueuedDeployAgeSeconds == nil || *b.QueuedDeployAgeSeconds != tc.wantAge {
				t.Fatalf("QueuedDeployAgeSeconds = %v, want %v", b.QueuedDeployAgeSeconds, tc.wantAge)
			}
		})
	}
}

func TestListAllBarkparks(t *testing.T) {
	var gotPath, gotQuery string
	c := newFake(t, "sess-abc", func(w http.ResponseWriter, r *http.Request) {
		gotPath, gotQuery = r.URL.Path, r.URL.RawQuery
		_, _ = io.WriteString(w, `{"barkparks":[
			{"id":"bp-1","name":"prod","slug":"prod","team_id":"team-1","team":{"id":"team-1","name":"Primary","slug":"primary"}},
			{"id":"bp-2","name":"docs","slug":"docs","team_id":"team-2","team":{"id":"team-2","name":"Docs","slug":"docs","role":"member"}}
		]}`)
	})

	list, err := c.ListAllBarkparks(context.Background())
	if err != nil {
		t.Fatalf("ListAllBarkparks: %v", err)
	}
	if gotPath != "/v1/barkparks" || gotQuery != "scope=all" {
		t.Fatalf("request = %s?%s, want /v1/barkparks?scope=all", gotPath, gotQuery)
	}
	if len(list) != 2 || list[1].Team == nil || list[1].Team.Name != "Docs" || list[1].Team.Role != "member" {
		t.Fatalf("cross-team response decoded wrong: %+v", list)
	}
}

func TestGetCredentials(t *testing.T) {
	var gotAuth, gotMethod, gotPath, gotTeam string
	c := newFake(t, "sess-xyz", func(w http.ResponseWriter, r *http.Request) {
		gotAuth, gotMethod, gotPath, gotTeam = r.Header.Get("Authorization"), r.Method, r.URL.Path, r.Header.Get("X-Barkpark-Team")
		_, _ = io.WriteString(w, `{"admin_token":"bp_admin_secret-bearer","url":"https://prod.example.com","host":"203.0.113.7"}`)
	})

	creds, err := c.GetCredentials(context.Background(), "bp-1")
	if err != nil {
		t.Fatalf("GetCredentials: %v", err)
	}
	if gotMethod != "GET" || gotPath != "/v1/barkparks/bp-1/credentials" {
		t.Fatalf("request = %s %s, want GET /v1/barkparks/bp-1/credentials", gotMethod, gotPath)
	}
	if gotAuth != "Bearer sess-xyz" {
		t.Fatalf("auth header = %q, want Bearer sess-xyz", gotAuth)
	}
	if gotTeam != "" {
		t.Fatalf("default GetCredentials team header = %q, want absent", gotTeam)
	}
	if creds.AdminToken != "bp_admin_secret-bearer" || creds.URL != "https://prod.example.com" || creds.Host != "203.0.113.7" {
		t.Fatalf("credentials decoded wrong: %+v", creds)
	}
}

func TestGetCredentialsForTeamSetsTeamHeader(t *testing.T) {
	var gotTeam string
	c := newFake(t, "sess-xyz", func(w http.ResponseWriter, r *http.Request) {
		gotTeam = r.Header.Get("X-Barkpark-Team")
		_, _ = io.WriteString(w, `{"admin_token":"secret"}`)
	})
	if _, err := c.GetCredentialsForTeam(context.Background(), "bp-2", "team-docs"); err != nil {
		t.Fatalf("GetCredentialsForTeam: %v", err)
	}
	if gotTeam != "team-docs" {
		t.Fatalf("team header = %q, want team-docs", gotTeam)
	}
}

func TestGetCredentials404SurfacesNoAdminToken(t *testing.T) {
	c := newFake(t, "sess-xyz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
		_, _ = io.WriteString(w, `{"error":"no_admin_token"}`)
	})

	_, err := c.GetCredentials(context.Background(), "bp-1")
	if err == nil {
		t.Fatal("GetCredentials on a 404 returned nil, want an error")
	}
	if !strings.Contains(err.Error(), "no_admin_token") {
		t.Fatalf("error = %v, want it to surface no_admin_token", err)
	}
}

func TestMeReturnsTeamsMembershipList(t *testing.T) {
	var gotMethod, gotPath, gotAuth string
	c := newFake(t, "sess-xyz", func(w http.ResponseWriter, r *http.Request) {
		gotMethod, gotPath, gotAuth = r.Method, r.URL.Path, r.Header.Get("Authorization")
		_, _ = io.WriteString(w, `{
			"user":{"id":"u-1","email":"ada@example.com","confirmed":true,"two_factor_enabled":false},
			"team":{"id":"team-1","name":"Primary","slug":"primary"},
			"teams":[
				{"id":"team-1","name":"Primary","slug":"primary","role":"owner"},
				{"id":"team-2","name":"Docs","slug":"docs","role":"admin"}
			],
			"role":"owner"
		}`)
	})

	me, err := c.Me(context.Background())
	if err != nil {
		t.Fatalf("Me: %v", err)
	}
	if gotMethod != "GET" || gotPath != "/v1/me" {
		t.Fatalf("request = %s %s, want GET /v1/me", gotMethod, gotPath)
	}
	if gotAuth != "Bearer sess-xyz" {
		t.Fatalf("Me must send the session bearer; got %q", gotAuth)
	}
	if me.User.Email != "ada@example.com" || me.Role != "owner" {
		t.Fatalf("decoded identity = %+v", me)
	}
	if len(me.Teams) != 2 {
		t.Fatalf("teams len = %d, want 2 (%+v)", len(me.Teams), me.Teams)
	}
	if me.Teams[1].ID != "team-2" || me.Teams[1].Slug != "docs" || me.Teams[1].Role != "admin" {
		t.Fatalf("second membership decoded wrong: %+v", me.Teams[1])
	}
	if me.Team == nil || me.Team.ID != "team-1" {
		t.Fatalf("current team decoded wrong: %+v", me.Team)
	}
}

func TestMe401SurfacesAuthError(t *testing.T) {
	c := newFake(t, "bad", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = io.WriteString(w, `{"error":"invalid_token"}`)
	})
	_, err := c.Me(context.Background())
	if err == nil {
		t.Fatal("Me on a 401 returned nil, want an error")
	}
	if !strings.Contains(err.Error(), "unauthorized") {
		t.Fatalf("error = %v, want it prefixed unauthorized", err)
	}
}

func TestConnectProvider(t *testing.T) {
	var gotBody map[string]any
	var gotMethod, gotPath, gotAuth string
	c := newFake(t, "sess-abc", func(w http.ResponseWriter, r *http.Request) {
		gotMethod, gotPath, gotAuth = r.Method, r.URL.Path, r.Header.Get("Authorization")
		gotBody = readJSON(t, r)
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, `{"provider":{"id":"prov-1","kind":"hetzner","label":"main","team_id":"team-1","inserted_at":"2026-06-26T00:00:00Z"}}`)
	})

	prov, err := c.ConnectProvider(context.Background(), "hetzner", "hcloud-token", "main")
	if err != nil {
		t.Fatalf("ConnectProvider: %v", err)
	}
	if gotMethod != "POST" || gotPath != "/v1/providers" {
		t.Fatalf("request = %s %s, want POST /v1/providers", gotMethod, gotPath)
	}
	if gotAuth != "Bearer sess-abc" {
		t.Fatalf("auth = %q, want Bearer sess-abc", gotAuth)
	}
	if gotBody["kind"] != "hetzner" || gotBody["token"] != "hcloud-token" || gotBody["label"] != "main" {
		t.Fatalf("provider body = %v", gotBody)
	}
	if prov.ID != "prov-1" || prov.Kind != "hetzner" || prov.Label != "main" {
		t.Fatalf("decoded provider = %+v", prov)
	}
}

func TestConnectProviderOmitsEmptyLabel(t *testing.T) {
	var gotBody map[string]any
	c := newFake(t, "sess-abc", func(w http.ResponseWriter, r *http.Request) {
		gotBody = readJSON(t, r)
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, `{"provider":{"id":"prov-1","kind":"hetzner","label":"","team_id":"team-1"}}`)
	})
	if _, err := c.ConnectProvider(context.Background(), "hetzner", "tok", ""); err != nil {
		t.Fatalf("ConnectProvider: %v", err)
	}
	if _, present := gotBody["label"]; present {
		t.Fatalf("empty label must be omitted from the request body; got %v", gotBody)
	}
}

func TestLaunch(t *testing.T) {
	var gotBody map[string]any
	var gotMethod, gotPath string
	c := newFake(t, "sess-abc", func(w http.ResponseWriter, r *http.Request) {
		gotMethod, gotPath = r.Method, r.URL.Path
		gotBody = readJSON(t, r)
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, `{"barkpark":{"id":"bp-9","name":"shop","slug":"shop","host":"shop.example.com","mode":"byo","health_status":"unknown","agent_status":"offline","team_id":"team-1"}}`)
	})

	bp, err := c.Launch(context.Background(), "hetzner", "shop")
	if err != nil {
		t.Fatalf("Launch: %v", err)
	}
	if gotMethod != "POST" || gotPath != "/v1/launch" {
		t.Fatalf("request = %s %s, want POST /v1/launch", gotMethod, gotPath)
	}
	if gotBody["provider"] != "hetzner" || gotBody["name"] != "shop" {
		t.Fatalf("launch body = %v", gotBody)
	}
	if bp.ID != "bp-9" || bp.Name != "shop" || bp.Mode != "byo" {
		t.Fatalf("decoded barkpark = %+v", bp)
	}
}

func TestLaunchOmitsEmptyProvider(t *testing.T) {
	var gotBody map[string]any
	c := newFake(t, "sess-abc", func(w http.ResponseWriter, r *http.Request) {
		gotBody = readJSON(t, r)
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, `{"barkpark":{"id":"bp-9","name":"shop"}}`)
	})
	if _, err := c.Launch(context.Background(), "", "shop"); err != nil {
		t.Fatalf("Launch: %v", err)
	}
	if _, present := gotBody["provider"]; present {
		t.Fatalf("empty provider must be omitted; got %v", gotBody)
	}
}

func TestGoLive(t *testing.T) {
	var gotBody map[string]any
	var gotMethod, gotPath string
	c := newFake(t, "sess-abc", func(w http.ResponseWriter, r *http.Request) {
		gotMethod, gotPath = r.Method, r.URL.Path
		gotBody = readJSON(t, r)
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, `{"barkpark":{"id":"bp-7","name":"blog","slug":"blog","url":"https://blog.barkpark.cloud","mode":"managed","health_status":"unknown","agent_status":"offline","team_id":"team-1"}}`)
	})

	bp, err := c.GoLive(context.Background(), "blog", "pro")
	if err != nil {
		t.Fatalf("GoLive: %v", err)
	}
	if gotMethod != "POST" || gotPath != "/v1/go-live" {
		t.Fatalf("request = %s %s, want POST /v1/go-live", gotMethod, gotPath)
	}
	if gotBody["name"] != "blog" || gotBody["plan"] != "pro" {
		t.Fatalf("go-live body = %v", gotBody)
	}
	if bp.ID != "bp-7" || bp.URL != "https://blog.barkpark.cloud" || bp.Mode != "managed" {
		t.Fatalf("decoded barkpark = %+v", bp)
	}
}

func TestGoLive422SurfacesNameRequired(t *testing.T) {
	c := newFake(t, "sess-abc", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnprocessableEntity)
		_, _ = io.WriteString(w, `{"error":"name_required"}`)
	})
	_, err := c.GoLive(context.Background(), "", "")
	if err == nil {
		t.Fatal("GoLive with 422 must error")
	}
	if err.Error() != "name_required" {
		t.Fatalf("422 error = %q, want exactly the surfaced message name_required", err)
	}
}

func TestGoLiveOmitsEmptyPlan(t *testing.T) {
	var gotBody map[string]any
	c := newFake(t, "sess-abc", func(w http.ResponseWriter, r *http.Request) {
		gotBody = readJSON(t, r)
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, `{"barkpark":{"id":"bp-7","name":"blog"}}`)
	})
	if _, err := c.GoLive(context.Background(), "blog", ""); err != nil {
		t.Fatalf("GoLive: %v", err)
	}
	if _, present := gotBody["plan"]; present {
		t.Fatalf("empty plan must be omitted; got %v", gotBody)
	}
}

// TestListSites: GET /v1/sites with the bearer attached; decodes the sites array.
func TestListSites(t *testing.T) {
	var gotAuth, gotMethod, gotPath string
	c := newFake(t, "sess-abc", func(w http.ResponseWriter, r *http.Request) {
		gotAuth, gotMethod, gotPath = r.Header.Get("Authorization"), r.Method, r.URL.Path
		_, _ = io.WriteString(w, `{"sites":[
			{"id":"site-1","barkpark_id":"bp-1","team_id":"team-1","name":"Blog","slug":"blog","framework":"nextjs","domains":["blog.example.com"],"scale_mode":"always_on","port":4101,"current_deployment_id":"dep-a","inserted_at":"2026-06-26T00:00:00Z","updated_at":"2026-06-26T01:00:00Z"},
			{"id":"site-2","barkpark_id":"bp-1","team_id":"team-1","name":"Shop","slug":"shop","framework":"nextjs","domains":[],"scale_mode":"zero","port":0,"current_deployment_id":"","inserted_at":"2026-06-26T00:00:00Z","updated_at":"2026-06-26T01:00:00Z"}
		]}`)
	})

	list, err := c.ListSites(context.Background())
	if err != nil {
		t.Fatalf("ListSites: %v", err)
	}
	if gotMethod != "GET" || gotPath != "/v1/sites" {
		t.Fatalf("request = %s %s, want GET /v1/sites", gotMethod, gotPath)
	}
	if gotAuth != "Bearer sess-abc" {
		t.Fatalf("auth header = %q, want Bearer sess-abc", gotAuth)
	}
	if len(list) != 2 || list[0].Slug != "blog" || list[0].CurrentDeploymentID != "dep-a" || list[1].ScaleMode != "zero" {
		t.Fatalf("decoded sites = %+v", list)
	}
	if len(list[0].Domains) != 1 || list[0].Domains[0] != "blog.example.com" {
		t.Fatalf("domains decoded wrong: %+v", list[0].Domains)
	}
}

// TestGetSite: GET /v1/sites/:id returns a single site row.
func TestGetSite(t *testing.T) {
	var gotPath string
	c := newFake(t, "sess-abc", func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		_, _ = io.WriteString(w, `{"site":{"id":"site-1","barkpark_id":"bp-1","team_id":"team-1","name":"Blog","slug":"blog","framework":"nextjs","domains":["blog.example.com"],"scale_mode":"always_on","port":4101}}`)
	})
	s, err := c.GetSite(context.Background(), "site-1")
	if err != nil {
		t.Fatalf("GetSite: %v", err)
	}
	if gotPath != "/v1/sites/site-1" {
		t.Fatalf("hit %q, want /v1/sites/site-1", gotPath)
	}
	if s.ID != "site-1" || s.Name != "Blog" {
		t.Fatalf("decoded site = %+v", s)
	}
}

// TestGetSiteEscapesID: a user-typed id containing a path-corrupting char (here
// "a/b") is url.PathEscape'd into a single segment, so the server sees
// "/v1/sites/a%2Fb" rather than a "/b" sub-route. Guards the esc() hardening.
func TestGetSiteEscapesID(t *testing.T) {
	var gotEscaped string
	c := newFake(t, "sess-abc", func(w http.ResponseWriter, r *http.Request) {
		gotEscaped = r.URL.EscapedPath()
		_, _ = io.WriteString(w, `{"site":{"id":"a/b","barkpark_id":"bp-1","team_id":"team-1","name":"Blog","slug":"blog","framework":"nextjs","scale_mode":"always_on"}}`)
	})
	if _, err := c.GetSite(context.Background(), "a/b"); err != nil {
		t.Fatalf("GetSite: %v", err)
	}
	if !strings.Contains(gotEscaped, "a%2Fb") {
		t.Fatalf("escaped path %q, want it to contain a%%2Fb", gotEscaped)
	}
}

// TestCreateSite: POST /v1/sites carries the right body and decodes the row.
func TestCreateSite(t *testing.T) {
	var gotBody map[string]any
	var gotMethod, gotPath string
	c := newFake(t, "sess-abc", func(w http.ResponseWriter, r *http.Request) {
		gotMethod, gotPath = r.Method, r.URL.Path
		gotBody = readJSON(t, r)
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, `{"site":{"id":"site-7","barkpark_id":"bp-1","team_id":"team-1","name":"Blog","slug":"blog","framework":"nextjs","domains":["blog.example.com"],"scale_mode":"always_on"}}`)
	})

	s, err := c.CreateSite(context.Background(), SiteCreate{
		BarkparkID: "bp-1",
		Name:       "Blog",
		Framework:  "nextjs",
		Domains:    []string{"blog.example.com"},
	})
	if err != nil {
		t.Fatalf("CreateSite: %v", err)
	}
	if gotMethod != "POST" || gotPath != "/v1/sites" {
		t.Fatalf("request = %s %s, want POST /v1/sites", gotMethod, gotPath)
	}
	if gotBody["barkpark_id"] != "bp-1" || gotBody["name"] != "Blog" || gotBody["framework"] != "nextjs" {
		t.Fatalf("create body = %v", gotBody)
	}
	if s.ID != "site-7" || s.Slug != "blog" {
		t.Fatalf("decoded site = %+v", s)
	}
}

// TestCreateSiteOmitsEmpty: zero-value optional fields ride as omitempty so the
// server's defaults (framework "nextjs", scale_mode "always_on") apply.
func TestCreateSiteOmitsEmpty(t *testing.T) {
	var gotBody map[string]any
	c := newFake(t, "sess-abc", func(w http.ResponseWriter, r *http.Request) {
		gotBody = readJSON(t, r)
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, `{"site":{"id":"site-7"}}`)
	})
	if _, err := c.CreateSite(context.Background(), SiteCreate{
		BarkparkID: "bp-1", Name: "Blog",
	}); err != nil {
		t.Fatalf("CreateSite: %v", err)
	}
	if _, present := gotBody["framework"]; present {
		t.Fatalf("empty framework must be omitted; got %v", gotBody)
	}
	if _, present := gotBody["scale_mode"]; present {
		t.Fatalf("empty scale_mode must be omitted; got %v", gotBody)
	}
	if _, present := gotBody["domains"]; present {
		t.Fatalf("empty domains must be omitted; got %v", gotBody)
	}
}

// TestDeploy: POST /v1/sites/:id/deploy with git_ref + artifact_url.
func TestDeploy(t *testing.T) {
	var gotBody map[string]any
	var gotMethod, gotPath string
	c := newFake(t, "sess-abc", func(w http.ResponseWriter, r *http.Request) {
		gotMethod, gotPath = r.Method, r.URL.Path
		gotBody = readJSON(t, r)
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, `{"deployment":{"id":"dep-1","site_id":"site-1","status":"queued","git_ref":"main","artifact_url":"file:///tmp/x.tar"}}`)
	})

	d, err := c.Deploy(context.Background(), "site-1", "main", "file:///tmp/x.tar")
	if err != nil {
		t.Fatalf("Deploy: %v", err)
	}
	if gotMethod != "POST" || gotPath != "/v1/sites/site-1/deploy" {
		t.Fatalf("request = %s %s, want POST /v1/sites/site-1/deploy", gotMethod, gotPath)
	}
	if gotBody["git_ref"] != "main" || gotBody["artifact_url"] != "file:///tmp/x.tar" {
		t.Fatalf("deploy body = %v", gotBody)
	}
	if d.ID != "dep-1" || d.Status != "queued" {
		t.Fatalf("decoded deployment = %+v", d)
	}
}

// TestDeployOmitsEmptyFields: a deploy with no git_ref / artifact_url posts an
// empty object — the server picks up site defaults.
func TestDeployOmitsEmptyFields(t *testing.T) {
	var gotBody map[string]any
	c := newFake(t, "sess-abc", func(w http.ResponseWriter, r *http.Request) {
		gotBody = readJSON(t, r)
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, `{"deployment":{"id":"dep-1","status":"queued"}}`)
	})
	if _, err := c.Deploy(context.Background(), "site-1", "", ""); err != nil {
		t.Fatalf("Deploy: %v", err)
	}
	if _, present := gotBody["git_ref"]; present {
		t.Fatalf("empty git_ref must be omitted; got %v", gotBody)
	}
	if _, present := gotBody["artifact_url"]; present {
		t.Fatalf("empty artifact_url must be omitted; got %v", gotBody)
	}
}

// TestListDeployments: GET /v1/sites/:id/deployments newest-first, with no
// query string when the caller asks for no window.
func TestListDeployments(t *testing.T) {
	var gotPath, gotQuery string
	c := newFake(t, "sess-abc", func(w http.ResponseWriter, r *http.Request) {
		gotPath, gotQuery = r.URL.Path, r.URL.RawQuery
		_, _ = io.WriteString(w, `{"deployments":[
			{"id":"dep-2","site_id":"site-1","status":"live","image_tag":"sha:b","inserted_at":"2026-06-26T02:00:00Z"},
			{"id":"dep-1","site_id":"site-1","status":"failed","failure_reason":"boom","inserted_at":"2026-06-26T01:00:00Z"}
		]}`)
	})
	page, err := c.ListDeployments(context.Background(), "site-1", DeploymentQuery{})
	if err != nil {
		t.Fatalf("ListDeployments: %v", err)
	}
	if gotPath != "/v1/sites/site-1/deployments" {
		t.Fatalf("hit %q, want /v1/sites/site-1/deployments", gotPath)
	}
	if gotQuery != "" {
		t.Fatalf("zero-value query must send NO query string; got %q", gotQuery)
	}
	ds := page.Deployments
	if len(ds) != 2 || ds[0].Status != "live" {
		t.Fatalf("decoded deployments = %+v", ds)
	}
	if ds[1].FailureReason == nil || *ds[1].FailureReason != "boom" {
		t.Fatalf("failure_reason not decoded: %+v", ds[1])
	}
	// The absent key must stay absent — a nil, not an empty string that a
	// render path would print as a measured value.
	if ds[0].FailureReason != nil {
		t.Fatalf("a row with no failure_reason must decode nil, got %q", *ds[0].FailureReason)
	}
	if page.NextCursor != "" {
		t.Fatalf("no next_cursor on the wire must be \"\", got %q", page.NextCursor)
	}
}

// TestListDeploymentsWindowAndCursor: deploy-reliability W9. The call used to
// send no query at all, so it could never page past the server's default 100 —
// and every rate computed from those rows was a rate over an unstated window.
func TestListDeploymentsWindowAndCursor(t *testing.T) {
	var gotQuery string
	c := newFake(t, "sess-abc", func(w http.ResponseWriter, r *http.Request) {
		gotQuery = r.URL.RawQuery
		_, _ = io.WriteString(w, `{"deployments":[
			{"id":"dep-9","site_id":"site-1","status":"failed","failure_class":"BOX_AT_CAPACITY_DEFERRED","stage":"queue","trigger":"push","content_rev":"rev-7","inserted_at":"2026-06-26T02:00:00Z"}
		],"next_cursor":"cur-abc"}`)
	})
	page, err := c.ListDeployments(context.Background(), "site-1", DeploymentQuery{Limit: 250, Before: "cur-prev"})
	if err != nil {
		t.Fatalf("ListDeployments: %v", err)
	}
	if gotQuery != "before=cur-prev&limit=250" {
		t.Fatalf("query = %q, want before=cur-prev&limit=250", gotQuery)
	}
	if page.NextCursor != "cur-abc" {
		t.Fatalf("next_cursor = %q, want cur-abc", page.NextCursor)
	}
	d := page.Deployments[0]
	for name, got := range map[string]*string{
		"failure_class": d.FailureClass,
		"stage":         d.Stage,
		"trigger":       d.Trigger,
		"content_rev":   d.ContentRev,
	} {
		if got == nil {
			t.Fatalf("%s decoded nil — the key was on the wire", name)
		}
	}
	if *d.FailureClass != "BOX_AT_CAPACITY_DEFERRED" {
		t.Fatalf("failure_class = %q", *d.FailureClass)
	}
	if d.BecameLiveAt != nil {
		t.Fatalf("became_live_at absent on the wire must be nil, got %q", *d.BecameLiveAt)
	}
}

// TestSetEnv: POST /v1/sites/:id/env wraps the map under "env".
func TestSetEnv(t *testing.T) {
	var gotBody map[string]any
	var gotPath string
	c := newFake(t, "sess-abc", func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotBody = readJSON(t, r)
		_, _ = io.WriteString(w, `{"ok":true}`)
	})

	err := c.SetEnv(context.Background(), "site-1", map[string]string{
		"DATABASE_URL": "postgres://x",
		"SECRET":       "k",
	})
	if err != nil {
		t.Fatalf("SetEnv: %v", err)
	}
	if gotPath != "/v1/sites/site-1/env" {
		t.Fatalf("hit %q, want /v1/sites/site-1/env", gotPath)
	}
	envObj, ok := gotBody["env"].(map[string]any)
	if !ok {
		t.Fatalf("body must wrap env under \"env\" key; got %v", gotBody)
	}
	if envObj["DATABASE_URL"] != "postgres://x" || envObj["SECRET"] != "k" {
		t.Fatalf("env body = %v", envObj)
	}
}

// TestAddDomain: POST /v1/sites/:id/domains posts {domain} and returns the site
// with the new array.
func TestAddDomain(t *testing.T) {
	var gotBody map[string]any
	var gotPath string
	c := newFake(t, "sess-abc", func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotBody = readJSON(t, r)
		_, _ = io.WriteString(w, `{"site":{"id":"site-1","slug":"blog","domains":["blog.example.com","www.example.com"]}}`)
	})
	s, err := c.AddDomain(context.Background(), "site-1", "www.example.com")
	if err != nil {
		t.Fatalf("AddDomain: %v", err)
	}
	if gotPath != "/v1/sites/site-1/domains" {
		t.Fatalf("hit %q, want /v1/sites/site-1/domains", gotPath)
	}
	if gotBody["domain"] != "www.example.com" {
		t.Fatalf("domain body = %v", gotBody)
	}
	if len(s.Domains) != 2 {
		t.Fatalf("expected domains array to carry the new entry: %+v", s.Domains)
	}
}

// slowReader delivers its payload after a fixed delay, forcing the request body
// stream to outlast a wall-clock http.Client.Timeout.
type slowReader struct {
	data  []byte
	delay time.Duration
	sent  bool
}

func (s *slowReader) Read(p []byte) (int, error) {
	if s.sent {
		return 0, io.EOF
	}
	time.Sleep(s.delay)
	s.sent = true
	return copy(p, s.data), nil
}

// TestUploadDeploymentArtifactNoWallClockCap pins a property that outlived the
// route it was first written against: an upload path must NOT carry an absolute
// http.Client.Timeout, because that is a deadline over the whole body stream and
// ctx cannot extend it — a big artifact on a slow link would die mid-stream with
// a deadline the caller never asked for.
//
// site-spawner W10: this was TestUploadArtifactNoWallClockCap, aimed at the
// retired site-scoped upload. The property is REPOINTED, not dropped, because
// UploadDeploymentArtifact is now the only upload in the client and inherited the
// same nil-HTTP-means-no-cap construction.
func TestUploadDeploymentArtifactNoWallClockCap(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.ReadAll(r.Body)
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, `{"bytes":7}`)
	}))
	t.Cleanup(srv.Close)

	slow := func() *slowReader {
		return &slowReader{data: []byte("hello!\n"), delay: 250 * time.Millisecond}
	}

	// A wall-clock-capped client kills the slow upload — the pre-fix behavior.
	capped := &Client{BaseURL: srv.URL, Token: "t", HTTP: &http.Client{Timeout: 50 * time.Millisecond}}
	if _, err := capped.UploadDeploymentArtifact(context.Background(), "s", "dep-1", slow(), 7, "abc"); err == nil {
		t.Fatal("a wall-clock-capped client must kill an upload slower than its Timeout")
	}

	// The production path (nil HTTP, no absolute Timeout) completes regardless.
	uncapped := &Client{BaseURL: srv.URL, Token: "t"}
	up, err := uncapped.UploadDeploymentArtifact(context.Background(), "s", "dep-1", slow(), 7, "abc")
	if err != nil {
		t.Fatalf("nil-HTTP upload must have no wall-clock cap: %v", err)
	}
	if up.Bytes != 7 {
		t.Fatalf("decoded ArtifactUpload = %+v", up)
	}
}

// TestUploadDeploymentArtifactNilBody refuses a nil reader (a misuse of the SDK).
// Repointed from TestUploadArtifactNilBody in site-spawner W10 — the same misuse,
// on the surviving upload.
func TestUploadDeploymentArtifactNilBody(t *testing.T) {
	c := &Client{BaseURL: "http://x", Token: "t"}
	if _, err := c.UploadDeploymentArtifact(context.Background(), "site-1", "dep-1", nil, 7, "abc"); err == nil {
		t.Fatal("nil body must error")
	}
}

func TestCreateCheckout(t *testing.T) {
	var gotBody map[string]any
	var gotMethod, gotPath, gotAuth string
	c := newFake(t, "sess-abc", func(w http.ResponseWriter, r *http.Request) {
		gotMethod, gotPath, gotAuth = r.Method, r.URL.Path, r.Header.Get("Authorization")
		gotBody = readJSON(t, r)
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, `{"checkout_url":"https://checkout.stub/abc123"}`)
	})

	resp, err := c.CreateCheckout(context.Background(), "starter")
	if err != nil {
		t.Fatalf("CreateCheckout: %v", err)
	}
	if gotMethod != "POST" || gotPath != "/v1/billing/checkout" {
		t.Fatalf("request = %s %s, want POST /v1/billing/checkout", gotMethod, gotPath)
	}
	if gotAuth != "Bearer sess-abc" {
		t.Fatalf("auth = %q, want Bearer sess-abc", gotAuth)
	}
	// The client posts ONLY {plan} — the team is resolved server-side from the
	// session token, never client-supplied.
	if gotBody["plan"] != "starter" {
		t.Fatalf("checkout body = %v, want plan=starter", gotBody)
	}
	if _, present := gotBody["team_id"]; present {
		t.Fatalf("checkout must NOT send a team_id (server resolves it); got %v", gotBody)
	}
	if resp.CheckoutURL != "https://checkout.stub/abc123" {
		t.Fatalf("decoded CheckoutResp = %+v", resp)
	}
}

func TestCreateCheckout422SurfacesPlanInvalid(t *testing.T) {
	c := newFake(t, "sess-abc", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnprocessableEntity)
		_, _ = io.WriteString(w, `{"error":"plan_invalid"}`)
	})
	_, err := c.CreateCheckout(context.Background(), "nope")
	if err == nil {
		t.Fatal("CreateCheckout with 422 must error")
	}
	if err.Error() != "plan_invalid" {
		t.Fatalf("422 error = %q, want exactly plan_invalid", err)
	}
}

// TestErrorFallbackOnPlainBody confirms a non-2xx without an {"error":…} field
// still surfaces something (never swallowed).
func TestErrorFallbackOnPlainBody(t *testing.T) {
	c := newFake(t, "sess-abc", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = io.WriteString(w, "boom")
	})
	_, err := c.ListBarkparks(context.Background())
	if err == nil || !strings.Contains(err.Error(), "boom") {
		t.Fatalf("plain-body error = %v, want it to carry the body", err)
	}
}

// TestErrorFallbackClampsOnRuneBoundary confirms a >200-byte non-JSON body of
// multibyte runes is clamped without slicing mid-rune — the error stays valid
// UTF-8 and ends with the ellipsis marker.
func TestErrorFallbackClampsOnRuneBoundary(t *testing.T) {
	c := newFake(t, "sess-abc", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = io.WriteString(w, strings.Repeat("æ", 300))
	})
	_, err := c.ListBarkparks(context.Background())
	if err == nil {
		t.Fatal("multibyte 500 body must error")
	}
	if !utf8.ValidString(err.Error()) {
		t.Fatalf("clamped error must stay valid UTF-8; got %q", err.Error())
	}
	if !strings.HasSuffix(err.Error(), "…") {
		t.Fatalf("clamped error must end with the ellipsis marker; got %q", err.Error())
	}
}

// TestVerifyInstanceCompletedRun: a 200 verify envelope decodes into a
// VerifyResult (verdict, probes, null status honored) AND carries the exact
// response bytes in Raw — the `-o json` verbatim contract starts here.
func TestVerifyInstanceCompletedRun(t *testing.T) {
	const envelope = `{"ok":false,"reachable":false,"verified_at":"2026-07-04T10:00:00Z","probes":[` +
		`{"name":"verify.api","ok":false,"reachable":false,"status":null,"latency_ms":5003,"evidence":"instance unreachable"}]}`
	var gotMethod, gotPath, gotAuth string
	c := newFake(t, "sess-abc", func(w http.ResponseWriter, r *http.Request) {
		gotMethod, gotPath, gotAuth = r.Method, r.URL.Path, r.Header.Get("Authorization")
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, envelope)
	})

	res, err := c.VerifyInstance(context.Background(), "bp-1")
	if err != nil {
		t.Fatalf("VerifyInstance: %v", err)
	}
	if gotMethod != "POST" || gotPath != "/v1/barkparks/bp-1/verify" {
		t.Fatalf("hit %s %s, want POST /v1/barkparks/bp-1/verify", gotMethod, gotPath)
	}
	if gotAuth != "Bearer sess-abc" {
		t.Fatalf("auth = %q, want the session bearer", gotAuth)
	}
	if res.OK || res.Reachable {
		t.Fatalf("verdict = ok:%v reachable:%v, want both false", res.OK, res.Reachable)
	}
	if len(res.Probes) != 1 || res.Probes[0].Status != nil {
		t.Fatalf("probes = %+v, want one probe with a nil (null) status", res.Probes)
	}
	if string(res.Raw) != envelope {
		t.Fatalf("Raw must be the envelope bytes verbatim:\n got %q\nwant %q", res.Raw, envelope)
	}
}

// TestVerifyInstanceContractRefusal: a refusal code from the route's closed set
// surfaces as a typed *VerifyError carrying code + detail + HTTP status.
func TestVerifyInstanceContractRefusal(t *testing.T) {
	c := newFake(t, "sess-abc", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusConflict)
		_, _ = io.WriteString(w, `{"error":"not_live"}`)
	})

	_, err := c.VerifyInstance(context.Background(), "bp-1")
	var ve *VerifyError
	if !errors.As(err, &ve) {
		t.Fatalf("err = %v (%T), want *VerifyError", err, err)
	}
	if ve.Code != "not_live" || ve.HTTPStatus != http.StatusConflict {
		t.Fatalf("VerifyError = %+v, want code not_live / 409", ve)
	}
}

// TestVerifyInstance401KeepsUnauthorizedPrefix: a failure OUTSIDE the contract
// set (an expired session) falls back to cloudError — the "unauthorized:"
// prefix survives so the CLI's shared auth handling (exit 3) still fires.
func TestVerifyInstance401KeepsUnauthorizedPrefix(t *testing.T) {
	c := newFake(t, "sess-stale", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = io.WriteString(w, `{"error":"invalid or expired session"}`)
	})

	_, err := c.VerifyInstance(context.Background(), "bp-1")
	if err == nil {
		t.Fatal("401 must error")
	}
	var ve *VerifyError
	if errors.As(err, &ve) {
		t.Fatalf("a 401 is NOT a verify contract refusal, got %+v", ve)
	}
	if !strings.HasPrefix(err.Error(), "unauthorized:") {
		t.Fatalf("error = %q, want the unauthorized: prefix", err.Error())
	}
}

// --- FleetDeployCensus per-call timeout (dr-w33-s2) -------------------------
//
// The census aggregates the whole deploy ledger over the caller's window, so its
// latency grows with the window's WIDTH. On the shared 30s DefaultTimeout the
// reader could not reach the window that contains the epic's own never-covered
// production rows (27 days back): the plane answered 200 in 57.9s under curl
// while the CLI died on `Client.Timeout exceeded while awaiting headers`.
//
// A wall-clock difference of 30s vs 90s is not observable in a unit test without
// actually waiting, so the install is pinned STRUCTURALLY (go/ast over this
// package's own source, the same technique as internal/cli's resource census):
// delete the install line and this test reds. The behavioral half — that the
// copy-the-client pattern still honors an injected client untouched — is pinned
// by TestFleetDeployCensusHonorsInjectedClient below, which is the real
// regression risk of `cc := *c`.

// widestMeasuredCensus is the slowest window the live control plane was
// observed answering HTTP 200 on 2026-08-09 — the 27-day window, the narrowest
// one containing the epic's 3 never-covered production rows. It is the FLOOR the
// cap has to clear; anything at or below it puts the exit gauge's own number
// back out of reach.
const widestMeasuredCensus = 58 * time.Second

func TestFleetDeployCensusTimeoutExceedsDefault(t *testing.T) {
	if FleetDeployCensusTimeout <= DefaultTimeout {
		t.Fatalf("FleetDeployCensusTimeout = %s, must exceed DefaultTimeout %s — the "+
			"27-day window the exit gauge needs answered in 57.9s", FleetDeployCensusTimeout, DefaultTimeout)
	}
	// The load-bearing property is the MEASUREMENT, not the constant. Pinning
	// equality with the two 90s precedents would red on a future bump made for a
	// good reason (a wider window, a slower plane); pinning the measured floor
	// reds only when the cap stops covering the window it exists to reach.
	if FleetDeployCensusTimeout < widestMeasuredCensus {
		t.Fatalf("FleetDeployCensusTimeout = %s, below the widest window measured answering 200 (%s) — "+
			"the census cannot reach the 27-day window that holds the epic's only non-zero",
			FleetDeployCensusTimeout, widestMeasuredCensus)
	}
	// And a cap is still a cap: an unbounded one turns a sick plane into a hung
	// CLI, which is the failure this constant exists to make loud rather than
	// silent. Both precedents in this file sit well inside this band.
	if FleetDeployCensusTimeout > 5*time.Minute {
		t.Fatalf("FleetDeployCensusTimeout = %s exceeds 5m — a cap that large hangs the CLI on a "+
			"sick control plane instead of failing it", FleetDeployCensusTimeout)
	}
	for _, precedent := range []struct {
		name string
		d    time.Duration
	}{{"DomainStatusTimeout", DomainStatusTimeout}, {"VerifyTimeout", VerifyTimeout}} {
		if FleetDeployCensusTimeout < precedent.d {
			t.Fatalf("FleetDeployCensusTimeout = %s, want at least the headroom of its precedent %s (%s) — "+
				"the census is the heaviest read in this file, not the lightest",
				FleetDeployCensusTimeout, precedent.name, precedent.d)
		}
	}
}

// TestFleetDeployCensusInstallsItsOwnTimeout fails if FleetDeployCensus falls
// back to DefaultTimeout — i.e. if the `cc.HTTP = &http.Client{Timeout: ...}`
// install line is removed, or if the request is issued through the original
// receiver instead of the widened copy.
func TestFleetDeployCensusInstallsItsOwnTimeout(t *testing.T) {
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, "client.go", nil, parser.ParseComments)
	if err != nil {
		t.Fatalf("parse client.go: %v", err)
	}
	var body string
	for _, decl := range file.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Name.Name != "FleetDeployCensus" || fn.Recv == nil {
			continue
		}
		var buf bytes.Buffer
		if err := printer.Fprint(&buf, fset, fn.Body); err != nil {
			t.Fatalf("print FleetDeployCensus body: %v", err)
		}
		body = buf.String()
	}
	if body == "" {
		t.Fatal("FleetDeployCensus method not found in client.go")
	}
	if !strings.Contains(body, "FleetDeployCensusTimeout") {
		t.Fatalf("FleetDeployCensus does not install FleetDeployCensusTimeout — it falls back to "+
			"the shared %s DefaultTimeout, which cannot reach the 27-day window.\nbody:\n%s", DefaultTimeout, body)
	}
	if !strings.Contains(body, "cc := *c") {
		t.Fatalf("FleetDeployCensus must widen a COPY of the client (cc := *c), so an injected "+
			"client is honored untouched.\nbody:\n%s", body)
	}
	// `cc.do(` CONTAINS `c.do(`, so a substring check would pass vacuously — match
	// the bare receiver only when it is not preceded by an identifier character.
	if regexp.MustCompile(`(^|[^A-Za-z0-9_])c\.do\(`).MatchString(body) {
		t.Fatalf("FleetDeployCensus still issues its request through the un-widened receiver "+
			"(c.do), so the installed timeout is dead code.\nbody:\n%s", body)
	}
}

// TestFleetDeployCensusHonorsInjectedClient pins the regression risk of the
// copy-the-client pattern: a caller-supplied *http.Client must reach the request
// unchanged — same pointer, same Timeout — and must NOT be replaced by the
// 90s fallback.
func TestFleetDeployCensusHonorsInjectedClient(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, `{"total":5,"never_covered":3,"scope":{"kind":"team"}}`)
	}))
	t.Cleanup(srv.Close)

	rt := &countingTransport{inner: srv.Client().Transport}
	injected := &http.Client{Timeout: 7 * time.Second, Transport: rt}
	c := &Client{BaseURL: srv.URL, Token: "sess", HTTP: injected}

	from := time.Date(2026, 7, 13, 0, 0, 0, 0, time.UTC)
	if _, err := c.FleetDeployCensus(context.Background(), from, from.Add(20*24*time.Hour)); err != nil {
		t.Fatalf("FleetDeployCensus: %v", err)
	}
	if rt.n != 1 {
		t.Fatalf("injected client carried %d requests, want 1 — the census built its own client "+
			"instead of honoring the injected one", rt.n)
	}
	if injected.Timeout != 7*time.Second {
		t.Fatalf("injected client Timeout = %s, want 7s untouched", injected.Timeout)
	}
	if c.HTTP != injected {
		t.Fatal("FleetDeployCensus mutated the receiver's HTTP client; it must widen a copy only")
	}
}

// countingTransport counts the requests that actually travelled through the
// injected client — the only way to prove the injected client was USED rather
// than silently replaced by the lazily-built fallback.
type countingTransport struct {
	inner http.RoundTripper
	n     int
}

func (t *countingTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	t.n++
	inner := t.inner
	if inner == nil {
		inner = http.DefaultTransport
	}
	return inner.RoundTrip(r)
}
