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

// TestSetupLocalDryRunDefaultsProfileClean: the JSON dry-run plan for local
// carries profile=clean by default and the redacted seed-token env.
func TestSetupLocalDryRunDefaultsProfileClean(t *testing.T) {
	withTempConfigHome(t)

	env, code := runSetupJSON(t, globals{dryRun: true},
		[]string{"--target", "local"})
	if code != exitOK {
		t.Fatalf("exit = %d, want %d (%v)", code, exitOK, env)
	}
	if got := env["profile"]; got != "clean" {
		t.Fatalf("profile = %v, want \"clean\"", got)
	}
	envMap, _ := env["env"].(map[string]any)
	if envMap["BARKPARK_SEED_PROFILE"] != "clean" {
		t.Fatalf("env.BARKPARK_SEED_PROFILE = %v, want \"clean\"", envMap["BARKPARK_SEED_PROFILE"])
	}
	if envMap["BARKPARK_SEED_ADMIN_TOKEN"] != "****" {
		t.Fatalf("env.BARKPARK_SEED_ADMIN_TOKEN = %v, want \"****\"", envMap["BARKPARK_SEED_ADMIN_TOKEN"])
	}
}

// TestSetupProfileDemoFlag: --profile demo flips the plan's profile.
func TestSetupProfileDemoFlag(t *testing.T) {
	withTempConfigHome(t)

	env, code := runSetupJSON(t, globals{dryRun: true},
		[]string{"--target", "local", "--profile", "demo"})
	if code != exitOK {
		t.Fatalf("exit = %d, want %d (%v)", code, exitOK, env)
	}
	if got := env["profile"]; got != "demo" {
		t.Fatalf("profile = %v, want \"demo\"", got)
	}
}

// TestSetupProfileUnknownIsUsageError: --profile x is a clean usage error (2).
func TestSetupProfileUnknownIsUsageError(t *testing.T) {
	withTempConfigHome(t)

	env, code := runSetupJSON(t, globals{dryRun: true},
		[]string{"--target", "local", "--profile", "x"})
	if code != exitUsage {
		t.Fatalf("exit = %d, want %d (%v)", code, exitUsage, env)
	}
	errObj, _ := env["error"].(map[string]any)
	if errObj["code"] != "usage" {
		t.Fatalf("error.code = %v, want \"usage\" (%v)", errObj["code"], env)
	}
}

// TestFirstRunDetection: empty temp config home + no BARKPARK_* env => first
// run; a saved config flips it; a set env var flips it too.
func TestFirstRunDetection(t *testing.T) {
	withTempConfigHome(t)
	// axi-b4: the WHOLE dialect, derived — FirstRun reads ServerEnvNames and
	// TokenEnvNames, so a hand-written pair here leaves the newer names live.
	clearBarkparkEnv(t)

	if !FirstRun() {
		t.Fatalf("empty config home + no env should be a first run")
	}

	t.Setenv("BARKPARK_API_URL", "http://localhost:4000")
	if FirstRun() {
		t.Fatalf("a set BARKPARK_API_URL must not count as a first run")
	}
	t.Setenv("BARKPARK_API_URL", "")

	seedActiveServer(t)
	if FirstRun() {
		t.Fatalf("a saved config must not count as a first run")
	}
}

// TestFirstRunResult pins the pure post-wizard decision RunFirstTimeSetup
// delegates to: a LoggedInOnly cloud finish (CloudToken, no content server)
// must report configured=false so main.go exits as given WITHOUT resolving a
// desk — this is the headline W3 fix — while an ordinary connected server
// reports configured=true. Neither ever returns a non-OK exit.
func TestFirstRunResult(t *testing.T) {
	// Neutralize the ambient env so on-disk config is the sole signal (axi-b4:
	// derived from the dialect lists, never a hand-written subset of them).
	clearBarkparkEnv(t)

	t.Run("cloud token, no server → (false, exitOK)", func(t *testing.T) {
		withTempConfigHome(t)
		if err := SaveConfig(&Config{CloudURL: "https://api.barkpark.cloud", CloudToken: "sess"}); err != nil {
			t.Fatal(err)
		}
		configured, code := firstRunResult()
		if configured {
			t.Fatal("logged-in-without-server must report configured=false so main skips the desk")
		}
		if code != exitOK {
			t.Fatalf("logged-in-without-server must exit as given (exitOK=%d), got %d", exitOK, code)
		}
	})

	t.Run("connected server → (true, exitOK)", func(t *testing.T) {
		withTempConfigHome(t)
		if err := SaveConfig(&Config{Server: "https://my.barkpark", Token: "tok"}); err != nil {
			t.Fatal(err)
		}
		configured, code := firstRunResult()
		if !configured {
			t.Fatal("a saved content server means configured=true so main falls through to the desk")
		}
		if code != exitOK {
			t.Fatalf("configured finish must exit exitOK=%d, got %d", exitOK, code)
		}
	})
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
