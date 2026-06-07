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

func TestDisplayNameDerivation(t *testing.T) {
	cases := []struct {
		server string
		want   string
	}{
		{"http://localhost:4000", "local"},
		{"http://127.0.0.1:4000", "local"},
		{"http://[::1]:4000", "local"},
		{"https://api.barkpark.cloud", "barkpark"},
		{"https://www.example.com", "example"},
		{"https://staging.foo.com", "staging"},
		{"https://foo.com", "foo"},
		{"http://192.168.1.10:4000", "192.168.1.10"},
		{"", "server"},
	}
	for _, tc := range cases {
		if got := DisplayName(ServerEntry{Server: tc.server}); got != tc.want {
			t.Errorf("DisplayName(%q) = %q, want %q", tc.server, got, tc.want)
		}
	}

	// An explicit Name always wins over derivation.
	if got := DisplayName(ServerEntry{Name: "prod", Server: "http://localhost:4000"}); got != "prod" {
		t.Errorf("explicit Name should win, got %q", got)
	}
}

func TestDisplayNameUniqueness(t *testing.T) {
	// Two unnamed entries that derive the SAME base ("barkpark") must render
	// distinctly: the front one keeps the base, the later one is suffixed -2. The
	// list is most-recent-first; ranking counts earlier same-base unnamed entries.
	c := &Config{KnownServers: []ServerEntry{
		{Server: "https://api.barkpark.cloud"},      // front → "barkpark"
		{Server: "https://api.barkpark.io"},          // later → "barkpark-2"
		{Name: "prod", Server: "https://other.com"},  // explicit name unaffected
	}}
	if got := c.DisplayName(c.KnownServers[0]); got != "barkpark" {
		t.Errorf("front entry = %q, want barkpark", got)
	}
	if got := c.DisplayName(c.KnownServers[1]); got != "barkpark-2" {
		t.Errorf("collision entry = %q, want barkpark-2", got)
	}
	if got := c.DisplayName(c.KnownServers[2]); got != "prod" {
		t.Errorf("explicit-name entry = %q, want prod", got)
	}
}

func TestRememberServerDerivesUniqueName(t *testing.T) {
	c := &Config{}
	// First connect, no name → derives "barkpark".
	c.RememberServer(ServerEntry{Server: "https://api.barkpark.cloud", LastConnected: "2026-06-01T00:00:00Z"})
	// Second connect to a DIFFERENT server that derives the same base → "barkpark-2".
	c.RememberServer(ServerEntry{Server: "https://api.barkpark.io", LastConnected: "2026-06-02T00:00:00Z"})

	list := c.KnownServerList()
	// Most-recent-first: barkpark.io is at front and must NOT collide with the
	// older barkpark.cloud's derived name.
	names := map[string]string{}
	for _, e := range list {
		names[e.Server] = e.Name
	}
	if names["https://api.barkpark.cloud"] != "barkpark" {
		t.Errorf("first server name = %q, want barkpark", names["https://api.barkpark.cloud"])
	}
	if names["https://api.barkpark.io"] != "barkpark-2" {
		t.Errorf("second server name = %q, want barkpark-2", names["https://api.barkpark.io"])
	}
}

func TestRememberServerExplicitNameAndInherit(t *testing.T) {
	c := &Config{}
	c.RememberServer(ServerEntry{Name: "prod", Server: "https://api.barkpark.cloud", Token: "t1", LastConnected: "2026-06-01T00:00:00Z"})
	// Re-connect to the SAME url with NO name → inherits "prod".
	c.RememberServer(ServerEntry{Server: "https://api.barkpark.cloud", Token: "t2", LastConnected: "2026-06-02T00:00:00Z"})

	list := c.KnownServerList()
	if len(list) != 1 {
		t.Fatalf("upsert should collapse to 1 entry, got %d", len(list))
	}
	if list[0].Name != "prod" {
		t.Errorf("re-connect should inherit prior name, got %q", list[0].Name)
	}
	if list[0].Token != "t2" {
		t.Errorf("re-connect should refresh token, got %q", list[0].Token)
	}
}

func TestFindServer(t *testing.T) {
	c := &Config{KnownServers: []ServerEntry{
		{Name: "cloud", Server: "https://api.barkpark.cloud", Dataset: "staging"},
		{Server: "http://localhost:4000"}, // unnamed → DisplayName "local"
	}}

	// By explicit Name (case-insensitive).
	if e, ok := c.FindServer("CLOUD"); !ok || e.Server != "https://api.barkpark.cloud" {
		t.Errorf("FindServer by name failed: %+v ok=%v", e, ok)
	}
	// By derived DisplayName.
	if e, ok := c.FindServer("local"); !ok || e.Server != "http://localhost:4000" {
		t.Errorf("FindServer by derived name failed: %+v ok=%v", e, ok)
	}
	// By normalized URL (trailing slash, uppercase host).
	if e, ok := c.FindServer("https://API.barkpark.cloud/"); !ok || e.Name != "cloud" {
		t.Errorf("FindServer by URL failed: %+v ok=%v", e, ok)
	}
	// Miss.
	if _, ok := c.FindServer("nope"); ok {
		t.Errorf("FindServer should miss on unknown")
	}
	// Empty query → miss.
	if _, ok := c.FindServer(""); ok {
		t.Errorf("FindServer should miss on empty query")
	}
}

func TestServerKind(t *testing.T) {
	cases := []struct {
		server string
		want   string
	}{
		{"http://localhost:4000", "local"},
		{"http://127.0.0.1:4000", "local"},
		{"http://[::1]:4000", "local"},
		{"http://mymac.local:4000", "local"},
		{"http://10.0.0.5:4000", "local"},
		{"http://192.168.1.20:4000", "local"},
		{"http://172.16.0.1:4000", "local"},
		{"http://172.31.255.255:4000", "local"},
		{"http://172.15.0.1:4000", "cloud"}, // just below the private range
		{"http://172.32.0.1:4000", "cloud"}, // just above the private range
		{"http://8.8.8.8:4000", "cloud"},
		{"https://api.barkpark.cloud", "cloud"},
		{"https://staging.foo.com", "cloud"},
		{"", "cloud"},
	}
	for _, tc := range cases {
		if got := ServerKind(tc.server); got != tc.want {
			t.Errorf("ServerKind(%q) = %q, want %q", tc.server, got, tc.want)
		}
	}
}

func TestKindOfHonorsOverride(t *testing.T) {
	var c *Config // KindOf is nil-safe via the receiver guard below
	c = &Config{}
	// Derived when no override.
	if got := c.KindOf(ServerEntry{Server: "http://localhost:4000"}); got != "local" {
		t.Errorf("derived kind = %q, want local", got)
	}
	// Explicit override wins over the derived classification (a private IP pinned
	// to cloud).
	if got := c.KindOf(ServerEntry{Server: "http://10.0.0.5:4000", Kind: "cloud"}); got != "cloud" {
		t.Errorf("override kind = %q, want cloud", got)
	}
}

func TestMultiLocalNamingByPort(t *testing.T) {
	// Two locals on different ports: the first (front, most-recent-first) keeps the
	// bare "local"; the second disambiguates by PORT, not a bare ordinal.
	c := &Config{KnownServers: []ServerEntry{
		{Name: "local", Server: "http://localhost:4000"}, // front → "local"
		{Server: "http://localhost:4001"},                 // unnamed later → "local-4001"
	}}
	if got := c.DisplayName(c.KnownServers[0]); got != "local" {
		t.Errorf("front local = %q, want local", got)
	}
	if got := c.DisplayName(c.KnownServers[1]); got != "local-4001" {
		t.Errorf("second local = %q, want local-4001", got)
	}

	// RememberServer derives the same port-disambiguated handle at connect time.
	rc := &Config{}
	rc.RememberServer(ServerEntry{Server: "http://localhost:4000", LastConnected: "2026-06-01T00:00:00Z"})
	rc.RememberServer(ServerEntry{Server: "http://localhost:4001", LastConnected: "2026-06-02T00:00:00Z"})
	names := map[string]string{}
	for _, e := range rc.KnownServerList() {
		names[e.Server] = e.Name
	}
	if names["http://localhost:4000"] != "local" {
		t.Errorf("first local name = %q, want local", names["http://localhost:4000"])
	}
	if names["http://localhost:4001"] != "local-4001" {
		t.Errorf("second local name = %q, want local-4001", names["http://localhost:4001"])
	}
}

func TestPortOf(t *testing.T) {
	cases := []struct{ in, want string }{
		{"http://localhost:4001/x", "4001"},
		{"http://localhost", ""},
		{"https://api.barkpark.cloud", ""},
		{"http://[::1]:4000", "4000"},
		{"http://[::1]", ""},
		{"http://user@host:8080", "8080"},
	}
	for _, tc := range cases {
		if got := portOf(tc.in); got != tc.want {
			t.Errorf("portOf(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestSetActiveServer(t *testing.T) {
	c := &Config{Server: "http://localhost:4000", Token: "dev", Workspace: "default", Project: "default", Dataset: "production"}
	c.SetActiveServer(ServerEntry{Server: "https://api.barkpark.cloud", Token: "tok-cloud", Dataset: "staging"})

	if c.Server != "https://api.barkpark.cloud" || c.Token != "tok-cloud" {
		t.Errorf("SetActiveServer did not promote server/token: %+v", *c)
	}
	if c.Dataset != "staging" {
		t.Errorf("SetActiveServer should promote dataset, got %q", c.Dataset)
	}
	// Empty workspace/project on the entry leave the existing scope intact.
	if c.Workspace != "default" || c.Project != "default" {
		t.Errorf("SetActiveServer should not blank unset scope: w=%q p=%q", c.Workspace, c.Project)
	}
}
