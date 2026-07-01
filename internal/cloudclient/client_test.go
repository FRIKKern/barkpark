package cloudclient

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
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

func TestGetCredentials(t *testing.T) {
	var gotAuth, gotMethod, gotPath string
	c := newFake(t, "sess-xyz", func(w http.ResponseWriter, r *http.Request) {
		gotAuth, gotMethod, gotPath = r.Header.Get("Authorization"), r.Method, r.URL.Path
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
	if creds.AdminToken != "bp_admin_secret-bearer" || creds.URL != "https://prod.example.com" || creds.Host != "203.0.113.7" {
		t.Fatalf("credentials decoded wrong: %+v", creds)
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

// TestListDeployments: GET /v1/sites/:id/deployments newest-first.
func TestListDeployments(t *testing.T) {
	var gotPath string
	c := newFake(t, "sess-abc", func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		_, _ = io.WriteString(w, `{"deployments":[
			{"id":"dep-2","site_id":"site-1","status":"live","image_tag":"sha:b","inserted_at":"2026-06-26T02:00:00Z"},
			{"id":"dep-1","site_id":"site-1","status":"failed","failure_reason":"boom","inserted_at":"2026-06-26T01:00:00Z"}
		]}`)
	})
	ds, err := c.ListDeployments(context.Background(), "site-1")
	if err != nil {
		t.Fatalf("ListDeployments: %v", err)
	}
	if gotPath != "/v1/sites/site-1/deployments" {
		t.Fatalf("hit %q, want /v1/sites/site-1/deployments", gotPath)
	}
	if len(ds) != 2 || ds[0].Status != "live" || ds[1].FailureReason != "boom" {
		t.Fatalf("decoded deployments = %+v", ds)
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

// TestUploadArtifact exercises the streaming tarball upload (P7).
func TestUploadArtifact(t *testing.T) {
	var gotPath, gotCT, gotAuth string
	var gotBody []byte
	c := newFake(t, "sess-abc", func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotCT = r.Header.Get("Content-Type")
		gotAuth = r.Header.Get("Authorization")
		gotBody, _ = io.ReadAll(r.Body)
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, `{"artifact_url":"file:///tmp/x.tar.gz","bytes":7,"filename":"x.tar.gz"}`)
	})

	body := strings.NewReader("hello!\n")
	up, err := c.UploadArtifact(context.Background(), "site-1", body)
	if err != nil {
		t.Fatalf("UploadArtifact: %v", err)
	}
	if gotPath != "/v1/sites/site-1/artifact" {
		t.Fatalf("hit %q, want /v1/sites/site-1/artifact", gotPath)
	}
	if gotCT != "application/octet-stream" {
		t.Fatalf("content-type = %q, want application/octet-stream", gotCT)
	}
	if gotAuth != "Bearer sess-abc" {
		t.Fatalf("auth = %q, want Bearer sess-abc", gotAuth)
	}
	if string(gotBody) != "hello!\n" {
		t.Fatalf("body = %q, want %q", string(gotBody), "hello!\n")
	}
	if up.ArtifactURL != "file:///tmp/x.tar.gz" || up.Bytes != 7 || up.Filename != "x.tar.gz" {
		t.Fatalf("decoded ArtifactUpload = %+v", up)
	}
}

// TestUploadArtifact413 surfaces the control plane's 413 too-large response.
func TestUploadArtifact413(t *testing.T) {
	c := newFake(t, "sess-abc", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusRequestEntityTooLarge)
		_, _ = io.WriteString(w, `{"error":"artifact_too_large","max_bytes":104857600}`)
	})
	_, err := c.UploadArtifact(context.Background(), "site-1", strings.NewReader("x"))
	if err == nil || !strings.Contains(err.Error(), "artifact_too_large") {
		t.Fatalf("413 should surface artifact_too_large; got %v", err)
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

// TestUploadArtifactNoWallClockCap pins the fix: the upload path must NOT carry
// an absolute http.Client.Timeout (which ctx cannot extend), so a body that
// streams longer than such a cap still completes. A client whose Timeout is set
// (mimicking the old shared 30s DefaultTimeout, scaled down) dies mid-stream;
// the production path (nil HTTP → no Timeout) rides the ctx only and succeeds.
func TestUploadArtifactNoWallClockCap(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.ReadAll(r.Body)
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, `{"artifact_url":"file:///tmp/x.tar.gz","bytes":7,"filename":"x.tar.gz"}`)
	}))
	t.Cleanup(srv.Close)

	// A wall-clock-capped client kills the slow upload — the pre-fix behavior.
	capped := &Client{BaseURL: srv.URL, Token: "t", HTTP: &http.Client{Timeout: 50 * time.Millisecond}}
	if _, err := capped.UploadArtifact(context.Background(), "s", &slowReader{data: []byte("hello!\n"), delay: 250 * time.Millisecond}); err == nil {
		t.Fatal("a wall-clock-capped client must kill an upload slower than its Timeout")
	}

	// The production path (nil HTTP, no absolute Timeout) completes regardless.
	uncapped := &Client{BaseURL: srv.URL, Token: "t"}
	up, err := uncapped.UploadArtifact(context.Background(), "s", &slowReader{data: []byte("hello!\n"), delay: 250 * time.Millisecond})
	if err != nil {
		t.Fatalf("nil-HTTP upload must have no wall-clock cap: %v", err)
	}
	if up.ArtifactURL != "file:///tmp/x.tar.gz" {
		t.Fatalf("decoded ArtifactUpload = %+v", up)
	}
}

// TestUploadArtifactNilBody refuses a nil reader (a misuse of the SDK).
func TestUploadArtifactNilBody(t *testing.T) {
	c := &Client{BaseURL: "http://x", Token: "t"}
	if _, err := c.UploadArtifact(context.Background(), "site-1", nil); err == nil {
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
