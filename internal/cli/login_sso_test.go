package cli

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"
)

const ssoTestSession = "session-secret-value"

// fakeSSOInstance answers the three routes `bp login --sso` and `bp logout`
// use, and records what the CLI sent.
type fakeSSOInstance struct {
	mu          sync.Mutex
	startStatus int
	exchanged   map[string]string
	loggedOut   string
}

func (f *fakeSSOInstance) handler(t *testing.T) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		switch {
		case r.Method == "GET" && r.URL.Path == "/v1/auth/oidc/pensum/start":
			if f.startStatus != 0 {
				w.WriteHeader(f.startStatus)
				return
			}
			http.Redirect(w, r, "https://idp.example.com/authorize", http.StatusFound)
		case r.Method == "POST" && r.URL.Path == "/v1/auth/sso/exchange":
			body, _ := io.ReadAll(r.Body)
			_ = json.Unmarshal(body, &f.exchanged)
			w.WriteHeader(http.StatusCreated)
			_, _ = w.Write([]byte(`{"token":"` + ssoTestSession + `","user":{"id":"u1","email":"owner@example.com"},"expires_at":"2026-11-26T12:00:00Z","idp_mfa":true}`))
		case r.Method == "DELETE" && r.URL.Path == "/v1/auth/logout":
			f.loggedOut = r.Header.Get("Authorization")
			_, _ = w.Write([]byte(`{"ok":true,"revoked":1}`))
		default:
			t.Errorf("unexpected request %s %s", r.Method, r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
		}
	})
}

func isolateSSOConfig(t *testing.T) {
	t.Helper()
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	for _, n := range append(append([]string{}, ServerEnvNames...), TokenEnvNames...) {
		t.Setenv(n, "")
	}
}

// stubBrowser plays the browser: it follows the start URL's return_to with a
// ticket and the given state (the state from the URL when empty).
func ssoBrowser(t *testing.T, states ...string) chan int {
	t.Helper()
	codes := make(chan int, 8)
	prev := browserOpener
	browserOpener = func(start string) error {
		u, err := url.Parse(start)
		if err != nil {
			return err
		}
		q := u.Query()
		go func() {
			for _, s := range append(states, q.Get("state")) {
				resp, err := http.Get(q.Get("return_to") + "?" + url.Values{"ticket": {"bplt_x"}, "state": {s}}.Encode())
				if err != nil {
					t.Errorf("callback: %v", err)
					return
				}
				resp.Body.Close()
				codes <- resp.StatusCode
			}
		}()
		return nil
	}
	t.Cleanup(func() { browserOpener = prev })
	return codes
}

func TestLoginSSOSavesTheSessionAndNeverPrintsIt(t *testing.T) {
	isolateSSOConfig(t)
	f := &fakeSSOInstance{}
	srv := httptest.NewServer(f.handler(t))
	defer srv.Close()

	var start string
	prev := browserOpener
	codes := ssoBrowser(t, "wrong-state")
	inner := browserOpener
	browserOpener = func(u string) error { start = u; return inner(u) }
	defer func() { browserOpener = prev }()

	var so, se bytes.Buffer
	code := ssoLogin(newWriter(&so, &se), srv.URL, []string{"--sso", "--org", "pensum"})
	if code != exitOK {
		t.Fatalf("exit = %d; stdout=%q stderr=%q", code, so.String(), se.String())
	}

	u, _ := url.Parse(start)
	q := u.Query()
	rt, _ := url.Parse(q.Get("return_to"))
	if rt.Scheme != "http" || rt.Hostname() != "127.0.0.1" || rt.Port() == "" || rt.Path != "/callback" {
		t.Errorf("return_to = %q, want http://127.0.0.1:<port>/callback", q.Get("return_to"))
	}
	if q.Get("code_challenge_method") != "S256" || q.Get("state") == "" {
		t.Errorf("start query = %v", q)
	}
	sum := sha256.Sum256([]byte(f.exchanged["code_verifier"]))
	if base64.RawURLEncoding.EncodeToString(sum[:]) != q.Get("code_challenge") {
		t.Errorf("the verifier sent to the exchange does not answer the challenge")
	}
	if f.exchanged["audience"] != "bp-cli" || f.exchanged["ticket"] != "bplt_x" {
		t.Errorf("exchange body = %v", f.exchanged)
	}
	if first := <-codes; first != http.StatusBadRequest {
		t.Errorf("a callback with the wrong state answered %d, want 400", first)
	}

	all := so.String() + se.String()
	if strings.Contains(all, ssoTestSession) {
		t.Fatalf("the session token was printed: %q", all)
	}
	for _, want := range []string{"owner@example.com", "2026-11-26T12:00:00Z", "reported MFA"} {
		if !strings.Contains(so.String(), want) {
			t.Errorf("stdout lacks %q: %q", want, so.String())
		}
	}

	cfg, err := LoadConfig()
	if err != nil {
		t.Fatal(err)
	}
	entry, ok := cfg.FindServer(srv.URL)
	if !ok || entry.Token != ssoTestSession || entry.SSOOrg != "pensum" {
		t.Fatalf("saved entry = %+v (found %v)", entry, ok)
	}
	if cfg.Server != srv.URL || cfg.Token != ssoTestSession {
		t.Errorf("the server was not made active: server=%q", cfg.Server)
	}

	// bp logout revokes the session on the server and drops it from config.
	so.Reset()
	se.Reset()
	if code := runLogout(newWriter(&so, &se), globals{server: srv.URL}, nil); code != exitOK {
		t.Fatalf("logout exit = %d; %q %q", code, so.String(), se.String())
	}
	if f.loggedOut != "Bearer "+ssoTestSession {
		t.Errorf("logout did not revoke the saved session on the server")
	}
	cfg, _ = LoadConfig()
	entry, _ = cfg.FindServer(srv.URL)
	if entry.Token != "" || entry.SSOOrg != "" || cfg.Token != "" {
		t.Errorf("logout left the session in config: entry=%+v", entry)
	}
	if !strings.Contains(so.String(), "revoked the SSO session") {
		t.Errorf("logout receipt = %q", so.String())
	}
}

func TestLoginSSONamesAnInstanceWithoutLoopbackSupport(t *testing.T) {
	isolateSSOConfig(t)
	f := &fakeSSOInstance{startStatus: http.StatusBadRequest}
	srv := httptest.NewServer(f.handler(t))
	defer srv.Close()

	opened := false
	prev := browserOpener
	browserOpener = func(string) error { opened = true; return nil }
	defer func() { browserOpener = prev }()

	var so, se bytes.Buffer
	code := ssoLogin(newWriter(&so, &se), srv.URL, []string{"--sso", "--org=pensum"})
	if code == exitOK || opened {
		t.Fatalf("exit = %d, browser opened = %v", code, opened)
	}
	if !strings.Contains(se.String(), "predates `bp login --sso`") {
		t.Errorf("stderr = %q", se.String())
	}
}

func TestLoginSSONoBrowserPrintsTheURL(t *testing.T) {
	isolateSSOConfig(t)
	f := &fakeSSOInstance{}
	srv := httptest.NewServer(f.handler(t))
	defer srv.Close()

	opened := false
	prev := browserOpener
	browserOpener = func(string) error { opened = true; return nil }
	defer func() { browserOpener = prev }()
	prevWait := ssoLoginWait
	ssoLoginWait = 200 * time.Millisecond
	defer func() { ssoLoginWait = prevWait }()

	var so, se bytes.Buffer
	code := ssoLogin(newWriter(&so, &se), srv.URL, []string{"--sso", "--org", "pensum", "--no-browser"})
	if opened {
		t.Errorf("--no-browser started a browser")
	}
	if code == exitOK {
		t.Errorf("a sign-in that never arrived exited 0")
	}
	if !strings.Contains(se.String(), srv.URL+"/v1/auth/oidc/pensum/start?") {
		t.Errorf("the start URL was not printed: %q", se.String())
	}
}

func TestLoginSSONeedsAnOrg(t *testing.T) {
	if _, err := parseLoginSSOArgs([]string{"--sso"}); err == nil {
		t.Error("--sso without --org parsed")
	}
	if _, err := parseLoginSSOArgs([]string{"--sso", "--org", "x", "--email", "a"}); err == nil {
		t.Error("--email beside --sso parsed")
	}
	if !wantsSSOLogin([]string{"--org", "x", "--sso"}) || wantsSSOLogin([]string{"--device"}) {
		t.Error("wantsSSOLogin")
	}
}
