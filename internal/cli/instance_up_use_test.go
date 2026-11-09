package cli

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cli/setup"
)

// seedGylActive writes a config in a temporary XDG_CONFIG_HOME whose
// active server is gyl, as on the operator's machine on 2026-11-06.
func seedGylActive(t *testing.T) {
	t.Helper()
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(t.TempDir(), "config"))
	cfg := &Config{}
	cfg.RememberServer(ServerEntry{Name: "gyl", Server: "https://gyl.example.test", Token: "gyl-token",
		Workspace: "default", Project: "default", Dataset: "production"})
	if err := SaveConfig(cfg); err != nil {
		t.Fatal(err)
	}
}

// activeServerName runs bp servers -o json and returns the active name.
func activeServerName(t *testing.T) (string, []string) {
	t.Helper()
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	w.applyGlobals(globals{output: "json", outputSet: true})
	if code := runServers(w, nil); code != exitOK {
		t.Fatalf("bp servers exited %d: %s", code, stderr.String())
	}
	var got struct {
		Active  string `json:"active"`
		Servers []struct {
			Name string `json:"name"`
		} `json:"servers"`
	}
	if err := json.Unmarshal(stdout.Bytes(), &got); err != nil {
		t.Fatalf("bp servers -o json: %v\n%s", err, stdout.String())
	}
	var names []string
	for _, s := range got.Servers {
		names = append(names, s.Name)
	}
	return got.Active, names
}

// The real connect step saves the new instance without switching the
// active server.
func TestInstanceUpConnectKeepsActiveServer(t *testing.T) {
	seedGylActive(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/capabilities":
			_, _ = w.Write([]byte(`{"auth_tier":"admin","server":{"name":"barkpark","version":"0.2.40"}}`))
		default:
			_, _ = w.Write([]byte(`{}`))
		}
	}))
	defer srv.Close()

	var stdout, stderr bytes.Buffer
	if err := instanceUpConnect(newWriter(&stdout, &stderr), globals{}, srv.URL, "new-admin-token"); err != nil {
		t.Fatal(err)
	}
	active, names := activeServerName(t)
	if active != "gyl" {
		t.Errorf("bp servers shows active %q after connect; want gyl", active)
	}
	if len(names) != 2 {
		t.Errorf("bp servers lists %v; want gyl and the new instance", names)
	}
	if !strings.Contains(stderr.String(), "without changing the active server") {
		t.Errorf("connect report does not say the active server stayed:\n%s", stderr.String())
	}
	if strings.Contains(stderr.String(), "new-admin-token") {
		t.Errorf("connect report prints the token")
	}
}

// stubKeepActiveConnect stands in for the connect step's config write, as
// the real connect does with --keep-active.
func stubKeepActiveConnect(t *testing.T) {
	t.Helper()
	old := instanceUpConnect
	instanceUpConnect = func(_ *writer, _ globals, server, token string) error {
		return configStoreAdapter{}.Save(setup.SavedConfig{Server: server, Token: token,
			Workspace: "default", Project: "default", Dataset: "production", KeepActive: true})
	}
	t.Cleanup(func() { instanceUpConnect = old })
}

func TestInstanceUpWithoutUseKeepsActiveServer(t *testing.T) {
	stubInstanceUp(t)
	seedGylActive(t)
	stubKeepActiveConnect(t)
	stdout, stderr, code := runUp(t, vmArgs()...)
	if code != exitOK {
		t.Fatalf("exit %d\n%s", code, stderr)
	}
	active, _ := activeServerName(t)
	if active != "gyl" {
		t.Errorf("bp servers shows active %q after bp instance up; want gyl", active)
	}
	name := instanceUpServerName("https://pensum-cms.swedencentral.cloudapp.azure.com")
	if !strings.Contains(stdout, "bp use "+name) {
		t.Errorf("up does not print how to switch to %s:\n%s", name, stdout)
	}
	if strings.Contains(stdout, "is now the active server") {
		t.Errorf("up claims the switch without --use:\n%s", stdout)
	}
}

func TestInstanceUpUseSwitchesActiveServer(t *testing.T) {
	stubInstanceUp(t)
	seedGylActive(t)
	stubKeepActiveConnect(t)
	stdout, stderr, code := runUp(t, append(vmArgs(), "--use")...)
	if code != exitOK {
		t.Fatalf("exit %d\n%s", code, stderr)
	}
	name := instanceUpServerName("https://pensum-cms.swedencentral.cloudapp.azure.com")
	active, _ := activeServerName(t)
	if active != name || active == "gyl" {
		t.Errorf("bp servers shows active %q after --use; want %q", active, name)
	}
	if !strings.Contains(stdout, "is now the active server") {
		t.Errorf("up does not report the switch:\n%s", stdout)
	}
}

// --use on a rerun after a finished run switches without running a step again.
func TestInstanceUpUseOnRerunSwitches(t *testing.T) {
	f := stubInstanceUp(t)
	seedGylActive(t)
	stubKeepActiveConnect(t)
	if _, stderr, code := runUp(t, vmArgs()...); code != exitOK {
		t.Fatalf("exit %d\n%s", code, stderr)
	}
	calls := len(f.calls)
	if _, stderr, code := runUp(t, "--use"); code != exitOK {
		t.Fatalf("rerun exit %d\n%s", code, stderr)
	}
	if active, _ := activeServerName(t); active == "gyl" {
		t.Errorf("rerun with --use left gyl active")
	}
	// preflight runs on every run; nothing else may.
	for _, c := range f.calls[calls:] {
		if strings.Contains(c.String(), "vm create") || strings.Contains(c.String(), "deploy.sh") {
			t.Errorf("rerun ran %s", c.String())
		}
	}
}
