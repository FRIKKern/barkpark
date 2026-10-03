package cli

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// instance_admin_token_cmd_test.go — `bp instance admin-token`
// (task-7d4d405e0ee4bcbf, criterion 1). ONE httptest server plays both Barkpark
// Cloud (the credentials route) and the instance (identity, the elevated mint,
// and the connect probe), and records every request so the tests can prove
// what was — and was never — sent.

const (
	cloudHeldSecret = "cloud-held-secret-DO-NOT-LEAK"
	newAdminSecret  = "new-admin-secret"
)

type adminTokenFake struct {
	*httptest.Server
	mu         sync.Mutex
	requests   []string // "METHOD path"
	mintBearer string
	mintBody   map[string]any

	identityStatus int    // 0 → 200 with workspace "acme"
	mintStatus     int    // 0 → 201
	mintResp       string // "" → a full receipt
}

func newAdminTokenFake(t *testing.T) *adminTokenFake {
	t.Helper()
	f := &adminTokenFake{}
	f.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		f.requests = append(f.requests, r.Method+" "+r.URL.Path)
		f.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		switch {
		case strings.HasSuffix(r.URL.Path, "/credentials"):
			_, _ = io.WriteString(w, `{"admin_token":"`+cloudHeldSecret+`","url":"`+f.URL+`","host":""}`)
		case r.URL.Path == "/v1/tokens/current":
			if f.identityStatus != 0 {
				w.WriteHeader(f.identityStatus)
				_, _ = io.WriteString(w, `{"error":{"code":"unauthorized","message":"invalid token"}}`)
				return
			}
			_, _ = io.WriteString(w, `{"token":{"id":"t-cloud","label":"barkpark cloud admin","permissions":["read","write","admin"],"workspace":"acme"},"memberships":[{"workspace_id":"w1","workspace_slug":"acme","role":"admin"}]}`)
		case r.Method == "POST" && strings.HasSuffix(r.URL.Path, "/v1/tokens/elevated"):
			f.mu.Lock()
			f.mintBearer = r.Header.Get("Authorization")
			b, _ := io.ReadAll(r.Body)
			_ = json.Unmarshal(b, &f.mintBody)
			f.mu.Unlock()
			if f.mintStatus != 0 {
				w.WriteHeader(f.mintStatus)
				_, _ = io.WriteString(w, f.mintResp)
				return
			}
			w.WriteHeader(http.StatusCreated)
			_, _ = io.WriteString(w, `{"token":"`+newAdminSecret+`","id":"t-new","label":"`+labelOf(f.mintBody)+`","permissions":["read","write","admin"],"dataset":"production","workspace":"acme","expires_at":null}`)
		case r.URL.Path == "/v1/capabilities":
			_, _ = io.WriteString(w, `{"auth_tier":"admin","server":{"name":"acme-park","version":"1.0"}}`)
		case r.URL.Path == "/v1/meta":
			_, _ = io.WriteString(w, `{"serverTime":"2026-10-03T00:00:00Z","minApiVersion":"1","maxApiVersion":"1"}`)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(f.Close)
	return f
}

func labelOf(m map[string]any) string {
	s, _ := m["label"].(string)
	return s
}

func (f *adminTokenFake) sent() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.requests...)
}

// loggedInto saves a Cloud session pointing at the fake plane.
func loggedInto(t *testing.T, cloudURL string) {
	t.Helper()
	withTempConfigHome(t)
	t.Setenv(CloudTokenEnv, "")
	if err := SaveConfig(&Config{CloudURL: cloudURL, CloudToken: "sess-abc"}); err != nil {
		t.Fatalf("save config: %v", err)
	}
}

func runAdminToken(t *testing.T, output string, args ...string) (string, string, int) {
	t.Helper()
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	if output != "" {
		w.output = output
	}
	code := runInstanceAdminToken(w, globals{}, args)
	return so.String(), se.String(), code
}

func assertNoRotateOrRevoke(t *testing.T, f *adminTokenFake) {
	t.Helper()
	for _, r := range f.sent() {
		if strings.Contains(r, "/rotate") || strings.HasPrefix(r, "DELETE ") {
			t.Errorf("Cloud's credential must never be rotated or revoked; saw %q", r)
		}
	}
}

func TestInstanceAdminTokenRefusesWithNoSinkBeforeAnyRequest(t *testing.T) {
	f := newAdminTokenFake(t)
	loggedInto(t, f.URL)

	_, stderr, code := runAdminToken(t, "", "inst-1")

	if code != exitUsage {
		t.Fatalf("exit = %d, want usage", code)
	}
	if !strings.Contains(stderr, "--install") {
		t.Errorf("refusal does not name the sinks: %q", stderr)
	}
	if n := len(f.sent()); n != 0 {
		t.Errorf("%d requests were sent; a refused run must send none: %v", n, f.sent())
	}
}

func TestInstanceAdminTokenInstallMintsANewTokenAndSavesOnlyIt(t *testing.T) {
	f := newAdminTokenFake(t)
	loggedInto(t, f.URL)

	stdout, stderr, code := runAdminToken(t, "", "inst-1", "--install", "--label", "laptop-admin", "--no-expiry")
	if code != exitOK {
		t.Fatalf("exit = %d\nstdout=%s\nstderr=%s", code, stdout, stderr)
	}

	// Cloud's credential was the bearer of the mint, and nothing else.
	if f.mintBearer != "Bearer "+cloudHeldSecret {
		t.Errorf("mint bearer = %q, want Cloud's stored credential as the bootstrap", f.mintBearer)
	}
	perms, _ := f.mintBody["permissions"].([]any)
	if len(perms) != 3 || f.mintBody["label"] != "laptop-admin" || f.mintBody["no_expiry"] != true {
		t.Errorf("mint body = %v, want label laptop-admin, read/write/admin, no_expiry", f.mintBody)
	}
	var mintPath string
	for _, r := range f.sent() {
		if strings.HasSuffix(r, "/v1/tokens/elevated") {
			mintPath = r
		}
	}
	if mintPath != "POST /w/acme/p/default/v1/tokens/elevated" {
		t.Errorf("mint went to %q, want the workspace Cloud's credential belongs to", mintPath)
	}
	assertNoRotateOrRevoke(t, f)

	// The bp config holds the NEW token for that server — never Cloud's.
	cfg, err := LoadConfig()
	if err != nil {
		t.Fatalf("load config: %v", err)
	}
	entry, ok := cfg.FindServer(f.URL)
	if !ok {
		t.Fatalf("no server entry for %s after --install", f.URL)
	}
	if entry.Token != newAdminSecret {
		t.Errorf("saved token = %q, want the newly minted one", entry.Token)
	}
	cfgPath, err := ConfigPath()
	if err != nil {
		t.Fatalf("config path: %v", err)
	}
	raw, err := os.ReadFile(cfgPath)
	if err != nil || !bytes.Contains(raw, []byte(newAdminSecret)) {
		t.Fatalf("could not read the saved config back (%v) — the leak check below would be vacuous", err)
	}
	if bytes.Contains(raw, []byte(cloudHeldSecret)) {
		t.Errorf("Cloud's credential was written to the bp config")
	}

	// Neither secret reaches the terminal without --reveal.
	for _, s := range []string{cloudHeldSecret, newAdminSecret} {
		if strings.Contains(stdout+stderr, s) {
			t.Errorf("output carries a secret (%q) without --reveal:\n%s\n%s", s, stdout, stderr)
		}
	}
	if !strings.Contains(stdout, "minted a new admin token") {
		t.Errorf("no receipt:\n%s", stdout)
	}
}

func TestInstanceAdminTokenRevealJSONCarriesOnlyTheNewSecret(t *testing.T) {
	f := newAdminTokenFake(t)
	loggedInto(t, f.URL)

	stdout, stderr, code := runAdminToken(t, "json", "inst-1", "--reveal")
	if code != exitOK {
		t.Fatalf("exit = %d: %s", code, stderr)
	}
	var got map[string]any
	if err := json.Unmarshal([]byte(stdout), &got); err != nil {
		t.Fatalf("stdout is not JSON: %v\n%s", err, stdout)
	}
	if got["token"] != newAdminSecret || got["installed"] != false {
		t.Errorf("json = %v, want the new token and installed=false", got)
	}
	if strings.Contains(stdout+stderr, cloudHeldSecret) {
		t.Errorf("Cloud's credential leaked into the output")
	}
}

func TestInstanceAdminTokenOutWritesA0600FileAndRefusesAnExistingPath(t *testing.T) {
	f := newAdminTokenFake(t)
	loggedInto(t, f.URL)
	dir := t.TempDir()

	existing := filepath.Join(dir, "taken")
	if err := os.WriteFile(existing, []byte("live"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, _, code := runAdminToken(t, "", "inst-1", "--out", existing); code != exitUsage {
		t.Fatalf("an existing --out path must be refused, exit = %d", code)
	}
	if n := len(f.sent()); n != 0 {
		t.Fatalf("a refused --out sent %d requests", n)
	}

	path := filepath.Join(dir, "admin.token")
	stdout, stderr, code := runAdminToken(t, "", "inst-1", "--out", path)
	if code != exitOK {
		t.Fatalf("exit = %d: %s", code, stderr)
	}
	b, err := os.ReadFile(path)
	if err != nil || strings.TrimSpace(string(b)) != newAdminSecret {
		t.Fatalf("file = %q (%v), want the new secret", string(b), err)
	}
	if st, _ := os.Stat(path); st.Mode().Perm() != 0o600 {
		t.Errorf("mode = %v, want 0600", st.Mode().Perm())
	}
	if strings.Contains(stdout, newAdminSecret) {
		t.Errorf("--out must not also print the secret")
	}
}

func TestInstanceAdminTokenStopsWhenTheBoxNoLongerAcceptsCloudsCredential(t *testing.T) {
	f := newAdminTokenFake(t)
	f.identityStatus = http.StatusUnauthorized
	loggedInto(t, f.URL)

	_, stderr, code := runAdminToken(t, "", "inst-1", "--install")

	if code == exitOK {
		t.Fatalf("exit 0 with a dead bootstrap credential")
	}
	if !strings.Contains(stderr, "no longer accepts the credential Cloud stores") {
		t.Errorf("the dead-credential state is not named: %q", stderr)
	}
	for _, r := range f.sent() {
		if strings.HasSuffix(r, "/v1/tokens/elevated") {
			t.Errorf("minted with a credential the box rejects: %v", f.sent())
		}
	}
}

func TestInstanceAdminTokenRendersTheServersRefusalAndCleansUp(t *testing.T) {
	f := newAdminTokenFake(t)
	f.mintStatus = http.StatusForbidden
	f.mintResp = `{"error":{"code":"forbidden","reason":"admin_required","message":"minting a write or admin token needs a token that holds the admin permission"}}`
	loggedInto(t, f.URL)
	path := filepath.Join(t.TempDir(), "admin.token")

	stdout, stderr, code := runAdminToken(t, "", "inst-1", "--out", path)

	if code == exitOK {
		t.Fatalf("exit 0 on a 403")
	}
	if !strings.Contains(stdout+stderr, "admin permission") {
		t.Errorf("the server's refusal is not shown: %s %s", stdout, stderr)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Errorf("a failed mint left %s behind", path)
	}
}

func TestInstanceAdminTokenArgRefusals(t *testing.T) {
	for _, tc := range [][]string{
		{"--install"},                   // no id
		{"i", "--out", "x", "--reveal"}, // two printing sinks
		{"i", "--install", "--expires-in", "30d", "--no-expiry"},
		{"i", "--install", "--bogus", "v"},
		{"i", "j", "--install"},
	} {
		if _, err := parseInstanceAdminTokenArgs(tc); err == nil {
			t.Errorf("accepted %v", tc)
		}
	}
	a, err := parseInstanceAdminTokenArgs([]string{"i", "--install"})
	if err != nil || !strings.HasPrefix(a.label, "bp admin-token (") {
		t.Errorf("default label = %q (%v)", a.label, err)
	}
}
