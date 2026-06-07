package cli

import (
	"bytes"
	"encoding/json"
	"testing"
)

// seedActiveServer writes a config with one saved/active server under the test's
// temp XDG home, so the connect-without-`--server` default has something to land
// on. It returns the URL it seeded.
func seedActiveServer(t *testing.T) string {
	t.Helper()
	const url = "https://api.barkpark.cloud"
	cfg := &Config{}
	cfg.RememberServer(ServerEntry{
		Server:        url,
		Token:         "tok-saved",
		Workspace:     "default",
		Project:       "default",
		Dataset:       "production",
		Tier:          "admin",
		LastConnected: "2026-06-05T00:00:00Z",
	})
	if err := SaveConfig(cfg); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}
	return url
}

// runSetupJSON drives runSetup with -o json and returns the parsed envelope plus
// the exit code. It uses an in-memory writer so nothing touches the real tty.
func runSetupJSON(t *testing.T, g globals, tail []string) (map[string]any, int) {
	t.Helper()
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	g.output = "json"
	g.outputSet = true
	w.applyGlobals(g)
	code := runSetup(w, g, tail)
	var env map[string]any
	if stdout.Len() > 0 {
		if err := json.Unmarshal(stdout.Bytes(), &env); err != nil {
			t.Fatalf("unmarshal stdout %q: %v", stdout.String(), err)
		}
	}
	return env, code
}

// TestSetupConnectDefaultsToActiveSavedServer covers the convenience path: with a
// saved active server and NO --server, a connect dry-run resolves connect_to to
// that server and surfaces it in known_servers (active:true).
func TestSetupConnectDefaultsToActiveSavedServer(t *testing.T) {
	withTempConfigHome(t)
	url := seedActiveServer(t)

	env, code := runSetupJSON(t, globals{dryRun: true},
		[]string{"--target", "connect"})
	if code != exitOK {
		t.Fatalf("exit = %d, want %d (%v)", code, exitOK, env)
	}
	if ok, _ := env["ok"].(bool); !ok {
		t.Fatalf("ok = %v, want true (%v)", env["ok"], env)
	}
	if got := env["connect_to"]; got != url {
		t.Fatalf("connect_to = %v, want %q", got, url)
	}
	ks, _ := env["known_servers"].([]any)
	if len(ks) == 0 {
		t.Fatalf("known_servers empty, want the saved server")
	}
	first, _ := ks[0].(map[string]any)
	if first["server"] != url {
		t.Fatalf("known_servers[0].server = %v, want %q", first["server"], url)
	}
	if active, _ := first["active"].(bool); !active {
		t.Fatalf("known_servers[0].active = %v, want true", first["active"])
	}
}

// TestSetupConnectNoServerNoSaved covers the clean usage error: no --server and an
// empty config → {ok:false, error.code:"usage"} exit 2.
func TestSetupConnectNoServerNoSaved(t *testing.T) {
	withTempConfigHome(t) // empty config

	env, code := runSetupJSON(t, globals{dryRun: true},
		[]string{"--target", "connect"})
	if code != exitUsage {
		t.Fatalf("exit = %d, want %d (%v)", code, exitUsage, env)
	}
	if ok, _ := env["ok"].(bool); ok {
		t.Fatalf("ok = %v, want false (%v)", env["ok"], env)
	}
	errObj, _ := env["error"].(map[string]any)
	if errObj["code"] != "usage" {
		t.Fatalf("error.code = %v, want \"usage\" (%v)", errObj["code"], env)
	}
}

// TestSetupConnectExplicitServerOverridesSaved confirms an explicit --server still
// wins over the saved active server.
func TestSetupConnectExplicitServerOverridesSaved(t *testing.T) {
	withTempConfigHome(t)
	seedActiveServer(t)

	const other = "https://other.example.com"
	env, code := runSetupJSON(t, globals{dryRun: true},
		[]string{"--target", "connect", "--server", other})
	if code != exitOK {
		t.Fatalf("exit = %d, want %d (%v)", code, exitOK, env)
	}
	if got := env["connect_to"]; got != other {
		t.Fatalf("connect_to = %v, want %q", got, other)
	}
}
