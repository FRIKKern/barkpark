package cloudclient

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
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
