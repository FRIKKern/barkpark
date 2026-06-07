package cli

import (
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// withTempConfigHome points XDG_CONFIG_HOME at a fresh temp dir for the duration
// of a test, so config read/write never touches the real ~/.config/barkpark.
func withTempConfigHome(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	return dir
}

func TestConfigRoundTrip(t *testing.T) {
	withTempConfigHome(t)

	want := &Config{
		Server:      "https://api.barkpark.cloud",
		Token:       "tok-123",
		AdminToken:  "admin-456",
		IngestToken: "ingest-789",
		Workspace:   "default",
		Project:     "default",
		Dataset:     "production",
		Output:      "json",
	}

	if err := SaveConfig(want); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}

	got, err := LoadConfig()
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}

	if !reflect.DeepEqual(got, want) {
		t.Fatalf("round-trip mismatch:\n got=%+v\nwant=%+v", *got, *want)
	}
}

func TestConfigSavePerms(t *testing.T) {
	root := withTempConfigHome(t)

	if err := SaveConfig(&Config{Server: "https://api.barkpark.cloud"}); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}

	// File must be 0600 — it holds tokens.
	path := filepath.Join(root, "barkpark", "config.json")
	fi, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat config: %v", err)
	}
	if perm := fi.Mode().Perm(); perm != 0o600 {
		t.Fatalf("config perms = %o, want 0600", perm)
	}

	// Dir must be 0700.
	di, err := os.Stat(filepath.Join(root, "barkpark"))
	if err != nil {
		t.Fatalf("stat config dir: %v", err)
	}
	if perm := di.Mode().Perm(); perm != 0o700 {
		t.Fatalf("config dir perms = %o, want 0700", perm)
	}
}

func TestConfigReTightensPerms(t *testing.T) {
	root := withTempConfigHome(t)

	if err := SaveConfig(&Config{Server: "a"}); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}
	path := filepath.Join(root, "barkpark", "config.json")
	// Loosen the file, then re-save — SaveConfig must re-tighten to 0600.
	if err := os.Chmod(path, 0o644); err != nil {
		t.Fatalf("chmod loosen: %v", err)
	}
	if err := SaveConfig(&Config{Server: "b"}); err != nil {
		t.Fatalf("SaveConfig re-save: %v", err)
	}
	fi, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if perm := fi.Mode().Perm(); perm != 0o600 {
		t.Fatalf("re-save perms = %o, want 0600", perm)
	}
}

func TestLoadConfigMissingIsEmpty(t *testing.T) {
	withTempConfigHome(t) // fresh dir, no config file written

	got, err := LoadConfig()
	if err != nil {
		t.Fatalf("LoadConfig on missing file should not error, got: %v", err)
	}
	if !reflect.DeepEqual(got, &Config{}) {
		t.Fatalf("missing-file config should be empty, got %+v", *got)
	}
}

func TestConfigKnownServersRoundTrip(t *testing.T) {
	withTempConfigHome(t)

	want := &Config{
		Server:    "https://api.barkpark.cloud",
		Token:     "tok-123",
		Workspace: "default",
		Project:   "default",
		Dataset:   "production",
		KnownServers: []ServerEntry{
			{Server: "https://api.barkpark.cloud", Token: "tok-123", Workspace: "default", Project: "default", Dataset: "production", Tier: "admin", LastConnected: "2026-06-05T10:00:00Z"},
			{Server: "http://localhost:4000", Token: "barkpark-dev-token", Tier: "anonymous", LastConnected: "2026-06-04T09:00:00Z"},
		},
	}

	if err := SaveConfig(want); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}
	got, err := LoadConfig()
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("known-servers round-trip mismatch:\n got=%+v\nwant=%+v", *got, *want)
	}
}

func TestRememberServerUpsertAndActive(t *testing.T) {
	c := &Config{}

	c.RememberServer(ServerEntry{Server: "https://api.barkpark.cloud", Token: "t1", Dataset: "production", Tier: "admin", LastConnected: "2026-06-01T00:00:00Z"})
	c.RememberServer(ServerEntry{Server: "http://localhost:4000", Token: "dev", Tier: "anonymous", LastConnected: "2026-06-02T00:00:00Z"})

	// Re-connect to the FIRST server (same URL but trailing slash + uppercase
	// host) — must collapse to one entry, refreshed, and move to front.
	c.RememberServer(ServerEntry{Server: "https://API.BARKPARK.cloud/", Token: "t2", Dataset: "staging", Tier: "write", LastConnected: "2026-06-03T00:00:00Z"})

	list := c.KnownServerList()
	if len(list) != 2 {
		t.Fatalf("upsert should collapse same URL: got %d entries, want 2: %+v", len(list), list)
	}
	// Most-recent-first: the re-connected barkpark.cloud is at front.
	if list[0].Server != "https://API.BARKPARK.cloud/" {
		t.Fatalf("re-connected server should be front, got %q", list[0].Server)
	}
	if list[0].Token != "t2" || list[0].Dataset != "staging" || list[0].LastConnected != "2026-06-03T00:00:00Z" {
		t.Fatalf("front entry should reflect latest connect: %+v", list[0])
	}
	if list[1].Server != "http://localhost:4000" {
		t.Fatalf("second entry should be localhost, got %q", list[1].Server)
	}

	// Active flat fields point at the most-recent connect.
	if c.Server != "https://API.BARKPARK.cloud/" || c.Token != "t2" || c.Dataset != "staging" {
		t.Fatalf("RememberServer must promote to active: server=%q token=%q dataset=%q", c.Server, c.Token, c.Dataset)
	}
	if !c.IsActiveServer("https://api.barkpark.cloud") { // normalized match
		t.Fatalf("IsActiveServer should match normalized active URL")
	}
	if c.IsActiveServer("http://localhost:4000") {
		t.Fatalf("localhost is not active")
	}
}

func TestRememberServerCapsAt20(t *testing.T) {
	c := &Config{}
	for i := 0; i < 25; i++ {
		c.RememberServer(ServerEntry{
			Server:        fmt.Sprintf("https://srv-%02d.example.com", i),
			LastConnected: "2026-06-05T00:00:00Z",
		})
	}
	list := c.KnownServerList()
	if len(list) != maxKnownServers {
		t.Fatalf("history should cap at %d, got %d", maxKnownServers, len(list))
	}
	// Most-recent (srv-24) at front; oldest survivor is srv-05 (srv-00..04 dropped).
	if list[0].Server != "https://srv-24.example.com" {
		t.Fatalf("front should be the latest, got %q", list[0].Server)
	}
	if list[len(list)-1].Server != "https://srv-05.example.com" {
		t.Fatalf("tail should be srv-05 after trimming oldest, got %q", list[len(list)-1].Server)
	}
}

func TestLoadOldFlatConfigHasNoKnownServers(t *testing.T) {
	root := withTempConfigHome(t)

	// Write an OLD-shape config.json by hand — no known_servers key at all.
	dir := filepath.Join(root, "barkpark")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	old := `{"server":"https://api.barkpark.cloud","token":"tok","workspace":"default","project":"default","dataset":"production"}`
	if err := os.WriteFile(filepath.Join(dir, "config.json"), []byte(old), 0o600); err != nil {
		t.Fatalf("write old config: %v", err)
	}

	got, err := LoadConfig()
	if err != nil {
		t.Fatalf("loading an old flat config must not error: %v", err)
	}
	if got.Server != "https://api.barkpark.cloud" {
		t.Fatalf("old flat fields should load: server=%q", got.Server)
	}
	if len(got.KnownServers) != 0 {
		t.Fatalf("old config should yield no known servers, got %+v", got.KnownServers)
	}
	if list := got.KnownServerList(); len(list) != 0 {
		t.Fatalf("KnownServerList on old config should be empty, got %+v", list)
	}
}

func TestToActiveContext(t *testing.T) {
	c := &Config{Server: "s", Token: "t", Workspace: "w", Project: "p", Dataset: "d", Output: "json"}
	ac := c.ToActiveContext()
	if ac.Server != "s" || ac.Token != "t" || ac.Workspace != "w" || ac.Project != "p" || ac.Dataset != "d" || ac.Output != "json" {
		t.Fatalf("ToActiveContext mismatch: %+v", ac)
	}

	// Nil receiver is safe and yields an empty ActiveContext.
	var nilC *Config
	if nilC.ToActiveContext() != (manifest.ActiveContext{}) {
		t.Fatalf("nil config should yield empty ActiveContext")
	}
}
