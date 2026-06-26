package cli

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

// seedCloudLogin writes a config under the test's temp config home carrying a
// Cloud token + a control-plane URL, so the authed Cloud commands (barkparks /
// provider / launch / go-live) resolve a client pointed at the fake server.
func seedCloudLogin(t *testing.T, cloudURL string) {
	t.Helper()
	cfg := &Config{
		CloudURL:   cloudURL,
		CloudToken: "sess-abc",
		CloudTeam:  "team-1",
	}
	if err := SaveConfig(cfg); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}
}

// TestLoginWritesCloudToken drives `bp login --email … --password … --url <fake>`
// against a fake control plane and asserts the token + URL land in the temp
// config, and the success line prints.
func TestLoginWritesCloudToken(t *testing.T) {
	withTempConfigHome(t)

	var gotPath, gotAuth string
	var gotBody map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath, gotAuth = r.URL.Path, r.Header.Get("Authorization")
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &gotBody)
		_, _ = io.WriteString(w, `{"token":"sess-xyz","team_id":"team-9"}`)
	}))
	defer srv.Close()

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runLoginCloud(out, []string{
			"--email", "a@b.com",
			"--password", "hunter2",
			"--url", srv.URL,
		})
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	if gotPath != "/v1/auth/login" {
		t.Fatalf("login hit %q, want /v1/auth/login", gotPath)
	}
	if gotAuth != "" {
		t.Fatalf("login must be unauthed; got %q", gotAuth)
	}
	if gotBody["email"] != "a@b.com" || gotBody["password"] != "hunter2" {
		t.Fatalf("login body = %v", gotBody)
	}

	cfg, err := LoadConfig()
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	if cfg.CloudToken != "sess-xyz" {
		t.Fatalf("CloudToken = %q, want sess-xyz", cfg.CloudToken)
	}
	if cfg.CloudURL != srv.URL {
		t.Fatalf("CloudURL = %q, want %q", cfg.CloudURL, srv.URL)
	}
	if cfg.CloudTeam != "team-9" {
		t.Fatalf("CloudTeam = %q, want team-9", cfg.CloudTeam)
	}
	if !bytes.Contains([]byte(stdout), []byte("logged in")) {
		t.Fatalf("expected a success line:\n%s", stdout)
	}
}

// TestLoginBadCredsExitsAuth: a 401 from the control plane is an auth error
// (exit 3) and writes NO token to config.
func TestLoginBadCredsExitsAuth(t *testing.T) {
	withTempConfigHome(t)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = io.WriteString(w, `{"error":"invalid_credentials"}`)
	}))
	defer srv.Close()

	_, stderr, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runLoginCloud(out, []string{"--email", "a@b.com", "--password", "x", "--url", srv.URL})
	})
	if code != exitAuth {
		t.Fatalf("exit = %d, want %d (auth)", code, exitAuth)
	}
	if !bytes.Contains([]byte(stderr), []byte("invalid_credentials")) {
		t.Fatalf("stderr should surface the auth message:\n%s", stderr)
	}
	cfg, _ := LoadConfig()
	if cfg.CloudToken != "" {
		t.Fatalf("a failed login must not persist a token; got %q", cfg.CloudToken)
	}
}

// TestBarkparksHitsControlPlane: with a Cloud token saved, `bp barkparks` queries
// the fake control plane (Bearer attached) and renders the fleet table.
func TestBarkparksHitsControlPlane(t *testing.T) {
	withTempConfigHome(t)

	var gotAuth, gotPath string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth, gotPath = r.Header.Get("Authorization"), r.URL.Path
		_, _ = io.WriteString(w, `{"barkparks":[
			{"id":"bp-1","name":"prod","slug":"prod","url":"https://prod.example.com","mode":"managed","health_status":"up","agent_status":"online","team_id":"team-1"},
			{"id":"bp-2","name":"staging","slug":"staging","host":"staging.example.com","mode":"byo","health_status":"unknown","agent_status":"offline","team_id":"team-1"}
		]}`)
	}))
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runBarkparks(out, nil)
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	if gotPath != "/v1/barkparks" {
		t.Fatalf("hit %q, want /v1/barkparks", gotPath)
	}
	if gotAuth != "Bearer sess-abc" {
		t.Fatalf("auth = %q, want Bearer sess-abc", gotAuth)
	}
	// The rendered table carries the authoritative rows (NAME + HEALTH columns),
	// and the staging row's URL falls back to its host.
	for _, want := range []string{"prod", "https://prod.example.com", "up", "online", "staging", "staging.example.com", "HEALTH", "AGENT"} {
		if !bytes.Contains([]byte(stdout), []byte(want)) {
			t.Fatalf("rendered table missing %q:\n%s", want, stdout)
		}
	}
	// It must NOT fall back to the local-config "no Barkparks known" hint.
	if bytes.Contains([]byte(stdout), []byte("register ssh")) {
		t.Fatalf("token present must use the control plane, not the local hint:\n%s", stdout)
	}
}

// TestBarkparksFallsBackToLocalWithoutToken: no Cloud token → the cloud-11 local
// KnownServers view, no network call.
func TestBarkparksFallsBackToLocalWithoutToken(t *testing.T) {
	withTempConfigHome(t)
	seedTwoBarkparks(t) // local KnownServers, no cloud token

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runBarkparks(out, nil)
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	// Local view shows the KIND column (cloud-11), which the control-plane table
	// does not render.
	if !bytes.Contains([]byte(stdout), []byte("KIND")) {
		t.Fatalf("no token should render the local KIND-column view:\n%s", stdout)
	}
}

// TestGoLivePostsRightBody: `bp go-live --name blog --plan pro` posts the right
// body with the Bearer attached and renders the provisioned row.
func TestGoLivePostsRightBody(t *testing.T) {
	withTempConfigHome(t)

	var gotPath, gotAuth string
	var gotBody map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath, gotAuth = r.URL.Path, r.Header.Get("Authorization")
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &gotBody)
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, `{"barkpark":{"id":"bp-7","name":"blog","url":"https://blog.barkpark.cloud","mode":"managed","health_status":"unknown","agent_status":"offline","team_id":"team-1"}}`)
	}))
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runGoLive(out, []string{"--name", "blog", "--plan", "pro"})
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	if gotPath != "/v1/go-live" {
		t.Fatalf("hit %q, want /v1/go-live", gotPath)
	}
	if gotAuth != "Bearer sess-abc" {
		t.Fatalf("auth = %q, want Bearer sess-abc", gotAuth)
	}
	if gotBody["name"] != "blog" || gotBody["plan"] != "pro" {
		t.Fatalf("go-live body = %v", gotBody)
	}
	if !bytes.Contains([]byte(stdout), []byte("https://blog.barkpark.cloud")) {
		t.Fatalf("rendered confirmation missing the new URL:\n%s", stdout)
	}
}

// TestGoLive422SurfacesNameRequired: the control plane's 422 surfaces in the CLI.
func TestGoLive422SurfacesNameRequired(t *testing.T) {
	withTempConfigHome(t)

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnprocessableEntity)
		_, _ = io.WriteString(w, `{"error":"name_required"}`)
	}))
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	// --name is non-empty client-side (the client requires it), but the server
	// rejects it — proving the 422 path surfaces. We pass a name so we reach the
	// POST rather than the local guard.
	_, stderr, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runGoLive(out, []string{"--name", "blog"})
	})
	if code != exitGeneric {
		t.Fatalf("exit = %d, want %d", code, exitGeneric)
	}
	if !bytes.Contains([]byte(stderr), []byte("name_required")) {
		t.Fatalf("stderr should surface name_required:\n%s", stderr)
	}
}

// TestProviderAddPostsBody: `bp provider add hetzner --token t --label l` posts
// the right body and renders the connected provider.
func TestProviderAddPostsBody(t *testing.T) {
	withTempConfigHome(t)

	var gotPath string
	var gotBody map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &gotBody)
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, `{"provider":{"id":"prov-1","kind":"hetzner","label":"main","team_id":"team-1"}}`)
	}))
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runProvider(out, []string{"add", "hetzner", "--token", "hcloud-tok", "--label", "main"})
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	if gotPath != "/v1/providers" {
		t.Fatalf("hit %q, want /v1/providers", gotPath)
	}
	if gotBody["kind"] != "hetzner" || gotBody["token"] != "hcloud-tok" || gotBody["label"] != "main" {
		t.Fatalf("provider body = %v", gotBody)
	}
	if !bytes.Contains([]byte(stdout), []byte("prov-1")) {
		t.Fatalf("rendered confirmation missing the provider id:\n%s", stdout)
	}
}

// TestLaunchPostsBody: `bp launch hetzner --name shop` posts provider+name.
func TestLaunchPostsBody(t *testing.T) {
	withTempConfigHome(t)

	var gotPath string
	var gotBody map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &gotBody)
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, `{"barkpark":{"id":"bp-9","name":"shop","host":"shop.example.com","mode":"byo","health_status":"unknown","agent_status":"offline","team_id":"team-1"}}`)
	}))
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runLaunch(out, []string{"hetzner", "--name", "shop"})
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0\n%s", code, stdout)
	}
	if gotPath != "/v1/launch" {
		t.Fatalf("hit %q, want /v1/launch", gotPath)
	}
	if gotBody["provider"] != "hetzner" || gotBody["name"] != "shop" {
		t.Fatalf("launch body = %v", gotBody)
	}
}

// TestAuthedCommandsRequireLogin: with NO cloud token, the authed commands fail
// with exit 3 and tell the user to run `bp login`. They must NOT hit the network.
func TestAuthedCommandsRequireLogin(t *testing.T) {
	withTempConfigHome(t) // empty config — no cloud token

	cases := []struct {
		name string
		run  func(out *writer) int
	}{
		{"provider", func(out *writer) int { return runProvider(out, []string{"add", "hetzner", "--token", "t"}) }},
		{"launch", func(out *writer) int { return runLaunch(out, []string{"hetzner", "--name", "x"}) }},
		{"go-live", func(out *writer) int { return runGoLive(out, []string{"--name", "x"}) }},
	}
	for _, tc := range cases {
		_, stderr, code := runCloudCapture(t, false, func(out *writer) int {
			out.output = "table"
			return tc.run(out)
		})
		if code != exitAuth {
			t.Fatalf("%s: exit = %d, want %d (auth)", tc.name, code, exitAuth)
		}
		if !bytes.Contains([]byte(stderr), []byte("bp login")) {
			t.Fatalf("%s: stderr should tell the user to run bp login:\n%s", tc.name, stderr)
		}
	}
}
