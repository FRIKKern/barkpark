package cli

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/cli/setup"
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

func TestSaveConfigAtomicRoundTripAndPerms(t *testing.T) {
	root := withTempConfigHome(t)

	want := &Config{Server: "https://api.barkpark.cloud", Token: "tok-123"}
	if err := SaveConfig(want); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}

	// On-disk file is 0600 — it holds tokens.
	path := filepath.Join(root, "barkpark", "config.json")
	fi, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat config: %v", err)
	}
	if perm := fi.Mode().Perm(); perm != 0o600 {
		t.Fatalf("config perms = %o, want 0600", perm)
	}

	got, err := LoadConfig()
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("round-trip mismatch:\n got=%+v\nwant=%+v", *got, *want)
	}
}

func TestSaveConfigRecoversFromCorruptFile(t *testing.T) {
	root := withTempConfigHome(t)
	dir := filepath.Join(root, "barkpark")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	path := filepath.Join(dir, "config.json")

	// Simulate a config left truncated/interleaved by a crash or racing bp.
	if err := os.WriteFile(path, []byte(`{"server":"https://api.barkpark`), 0o600); err != nil {
		t.Fatalf("write corrupt config: %v", err)
	}

	// A fresh save must overwrite the corruption so LoadConfig succeeds again.
	if err := SaveConfig(&Config{Server: "https://api.barkpark.cloud", Token: "t"}); err != nil {
		t.Fatalf("SaveConfig over corrupt file: %v", err)
	}
	got, err := LoadConfig()
	if err != nil {
		t.Fatalf("LoadConfig after recovery: %v", err)
	}
	if got.Server != "https://api.barkpark.cloud" || got.Token != "t" {
		t.Fatalf("recovered config mismatch: %+v", *got)
	}

	// No temp files may leak — a successful save renames its temp away.
	leftovers, err := filepath.Glob(filepath.Join(dir, "config-*.json"))
	if err != nil {
		t.Fatalf("glob temp files: %v", err)
	}
	if len(leftovers) != 0 {
		t.Fatalf("leftover temp files: %v", leftovers)
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
		{"http://127.0.1.1:4000", "local"}, // any 127.0.0.0/8 loopback → local
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
		{Server: "https://api.barkpark.io"},         // later → "barkpark-2"
		{Name: "prod", Server: "https://other.com"}, // explicit name unaffected
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
		{"http://127.0.1.1:4000", "local"},       // Debian/Ubuntu /etc/hosts hostname
		{"http://127.255.255.254:4000", "local"}, // top of 127.0.0.0/8
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
		{Server: "http://localhost:4001"},                // unnamed later → "local-4001"
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

// TestResolveThemeID pins the theme-identity precedence (ts-w4c): BP_THEME env >
// config.json "theme" > the evergreen default, with empty/whitespace at any tier
// falling through. The --theme flag is unrelated (it selects light/dark MODE).
func TestResolveThemeID(t *testing.T) {
	cases := []struct {
		name string
		env  string // "" = unset
		cfg  *Config
		want string
	}{
		{"nil config, no env → default", "", nil, DefaultThemeID},
		{"empty config, no env → default", "", &Config{}, DefaultThemeID},
		{"config theme, no env", "", &Config{Theme: "midnight"}, "midnight"},
		{"env overrides config", "amber", &Config{Theme: "midnight"}, "amber"},
		{"env, nil config", "amber", nil, "amber"},
		{"whitespace config falls through to default", "", &Config{Theme: "   "}, DefaultThemeID},
		{"whitespace env falls through to config", "  ", &Config{Theme: "midnight"}, "midnight"},
		{"env is trimmed", "  amber  ", nil, "amber"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			// t.Setenv("") sets an empty value (auto-restored); ResolveThemeID
			// treats empty == unset, so this covers the "no env" tiers too.
			t.Setenv("BP_THEME", c.env)
			if got := ResolveThemeID(c.cfg); got != c.want {
				t.Errorf("ResolveThemeID(env=%q, cfg=%+v) = %q, want %q", c.env, c.cfg, got, c.want)
			}
		})
	}
}

// utf8BOM is the byte sequence a Windows editor (Notepad, PowerShell `>`) prepends
// to a UTF-8 file. encoding/json rejects it, so LoadConfig must strip it.
var utf8BOM = []byte{0xEF, 0xBB, 0xBF}

// TestBOMBricksLoadConfig is the failing-first proof for BP-ONB-12: a config.json
// saved by a Windows editor carries a leading UTF-8 BOM, which encoding/json will
// not accept — pre-fix this errored and bricked EVERY bp command. Post-fix
// LoadConfig strips the BOM and the config loads cleanly.
func TestBOMBricksLoadConfig(t *testing.T) {
	root := withTempConfigHome(t)
	dir := filepath.Join(root, "barkpark")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	body := []byte(`{"server":"https://api.barkpark.cloud","token":"tok","dataset":"production"}`)
	withBOM := append(append([]byte(nil), utf8BOM...), body...)
	if err := os.WriteFile(filepath.Join(dir, "config.json"), withBOM, 0o600); err != nil {
		t.Fatalf("write BOM config: %v", err)
	}

	got, err := LoadConfig()
	if err != nil {
		t.Fatalf("BOM-prefixed config must load (Windows Notepad/PowerShell save), got error: %v", err)
	}
	if got.Server != "https://api.barkpark.cloud" || got.Token != "tok" || got.Dataset != "production" {
		t.Fatalf("BOM-stripped config fields wrong: %+v", *got)
	}
}

// TestSaveConfigSelfHeals proves the BOM is a one-time hazard: after loading a
// BOM-poisoned file, a normal SaveConfig rewrites BOM-free bytes, so the next
// LoadConfig succeeds even without the strip. The on-disk file must not begin
// with a BOM.
func TestSaveConfigSelfHeals(t *testing.T) {
	root := withTempConfigHome(t)
	dir := filepath.Join(root, "barkpark")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	path := filepath.Join(dir, "config.json")
	withBOM := append(append([]byte(nil), utf8BOM...), []byte(`{"server":"http://localhost:4000"}`)...)
	if err := os.WriteFile(path, withBOM, 0o600); err != nil {
		t.Fatalf("write BOM config: %v", err)
	}

	cfg, err := LoadConfig()
	if err != nil {
		t.Fatalf("load BOM config: %v", err)
	}
	cfg.Server = "https://api.barkpark.cloud"
	if err := SaveConfig(cfg); err != nil {
		t.Fatalf("save: %v", err)
	}

	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read back: %v", err)
	}
	if bytes.HasPrefix(raw, utf8BOM) {
		t.Fatalf("SaveConfig must emit BOM-free JSON, got a leading BOM: %q", raw[:min(6, len(raw))])
	}
	got, err := LoadConfig()
	if err != nil {
		t.Fatalf("reload after self-heal: %v", err)
	}
	if got.Server != "https://api.barkpark.cloud" {
		t.Fatalf("self-healed server = %q, want https://api.barkpark.cloud", got.Server)
	}
}

// TestRememberServerAliasCollapsesOneInstance is the headline proof for D4 / the
// gyldendal-2 kill: reaching ONE instance via two hostnames — canonical then a
// custom domain — that share an InstanceID must collapse to a SINGLE known-server
// entry, fold the prior hostname into aliases, and mint NO "-2" phantom. Both
// hostnames (and the InstanceID) must resolve back to the one entry, and the
// alias hostname must read as active.
func TestRememberServerAliasCollapsesOneInstance(t *testing.T) {
	const canonical = "https://gyldendal.barkpark.cloud"
	const custom = "https://cms.gyldendal.no"

	c := &Config{}
	c.RememberServer(ServerEntry{Server: canonical, InstanceID: "inst-gyld", Token: "t1", Dataset: "production", LastConnected: "2026-07-01T00:00:00Z"})
	// Reconnect via a DIFFERENT hostname that resolves to the SAME instance.
	c.RememberServer(ServerEntry{Server: custom, InstanceID: "inst-gyld", Token: "t2", Dataset: "production", LastConnected: "2026-07-02T00:00:00Z"})

	list := c.KnownServerList()
	if len(list) != 1 {
		t.Fatalf("two hostnames of ONE instance must collapse to a single entry (no gyldendal-2), got %d: %+v", len(list), list)
	}
	front := list[0]
	if front.Server != custom {
		t.Fatalf("primary should be the latest hostname %q, got %q", custom, front.Server)
	}
	if front.Token != "t2" {
		t.Fatalf("front entry should reflect latest connect token, got %q", front.Token)
	}
	if len(front.Aliases) != 1 || normalizeServerURL(front.Aliases[0]) != normalizeServerURL(canonical) {
		t.Fatalf("prior hostname should fold into aliases, got %+v", front.Aliases)
	}
	// No phantom -2 handle.
	if got := c.DisplayName(front); strings.HasSuffix(got, "-2") {
		t.Fatalf("collapsed instance must not carry a phantom -2 name, got %q", got)
	}
	// Both hostnames + the InstanceID resolve to the ONE entry.
	if e, ok := c.FindServer(canonical); !ok || e.Server != custom {
		t.Fatalf("alias hostname should resolve to the one entry: %+v ok=%v", e, ok)
	}
	if e, ok := c.FindServer(custom); !ok || e.Server != custom {
		t.Fatalf("primary hostname should resolve: %+v ok=%v", e, ok)
	}
	if e, ok := c.FindServer("inst-gyld"); !ok || e.Server != custom {
		t.Fatalf("InstanceID should resolve to the one entry: %+v ok=%v", e, ok)
	}
	// The active flat server is the custom URL; the alias hostname must still read
	// as active (same instance).
	if !c.IsActiveServer(canonical) {
		t.Fatalf("alias hostname should read as active (same instance)")
	}
	if !c.IsActiveServer(custom) {
		t.Fatalf("primary hostname should read as active")
	}
}

// TestRememberServerAdoptsInstanceIDForKnownURL proves the ID-less→ID upgrade: a
// server first saved with no InstanceID (bare local/dev, or a legacy entry) is
// ADOPTED — not duplicated — when re-connected to the same URL once its ID is
// known. Falls back to URL equality because one side lacks an ID.
func TestRememberServerAdoptsInstanceIDForKnownURL(t *testing.T) {
	const url = "https://api.example.com"
	c := &Config{}
	c.RememberServer(ServerEntry{Server: url, Token: "t1", LastConnected: "2026-07-01T00:00:00Z"})
	c.RememberServer(ServerEntry{Server: url, InstanceID: "inst-x", Token: "t2", LastConnected: "2026-07-02T00:00:00Z"})

	list := c.KnownServerList()
	if len(list) != 1 {
		t.Fatalf("same URL must stay one entry, got %d: %+v", len(list), list)
	}
	if list[0].InstanceID != "inst-x" {
		t.Fatalf("re-connect should adopt the learned InstanceID, got %q", list[0].InstanceID)
	}
	if len(list[0].Aliases) != 0 {
		t.Fatalf("same-URL re-connect must not manufacture aliases, got %+v", list[0].Aliases)
	}
}

// TestServerEntryInstanceFieldsRoundTrip proves the new InstanceID + Aliases
// fields persist through save/load and an old config without them loads cleanly.
func TestServerEntryInstanceFieldsRoundTrip(t *testing.T) {
	withTempConfigHome(t)
	want := &Config{
		Server: "https://cms.gyldendal.no",
		KnownServers: []ServerEntry{
			{Server: "https://cms.gyldendal.no", InstanceID: "inst-gyld", Aliases: []string{"https://gyldendal.barkpark.cloud"}, Tier: "admin"},
		},
	}
	if err := SaveConfig(want); err != nil {
		t.Fatalf("save: %v", err)
	}
	got, err := LoadConfig()
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("instance-field round-trip mismatch:\n got=%+v\nwant=%+v", *got, *want)
	}
}

// TestConnectSeamStampsInstanceIDAndCollapsesAliases is the D9 ACTIVATION proof:
// it drives the REAL connect persistence seam (configStoreAdapter.Save — the exact
// path connectToBarkpark writes through), NOT RememberServer directly, with one
// InstanceID reached via two hostnames. It proves the wave-1 plumbing is no longer
// INERT: a SavedConfig carrying a fleet-row InstanceID+Team now stamps them onto a
// single ServerEntry, folds the prior hostname into aliases, and mints NO phantom
// "-2" — the whole point of D9 (the gyldendal-2 kill only lands once a real ID is
// stamped by a caller).
func TestConnectSeamStampsInstanceIDAndCollapsesAliases(t *testing.T) {
	withTempConfigHome(t)
	const canonical = "https://gyldendal.barkpark.cloud"
	const custom = "https://cms.gyldendal.no"
	store := configStoreAdapter{}

	// First connect: canonical hostname, ID + team learned from the fleet row.
	if err := store.Save(setup.SavedConfig{Server: canonical, InstanceID: "inst-gyld", Team: "Gyldendal", Token: "t1", Dataset: "production", LastConnected: "2026-07-01T00:00:00Z"}); err != nil {
		t.Fatalf("first connect save: %v", err)
	}
	// Second connect: a DIFFERENT hostname that resolves to the SAME instance ID.
	if err := store.Save(setup.SavedConfig{Server: custom, InstanceID: "inst-gyld", Team: "Gyldendal", Token: "t2", Dataset: "production", LastConnected: "2026-07-02T00:00:00Z"}); err != nil {
		t.Fatalf("second connect save: %v", err)
	}

	cfg, err := LoadConfig()
	if err != nil {
		t.Fatalf("load after connects: %v", err)
	}
	list := cfg.KnownServerList()
	if len(list) != 1 {
		t.Fatalf("two hostnames of one instance via the connect seam must collapse to ONE entry (no gyldendal-2), got %d: %+v", len(list), list)
	}
	e := list[0]
	if e.InstanceID != "inst-gyld" {
		t.Fatalf("connect seam must stamp the fleet-row InstanceID onto the entry (activation), got %q", e.InstanceID)
	}
	if e.Team != "Gyldendal" {
		t.Fatalf("connect seam must stamp the owning team, got %q", e.Team)
	}
	if e.Server != custom {
		t.Fatalf("primary should be the latest hostname %q, got %q", custom, e.Server)
	}
	if e.Token != "t2" {
		t.Fatalf("entry should reflect the latest connect token, got %q", e.Token)
	}
	if len(e.Aliases) != 1 || normalizeServerURL(e.Aliases[0]) != normalizeServerURL(canonical) {
		t.Fatalf("prior hostname should fold into aliases, got %+v", e.Aliases)
	}
	if got := cfg.DisplayName(e); strings.HasSuffix(got, "-2") {
		t.Fatalf("collapsed instance must not carry a phantom -2 name, got %q", got)
	}
	// The persisted active server is the latest URL; the alias hostname must still
	// resolve to the one entry and read as active (same instance).
	if _, ok := cfg.FindServer(canonical); !ok {
		t.Fatalf("alias hostname must resolve to the one entry through the persisted config")
	}
	if !cfg.IsActiveServer(canonical) {
		t.Fatalf("alias hostname should read as active (same instance)")
	}
}

// TestConfigThemeRoundTrips proves the theme key persists through save/load and an
// old config without it loads cleanly (empty → default via ResolveThemeID).
func TestConfigThemeRoundTrips(t *testing.T) {
	withTempConfigHome(t)
	t.Setenv("BP_THEME", "")
	if err := SaveConfig(&Config{Server: "http://localhost:4000", Theme: "midnight"}); err != nil {
		t.Fatalf("save: %v", err)
	}
	got, err := LoadConfig()
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if got.Theme != "midnight" {
		t.Errorf("Theme did not round-trip: got %q, want %q", got.Theme, "midnight")
	}
	if id := ResolveThemeID(got); id != "midnight" {
		t.Errorf("ResolveThemeID after load = %q, want midnight", id)
	}
}

// testCloudPAT is a Cloud PERSONAL ACCESS TOKEN shape: the "bpc_pat_" prefix plus
// 43 base64url chars (32 random bytes) = 51 chars, exactly what the control plane
// mints. The Bearer is OPAQUE to the client — require_user_or_pat accepts a
// session token (43 chars, no prefix) or a PAT on the same Authorization header —
// so bp neither parses nor validates the shape; a PAT drives the identical path.
// The value below is fixed, non-secret filler, never a live credential.
const testCloudPAT = "bpc_pat_AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHHIIIIJJJJKKK"

// TestConfigCloudTokenEnvReadWhenNoFile is the FAIL-BEFORE pin: with NO config
// file at all and only BARKPARK_CLOUD_TOKEN set, the persisted field is empty
// (which is all bp read before this slice — a CI job could not authenticate at
// all) while resolution now yields the env value and the authed gate opens.
func TestConfigCloudTokenEnvReadWhenNoFile(t *testing.T) {
	withTempConfigHome(t)
	t.Setenv(CloudTokenEnv, testCloudPAT)

	cfg, err := LoadConfig()
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	// The pre-change read path: the config-file field. Still empty — this is the
	// exact state in which `bp cloud site deploy --prebuilt` used to refuse.
	if cfg.CloudToken != "" {
		t.Fatalf("CloudToken field should stay empty (env is not folded into it), got %q", cfg.CloudToken)
	}
	if !cfg.HasCloudToken() {
		t.Fatal("HasCloudToken should be true from the env alone — CI has no config.json")
	}
	tok, src := cfg.ResolveCloudToken()
	if tok != testCloudPAT {
		t.Errorf("ResolveCloudToken token = %q, want the env PAT", tok)
	}
	if src != CloudTokenSourceEnv {
		t.Errorf("source = %q, want %q", src, CloudTokenSourceEnv)
	}
	// And it reaches the Bearer: CloudClient is the only seam to cloudclient.
	if got := cfg.CloudClient().Token; got != testCloudPAT {
		t.Errorf("CloudClient().Token = %q, want the env PAT", got)
	}
}

// TestConfigCloudTokenEnvWinsOverFile pins the precedence in the first direction:
// env beats a persisted cloud_token.
func TestConfigCloudTokenEnvWinsOverFile(t *testing.T) {
	withTempConfigHome(t)
	t.Setenv(CloudTokenEnv, testCloudPAT)

	if err := SaveConfig(&Config{CloudURL: "https://api.barkpark.cloud", CloudToken: "file-session-token"}); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}
	cfg, err := LoadConfig()
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	tok, src := cfg.ResolveCloudToken()
	if tok != testCloudPAT || src != CloudTokenSourceEnv {
		t.Fatalf("env must win: got (%q, %q)", tok, src)
	}
	if got := cfg.CloudClient().Token; got != testCloudPAT {
		t.Errorf("CloudClient().Token = %q, want the env PAT", got)
	}
	// The persisted value is untouched — an env override never rewrites the file.
	if cfg.CloudToken != "file-session-token" {
		t.Errorf("persisted CloudToken mutated: %q", cfg.CloudToken)
	}
}

// TestConfigCloudTokenEmptyEnvKeepsFileValue pins the OTHER direction — the
// no-regression half. Unset, empty and whitespace-only env all leave an
// interactive user on the token `bp login` wrote.
func TestConfigCloudTokenEmptyEnvKeepsFileValue(t *testing.T) {
	for _, tc := range []struct{ name, env string }{
		{"unset", ""},
		{"empty", ""},
		{"whitespace", "   \t\n"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			withTempConfigHome(t)
			if tc.name == "unset" {
				t.Setenv(CloudTokenEnv, "sentinel") // restored by t.Setenv on cleanup
				os.Unsetenv(CloudTokenEnv)
			} else {
				t.Setenv(CloudTokenEnv, tc.env)
			}
			cfg := &Config{CloudToken: "file-session-token"}
			tok, src := cfg.ResolveCloudToken()
			if tok != "file-session-token" || src != CloudTokenSourceConfig {
				t.Fatalf("config tier must be used: got (%q, %q)", tok, src)
			}
			if !cfg.HasCloudToken() {
				t.Error("HasCloudToken should stay true for a logged-in user")
			}
			if got := cfg.CloudClient().Token; got != "file-session-token" {
				t.Errorf("CloudClient().Token = %q, want the config value", got)
			}
			// And with NEITHER tier set, "not logged in" still reads as before.
			empty := &Config{}
			if empty.HasCloudToken() || empty.CloudTokenSource() != CloudTokenSourceNone {
				t.Errorf("empty config should be not-logged-in, source=%q", empty.CloudTokenSource())
			}
			if (*Config)(nil).HasCloudToken() {
				t.Error("nil config must not report a token")
			}
		})
	}
}

// TestConfigCloudTokenSourceNeverLeaksValue proves the credential is attributable
// but never exposed: the source label carries no substring of the token, and a
// load → mutate → SaveConfig cycle (what login/logout/setup do) cannot persist an
// env credential into config.json.
func TestConfigCloudTokenSourceNeverLeaksValue(t *testing.T) {
	root := withTempConfigHome(t)
	t.Setenv(CloudTokenEnv, testCloudPAT)

	cfg, err := LoadConfig()
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	src := cfg.CloudTokenSource()
	if src != CloudTokenSourceEnv {
		t.Fatalf("source = %q, want %q", src, CloudTokenSourceEnv)
	}
	if strings.Contains(src, testCloudPAT) || strings.Contains(src, strings.TrimPrefix(testCloudPAT, "bpc_pat_")) {
		t.Fatalf("source label leaks the credential: %q", src)
	}

	// A save while the env is set must not write the env token to disk.
	cfg.Server = "https://api.barkpark.cloud"
	if err := SaveConfig(cfg); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}
	raw, err := os.ReadFile(filepath.Join(root, "barkpark", "config.json"))
	if err != nil {
		t.Fatalf("read config.json: %v", err)
	}
	if bytes.Contains(raw, []byte(testCloudPAT)) {
		t.Fatalf("config.json embedded the env credential:\n%s", raw)
	}
}

// TestConfigCloudTokenPATShapeIsOpaque records the credential shapes and that bp
// treats the Bearer as opaque: a 51-char bpc_pat_ PAT and a 43-char session token
// resolve identically, with no prefix parsing or length validation client-side.
func TestConfigCloudTokenPATShapeIsOpaque(t *testing.T) {
	withTempConfigHome(t)
	if len(testCloudPAT) != 51 {
		t.Fatalf("PAT fixture should be 51 chars (bpc_pat_ + 43), got %d", len(testCloudPAT))
	}
	session := strings.TrimPrefix(testCloudPAT, "bpc_pat_") // 43 chars, the session shape
	if len(session) != 43 {
		t.Fatalf("session fixture should be 43 chars, got %d", len(session))
	}
	for _, tok := range []string{testCloudPAT, session, "anything-the-server-understands"} {
		t.Setenv(CloudTokenEnv, tok)
		got, src := (&Config{}).ResolveCloudToken()
		if got != tok || src != CloudTokenSourceEnv {
			t.Errorf("opaque Bearer %q resolved as (%q, %q)", tok, got, src)
		}
	}
}

// TestConfigCloudTokenReachesTheDoctorProbe closes the seam the env tier opened
// in a NEIGHBOURING file. doctorGateOpts arms its cloud-sites probe behind
// HasCloudToken(), which now answers true for an env-only credential — but the
// Bearer it attached came from cfg.CloudToken, the PERSISTED tier, which is empty
// in exactly that case. So CI got a probe pointed at /v1/sites with NO
// Authorization value and reported the 401 as a failed doctor check: a false red
// produced by the credential that works for every other Cloud command.
func TestConfigCloudTokenReachesTheDoctorProbe(t *testing.T) {
	withTempConfigHome(t)
	t.Setenv(CloudTokenEnv, testCloudPAT)

	g := doctorGateOpts("", "")
	if g.CloudSitesURL == "" {
		t.Fatalf("an env-only credential must still arm the cloud-sites probe; got %+v", g)
	}
	if g.CloudSitesToken != testCloudPAT {
		t.Fatalf("the probe must carry the RESOLVED token, not the empty persisted field; got %q", g.CloudSitesToken)
	}

	// And the persisted tier still works on its own, unchanged.
	t.Setenv(CloudTokenEnv, "")
	if err := SaveConfig(&Config{CloudToken: "from-the-file"}); err != nil {
		t.Fatalf("SaveConfig: %v", err)
	}
	if g := doctorGateOpts("", ""); g.CloudSitesToken != "from-the-file" {
		t.Fatalf("the persisted tier regressed; got %q", g.CloudSitesToken)
	}
}
