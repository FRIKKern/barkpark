package cli

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// logoutServer answers DELETE /v1/auth/logout. It counts a revoked session only
// for the bearer it was given, the way the server counts rows it stamped.
type logoutServer struct {
	mu      sync.Mutex
	live    string
	bearers []string
}

func (s *logoutServer) start(t *testing.T) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "DELETE" || r.URL.Path != "/v1/auth/logout" {
			t.Errorf("unexpected request %s %s", r.Method, r.URL.Path)
			w.WriteHeader(http.StatusNotFound)
			return
		}
		s.mu.Lock()
		defer s.mu.Unlock()
		auth := r.Header.Get("Authorization")
		s.bearers = append(s.bearers, auth)
		if auth == "Bearer "+s.live {
			s.live = ""
			_, _ = w.Write([]byte(`{"ok":true,"revoked":1}`))
			return
		}
		_, _ = w.Write([]byte(`{"ok":true,"revoked":0}`))
	}))
	t.Cleanup(srv.Close)
	return srv
}

func writeSessionFile(t *testing.T, token string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "session.token")
	if err := os.WriteFile(p, []byte(token+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

// `bp logout --help` parses --help as a global. It must print help and leave
// the saved session alone. It used to log out.
func TestLogoutHelpFlagPrintsHelpAndKeepsTheSession(t *testing.T) {
	isolateSSOConfig(t)
	if err := SaveConfig(&Config{CloudURL: "https://api.barkpark.cloud", CloudToken: "cloud-sess"}); err != nil {
		t.Fatal(err)
	}
	var so, se bytes.Buffer
	if code := runLogout(newWriter(&so, &se), globals{help: true}, nil); code != exitOK {
		t.Fatalf("exit = %d; %s", code, se.String())
	}
	if !strings.Contains(so.String(), "USAGE") || !strings.Contains(so.String(), "--token-file") {
		t.Fatalf("help not printed:\n%s", so.String())
	}
	cfg, _ := LoadConfig()
	if cfg.CloudToken != "cloud-sess" {
		t.Fatalf("--help logged out: CloudToken = %q", cfg.CloudToken)
	}
}

// `bp logout -s <host> --token-file <file>` revokes the session in the file,
// such as one tooling/entra-signin saved, and drops a config copy of it.
func TestLogoutTokenFileRevokesThatSession(t *testing.T) {
	isolateSSOConfig(t)
	ls := &logoutServer{live: "sess-from-file"}
	srv := ls.start(t)
	if err := SaveConfig(&Config{Server: srv.URL, Token: "sess-from-file"}); err != nil {
		t.Fatal(err)
	}
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	w.output = "table"
	code := runLogout(w, globals{server: srv.URL}, []string{"--token-file", writeSessionFile(t, "sess-from-file")})
	if code != exitOK {
		t.Fatalf("exit = %d; %s %s", code, so.String(), se.String())
	}
	if len(ls.bearers) != 1 || ls.bearers[0] != "Bearer sess-from-file" {
		t.Fatalf("bearers sent = %v", ls.bearers)
	}
	if ls.live != "" {
		t.Fatalf("session still live on the server")
	}
	cfg, _ := LoadConfig()
	if cfg.Token != "" {
		t.Fatalf("config still holds the revoked token")
	}
	if !strings.Contains(so.String(), "revoked the session") {
		t.Fatalf("receipt = %q", so.String())
	}
}

// A token the server does not revoke is a failure, not a quiet success.
func TestLogoutTokenFileExitsOneWhenNothingIsRevoked(t *testing.T) {
	isolateSSOConfig(t)
	ls := &logoutServer{live: "some-other-session"}
	srv := ls.start(t)
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	w.output = "table"
	code := runLogout(w, globals{server: srv.URL}, []string{"--token-file=" + writeSessionFile(t, "dead-session")})
	if code != exitGeneric {
		t.Fatalf("exit = %d, want %d; %s %s", code, exitGeneric, so.String(), se.String())
	}
	if ls.live == "" {
		t.Fatalf("revoked the wrong session")
	}
}

// With nothing saved for the server, logout says how to end a session that
// lives in a file instead of only reporting was_logged_in false.
func TestLogoutWithNothingSavedNamesTokenFile(t *testing.T) {
	isolateSSOConfig(t)
	var so, se bytes.Buffer
	w := newWriter(&so, &se)
	w.output = "table"
	if code := runLogout(w, globals{server: "https://barkpark.example.com"}, nil); code != exitOK {
		t.Fatalf("exit = %d", code)
	}
	if !strings.Contains(se.String(), "bp logout -s https://barkpark.example.com --token-file <file>") {
		t.Fatalf("stderr = %q", se.String())
	}
}

func TestLogoutRefusesUnknownArgument(t *testing.T) {
	isolateSSOConfig(t)
	var so, se bytes.Buffer
	if code := runLogout(newWriter(&so, &se), globals{}, []string{"--bogus"}); code != exitUsage {
		t.Fatalf("exit = %d, want %d", code, exitUsage)
	}
}

// `-s <saved server>` carries that entry's token above the env layer. For
// `bp auth logout` the exported session token must win, or the command revokes
// nothing. An explicit --token still wins over the env.
func TestAuthLogoutSendsTheExportedSessionToken(t *testing.T) {
	isolateSSOConfig(t)
	t.Setenv("BARKPARK_TOKEN", "exported-session")
	ctx := authLogoutContext(globals{server: "run5"}, manifest.Context{Token: "saved-admin"})
	if ctx.Token != "exported-session" {
		t.Fatalf("token = %q, want the exported session", ctx.Token)
	}
	ctx = authLogoutContext(globals{token: "flag-session"}, manifest.Context{Token: "flag-session"})
	if ctx.Token != "flag-session" {
		t.Fatalf("token = %q, want the --token value", ctx.Token)
	}
	t.Setenv("BARKPARK_TOKEN", "")
	ctx = authLogoutContext(globals{}, manifest.Context{Token: "saved-session"})
	if ctx.Token != "saved-session" {
		t.Fatalf("token = %q, want the saved token", ctx.Token)
	}
}
