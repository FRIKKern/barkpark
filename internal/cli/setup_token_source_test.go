package cli

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// setup_token_source_test.go covers `bp setup --target connect --token -` and
// `--token-file <path>`: the token reaches the saved server without argv, and
// --keep-active still leaves the active server as it was.

// tokenServer answers /v1/capabilities with admin only for the wanted token.
func tokenServer(t *testing.T, want string) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		tier := "none"
		if r.Header.Get("Authorization") == "Bearer "+want {
			tier = "admin"
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"auth_tier":"` + tier + `","manifest_version":"1","server":{"name":"barkpark","version":"0.1.0"},"commands":[]}`))
	}))
	t.Cleanup(srv.Close)
	return srv
}

func runSetupHuman(t *testing.T, g globals, tail []string) (string, string, int) {
	t.Helper()
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	g.output, g.outputSet = "table", true
	w.applyGlobals(g)
	code := runSetup(w, g, tail)
	return stdout.String(), stderr.String(), code
}

func stubSecretStdin(t *testing.T, s string) {
	t.Helper()
	old := secretStdinReader
	secretStdinReader = strings.NewReader(s)
	t.Cleanup(func() { secretStdinReader = old })
}

func savedToken(t *testing.T, server string) string {
	t.Helper()
	cfg, err := LoadConfig()
	if err != nil {
		t.Fatal(err)
	}
	e, ok := cfg.FindServer(server)
	if !ok {
		t.Fatalf("%s is not saved", server)
	}
	return e.Token
}

func TestSetupConnectTokenFromStdinKeepsActive(t *testing.T) {
	withTempConfigHome(t)
	active := seedActiveServer(t)
	const tok = "bp_admin_stdin_0123456789"
	srv := tokenServer(t, tok)
	stubSecretStdin(t, tok+"\n")

	stdout, stderr, code := runSetupHuman(t, globals{}, []string{"--target", "connect", "--server", srv.URL, "--token", "-", "--keep-active", "--name", "box"})
	if code != exitOK {
		t.Fatalf("exit %d\nstdout %s\nstderr %s", code, stdout, stderr)
	}
	if got := savedToken(t, srv.URL); got != tok {
		t.Fatalf("saved token is %q, want the one from stdin", got)
	}
	if strings.Contains(stdout+stderr, tok) {
		t.Fatalf("setup printed the token:\n%s%s", stdout, stderr)
	}
	cfg, _ := LoadConfig()
	if cfg.Server != active {
		t.Fatalf("active server is %q, want %q kept by --keep-active", cfg.Server, active)
	}
}

func TestSetupConnectGlobalTokenDashReadsStdin(t *testing.T) {
	withTempConfigHome(t)
	const tok = "bp_admin_global_dash"
	srv := tokenServer(t, tok)
	stubSecretStdin(t, tok)
	if _, stderr, code := runSetupHuman(t, globals{token: "-"}, []string{"--target", "connect", "--server", srv.URL}); code != exitOK {
		t.Fatalf("exit %d: %s", code, stderr)
	}
	if got := savedToken(t, srv.URL); got != tok {
		t.Fatalf("saved token is %q", got)
	}
}

func TestSetupConnectTokenFile(t *testing.T) {
	withTempConfigHome(t)
	const tok = "bp_admin_file_token"
	srv := tokenServer(t, tok)
	file := filepath.Join(t.TempDir(), "admin-token")
	if err := os.WriteFile(file, []byte("  "+tok+"\r\nsecond line\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, stderr, code := runSetupHuman(t, globals{}, []string{"--target", "connect", "--server", srv.URL, "--token-file", file, "--keep-active"}); code != exitOK {
		t.Fatalf("exit %d: %s", code, stderr)
	}
	if got := savedToken(t, srv.URL); got != tok {
		t.Fatalf("saved token is %q", got)
	}
}

func TestSetupConnectTokenSourceErrors(t *testing.T) {
	withTempConfigHome(t)
	srv := tokenServer(t, "x")
	empty := filepath.Join(t.TempDir(), "empty")
	_ = os.WriteFile(empty, nil, 0o600)
	for name, c := range map[string]struct {
		g     globals
		tail  []string
		stdin string
		want  string
	}{
		"empty stdin":     {tail: []string{"--token", "-"}, want: "empty"},
		"empty file":      {tail: []string{"--token-file", empty}, want: "empty"},
		"missing file":    {tail: []string{"--token-file", empty + ".none"}, want: "--token-file"},
		"both sources":    {tail: []string{"--token", "abc", "--token-file", empty}, want: "not both"},
		"global and file": {g: globals{token: "abc"}, tail: []string{"--token-file", empty}, want: "not both"},
	} {
		t.Run(name, func(t *testing.T) {
			stubSecretStdin(t, c.stdin)
			tail := append([]string{"--target", "connect", "--server", srv.URL}, c.tail...)
			_, stderr, code := runSetupHuman(t, c.g, tail)
			if code != exitUsage || !strings.Contains(stderr, c.want) {
				t.Fatalf("exit %d, stderr %q; want exit %d naming %q", code, stderr, exitUsage, c.want)
			}
			if cfg, _ := LoadConfig(); cfg != nil {
				if _, ok := cfg.FindServer(srv.URL); ok {
					t.Fatalf("a failed token read saved the server")
				}
			}
		})
	}
}
