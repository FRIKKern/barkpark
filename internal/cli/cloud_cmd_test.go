package cli

import (
	"bytes"
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/mattn/go-runewidth"
)

// updateGolden regenerates the testdata/*.golden fixtures instead of asserting
// against them: `go test ./internal/cli/... -run TestBarkparks -update`. The
// flag is package-local so it never collides with another package's -update.
var updateGolden = flag.Bool("update", false, "rewrite testdata golden files")

// goldenPath is the on-disk path of a named golden fixture.
func goldenPath(name string) string {
	return filepath.Join("testdata", name+".golden")
}

// assertGolden compares got against testdata/<name>.golden, rewriting the file
// when -update is set. It is the single golden seam these tests share.
func assertGolden(t *testing.T, name, got string) {
	t.Helper()
	path := goldenPath(name)
	if *updateGolden {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatalf("mkdir testdata: %v", err)
		}
		if err := os.WriteFile(path, []byte(got), 0o644); err != nil {
			t.Fatalf("write golden %s: %v", path, err)
		}
		return
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read golden %s: %v (run with -update to create it)", path, err)
	}
	if got != string(want) {
		t.Fatalf("golden mismatch for %s:\n--- got ---\n%s\n--- want ---\n%s", name, got, string(want))
	}
}

// runCloudCapture drives one of the cloud built-ins with an in-memory writer and
// returns stdout, stderr, and the exit code. When jsonOut is set the writer is
// put in -o json mode, matching what an agent (non-TTY) sees.
func runCloudCapture(t *testing.T, jsonOut bool, fn func(out *writer) int) (string, string, int) {
	t.Helper()
	var stdout, stderr bytes.Buffer
	w := newWriter(&stdout, &stderr)
	g := globals{}
	if jsonOut {
		g.output = "json"
		g.outputSet = true
	}
	w.applyGlobals(g)
	code := fn(w)
	return stdout.String(), stderr.String(), code
}

// seedTwoBarkparks writes a config with two known servers under the test's temp
// config home — one cloud, one local — and makes the cloud one active. The
// LastConnected stamps are fixed so the rendered table is deterministic.
func seedTwoBarkparks(t *testing.T) {
	t.Helper()
	cfg := &Config{}
	// Most-recent-first: register local LAST so it heads the list, then re-select
	// the cloud one as active to exercise the ★ marker on a non-head row.
	cfg.RememberServer(ServerEntry{
		Name:          "acme",
		Server:        "https://api.barkpark.cloud",
		Token:         "tok-acme",
		Tier:          "admin",
		LastConnected: "2026-06-05T00:00:00Z",
	})
	cfg.RememberServer(ServerEntry{
		Name:          "dev",
		Server:        "http://localhost:4000",
		Token:         "tok-dev",
		Tier:          "admin",
		LastConnected: "2026-06-06T00:00:00Z",
	})
	// Make the cloud server active (it is not the head of the list).
	if e, ok := cfg.FindServer("acme"); ok {
		cfg.SetActiveServer(e)
	}
	if err := SaveConfig(cfg); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}
}

// TestBarkparksTableGolden asserts the rendered `bp barkparks` human table for a
// fixture of two known servers (golden file).
func TestBarkparksTableGolden(t *testing.T) {
	withTempConfigHome(t)
	seedTwoBarkparks(t)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		// Force table output regardless of the test process's tty state.
		out.output = "table"
		return runBarkparks(out, nil)
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	assertGolden(t, "barkparks_table", stdout)
}

// TestBarkparksKindFilter checks the --kind local|cloud filter narrows the list.
func TestBarkparksKindFilter(t *testing.T) {
	withTempConfigHome(t)
	seedTwoBarkparks(t)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runBarkparks(out, []string{"--kind", "local"})
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if !bytes.Contains([]byte(stdout), []byte("localhost:4000")) {
		t.Fatalf("--kind local should show the local server:\n%s", stdout)
	}
	if bytes.Contains([]byte(stdout), []byte("api.barkpark.cloud")) {
		t.Fatalf("--kind local must NOT show the cloud server:\n%s", stdout)
	}
}

// TestBarkparksLocalYAML locks the LOCAL (no Cloud token) `bp barkparks -o yaml`
// path: it must emit the structured shape, not silently downgrade to the human
// table (the emitStructured contract). This is the -o yaml holdout the fix closed.
func TestBarkparksLocalYAML(t *testing.T) {
	withTempConfigHome(t)
	seedTwoBarkparks(t) // sets per-server Tokens but no CloudToken → local path

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "yaml"
		return runBarkparks(out, nil)
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if !strings.Contains(stdout, "barkparks:") || !strings.Contains(stdout, "source: local-config") {
		t.Fatalf("-o yaml should emit the structured shape, got:\n%s", stdout)
	}
	// It must NOT fall back to the human table (whose header carries STATUS).
	if strings.Contains(stdout, "STATUS") {
		t.Fatalf("-o yaml must not downgrade to the human table:\n%s", stdout)
	}
}

// TestBarkparksTableMultibyteAlignment locks that the human table measures and
// pads columns in terminal display cells (runewidth), not bytes: a multibyte
// name must not shear the URL column's alignment.
func TestBarkparksTableMultibyteAlignment(t *testing.T) {
	withTempConfigHome(t)
	cfg := &Config{}
	cfg.RememberServer(ServerEntry{Name: "犬公園", Server: "http://a.example:4000", LastConnected: "2026-06-06T00:00:00Z"})
	cfg.RememberServer(ServerEntry{Name: "ascii", Server: "http://b.example:4000", LastConnected: "2026-06-05T00:00:00Z"})
	if err := SaveConfig(cfg); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runBarkparks(out, nil)
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}

	// Every data row's URL must begin at the same DISPLAY column. A byte- or
	// rune-width pad would place the multibyte-name row's URL at a different cell.
	urlCol := -1
	for _, ln := range strings.Split(strings.TrimRight(stdout, "\n"), "\n") {
		idx := strings.Index(ln, "http://")
		if idx < 0 {
			continue // the header line has no URL value
		}
		col := runewidth.StringWidth(ln[:idx])
		if urlCol == -1 {
			urlCol = col
		} else if col != urlCol {
			t.Fatalf("URL column misaligned: display col %d, want %d\n%s", col, urlCol, stdout)
		}
	}
	if urlCol == -1 {
		t.Fatalf("no URL rows found in table:\n%s", stdout)
	}
}

// TestBarkparksEmpty: an empty config yields a friendly hint, exit 0.
func TestBarkparksEmpty(t *testing.T) {
	withTempConfigHome(t)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table"
		return runBarkparks(out, nil)
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if !bytes.Contains([]byte(stdout), []byte("no Barkparks known yet")) {
		t.Fatalf("empty config should hint how to add one:\n%s", stdout)
	}
}

// TestRegisterSSHUpsertsServer asserts `bp register ssh root@1.2.3.4 --name acme`
// upserts the server into a temp config (RememberServer wired correctly) and
// prints the confirmation. The clock is pinned so the persisted LastConnected is
// deterministic.
func TestRegisterSSHUpsertsServer(t *testing.T) {
	withTempConfigHome(t)
	pinClock(t, "2026-06-23T12:00:00Z")

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table" // force the human confirmation path for the golden
		return runAttach(out, "register", []string{"ssh", "root@1.2.3.4", "--name", "acme"})
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}

	// The server must be in config, named "acme", with the derived URL, active.
	cfg, err := LoadConfig()
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	const wantURL = "http://1.2.3.4:4000"
	entry, ok := cfg.FindServer("acme")
	if !ok {
		t.Fatalf("server not upserted under name acme; known=%v", knownNames(cfg))
	}
	if entry.Server != wantURL {
		t.Fatalf("entry.Server = %q, want %q", entry.Server, wantURL)
	}
	if entry.Name != "acme" {
		t.Fatalf("entry.Name = %q, want acme", entry.Name)
	}
	if entry.LastConnected != "2026-06-23T12:00:00Z" {
		t.Fatalf("entry.LastConnected = %q, want pinned stamp", entry.LastConnected)
	}
	if !cfg.IsActiveServer(wantURL) {
		t.Fatalf("registered server should be active; active=%q", cfg.ActiveServer())
	}

	// Confirmation output (golden).
	assertGolden(t, "register_ssh", stdout)
}

// TestRegisterSSHJSON checks the JSON envelope shape for register.
func TestRegisterSSHJSON(t *testing.T) {
	withTempConfigHome(t)
	pinClock(t, "2026-06-23T12:00:00Z")

	stdout, _, code := runCloudCapture(t, true, func(out *writer) int {
		return runAttach(out, "register", []string{"ssh", "root@1.2.3.4", "--name", "acme"})
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	var env map[string]any
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("unmarshal %q: %v", stdout, err)
	}
	if ok, _ := env["ok"].(bool); !ok {
		t.Fatalf("ok = %v, want true (%v)", env["ok"], env)
	}
	bp, _ := env["barkpark"].(map[string]any)
	if bp["name"] != "acme" || bp["url"] != "http://1.2.3.4:4000" {
		t.Fatalf("barkpark envelope = %v", bp)
	}
	if bp["ssh_target"] != "root@1.2.3.4" {
		t.Fatalf("ssh_target = %v, want root@1.2.3.4", bp["ssh_target"])
	}
}

// TestRegisterRequiresTransport: `bp register` without `ssh` is a usage error.
func TestRegisterRequiresTransport(t *testing.T) {
	withTempConfigHome(t)
	_, _, code := runCloudCapture(t, false, func(out *writer) int {
		return runAttach(out, "register", []string{"root@1.2.3.4"})
	})
	if code != exitUsage {
		t.Fatalf("exit = %d, want %d", code, exitUsage)
	}
}

// TestRegisterRejectsBadTarget: an empty-host / scheme'd target is a usage error
// and writes nothing to config.
func TestRegisterRejectsBadTarget(t *testing.T) {
	withTempConfigHome(t)
	for _, bad := range []string{"root@", "@host", "http://1.2.3.4", "host with space"} {
		_, _, code := runCloudCapture(t, false, func(out *writer) int {
			return runAttach(out, "register", []string{"ssh", bad, "--name", "x"})
		})
		if code != exitUsage {
			t.Fatalf("target %q: exit = %d, want %d", bad, code, exitUsage)
		}
	}
	cfg, _ := LoadConfig()
	if len(cfg.KnownServerList()) != 0 {
		t.Fatalf("bad targets must not write config; got %v", knownNames(cfg))
	}
}

// TestAttachShortForm: `bp attach <target> --name <name>` (no `ssh` literal)
// upserts the same way register does, and derives a name when omitted.
func TestAttachShortForm(t *testing.T) {
	withTempConfigHome(t)
	pinClock(t, "2026-06-23T12:00:00Z")

	_, _, code := runCloudCapture(t, false, func(out *writer) int {
		return runAttach(out, "attach", []string{"deploy@198.51.100.7"})
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	cfg, _ := LoadConfig()
	if _, ok := cfg.FindServer("http://198.51.100.7:4000"); !ok {
		t.Fatalf("attach should upsert the derived URL; known=%v", knownNames(cfg))
	}
}

// TestAgentDisableRendersSSHCommand asserts `bp agent disable --name acme`
// renders (does NOT execute) the SSH command, against a golden file.
func TestAgentDisableRendersSSHCommand(t *testing.T) {
	withTempConfigHome(t)
	seedTwoBarkparks(t)

	stdout, _, code := runCloudCapture(t, false, func(out *writer) int {
		out.output = "table" // force the human render path for the golden
		return runAgent(out, "disable", []string{"--name", "acme"})
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	assertGolden(t, "agent_disable", stdout)
}

// TestAgentUninstallJSON checks the uninstall command renders the remote command
// in its JSON envelope and never executes it (dry_run:true).
func TestAgentUninstallJSON(t *testing.T) {
	withTempConfigHome(t)
	seedTwoBarkparks(t)

	stdout, _, code := runCloudCapture(t, true, func(out *writer) int {
		return runAgent(out, "uninstall", []string{"--name", "dev"})
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	var env map[string]any
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("unmarshal %q: %v", stdout, err)
	}
	if dry, _ := env["dry_run"].(bool); !dry {
		t.Fatalf("dry_run = %v, want true (never executes)", env["dry_run"])
	}
	if env["target"] != "dev" {
		t.Fatalf("target = %v, want dev", env["target"])
	}
	cmd, _ := env["command"].(string)
	if cmd == "" || cmd[:4] != "ssh " {
		t.Fatalf("command = %q, want a rendered ssh line", cmd)
	}
	// The uninstall remote must remove the unit + binary.
	if !bytes.Contains([]byte(cmd), []byte("rm -f /etc/systemd/system/barkpark-agent.service")) {
		t.Fatalf("uninstall command missing unit removal: %q", cmd)
	}
}

// TestAgentNoActiveTarget: agent with no --name and no active server is a clean
// usage error.
func TestAgentNoActiveTarget(t *testing.T) {
	withTempConfigHome(t) // empty config — no active server
	_, _, code := runCloudCapture(t, false, func(out *writer) int {
		return runAgent(out, "disable", nil)
	})
	if code != exitUsage {
		t.Fatalf("exit = %d, want %d", code, exitUsage)
	}
}

// TestAgentUnknownVerb: an unrecognised agent verb is a usage error.
func TestAgentUnknownVerb(t *testing.T) {
	withTempConfigHome(t)
	seedTwoBarkparks(t)
	_, _, code := runCloudCapture(t, false, func(out *writer) int {
		return runAgent(out, "frobnicate", nil)
	})
	if code != exitUsage {
		t.Fatalf("exit = %d, want %d", code, exitUsage)
	}
}

// TestAgentUnknownVerbJSON: an unrecognised agent verb under -o json emits a
// structured usage error envelope (matching agentNoTarget's shape) rather than
// plaintext stderr, so agents get a machine-readable miss.
func TestAgentUnknownVerbJSON(t *testing.T) {
	withTempConfigHome(t)
	seedTwoBarkparks(t)
	stdout, _, code := runCloudCapture(t, true, func(out *writer) int {
		return runAgent(out, "frobnicate", nil)
	})
	if code != exitUsage {
		t.Fatalf("exit = %d, want %d", code, exitUsage)
	}
	var env map[string]any
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("unmarshal %q: %v", stdout, err)
	}
	if ok, _ := env["ok"].(bool); ok {
		t.Fatalf("ok = %v, want false", env["ok"])
	}
	errObj, _ := env["error"].(map[string]any)
	if errObj["code"] != "usage" {
		t.Fatalf("error.code = %v, want usage (%v)", errObj["code"], env)
	}
	known, _ := errObj["known"].([]any)
	if len(known) != 2 || known[0] != "disable" || known[1] != "uninstall" {
		t.Fatalf("error.known = %v, want [disable uninstall]", errObj["known"])
	}
}

// pinClock pins cloudClock to a fixed RFC3339 instant for the duration of a test
// so the persisted LastConnected stamp is deterministic.
func pinClock(t *testing.T, rfc3339 string) {
	t.Helper()
	ts, err := time.Parse(time.RFC3339, rfc3339)
	if err != nil {
		t.Fatalf("parse pinned clock %q: %v", rfc3339, err)
	}
	orig := cloudClock
	cloudClock = func() time.Time { return ts }
	t.Cleanup(func() { cloudClock = orig })
}
