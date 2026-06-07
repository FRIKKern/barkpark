package cli

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// Config is the on-disk persisted connection + scope the CLI defaults to when no
// flag/env overrides it. It is the durable backing for manifest.ActiveContext —
// `bp setup` writes it, resolveContext reads it, and the precedence chain
// (flags > env > active(this) > defaults) means a saved config is the floor a
// bare `bp whoami` lands on while flags still win.
//
// It holds credentials, so it is written 0600 in a 0700 dir. JSON tags are
// snake_case to read cleanly when a user cats the file.
//
// The flat Server/Token/Workspace/Project/Dataset fields are the ACTIVE context
// (what ToActiveContext projects). KnownServers is a most-recent-first history
// of every server `bp setup --target connect` has reached — the pick-list the
// wizard offers so a returning user selects instead of re-typing a URL. An old
// config.json without the known_servers key loads cleanly (nil slice).
type Config struct {
	Server      string `json:"server,omitempty"`
	Token       string `json:"token,omitempty"`
	AdminToken  string `json:"admin_token,omitempty"`
	IngestToken string `json:"ingest_token,omitempty"`
	Workspace   string `json:"workspace,omitempty"`
	Project     string `json:"project,omitempty"`
	Dataset     string `json:"dataset,omitempty"`
	Output      string `json:"output,omitempty"`

	// KnownServers is the connect history, most-recent-first, capped at
	// maxKnownServers. RememberServer maintains it.
	KnownServers []ServerEntry `json:"known_servers,omitempty"`
}

// ServerEntry is one remembered connection in the connect history. It carries
// enough to re-select the server from the wizard without re-typing anything —
// the URL, the token + scope it was reached with, the resolved tier, and when
// it was last connected (RFC3339, stamped by the caller).
type ServerEntry struct {
	Server        string `json:"server,omitempty"`
	Token         string `json:"token,omitempty"`
	Workspace     string `json:"workspace,omitempty"`
	Project       string `json:"project,omitempty"`
	Dataset       string `json:"dataset,omitempty"`
	Tier          string `json:"tier,omitempty"`
	LastConnected string `json:"last_connected,omitempty"`
}

// maxKnownServers caps the connect history so the file never grows unbounded.
const maxKnownServers = 20

// normalizeServerURL canonicalises a server URL for upsert-equality: it trims a
// trailing slash and lowercases the scheme + host while preserving the path
// (paths are rare for a barkpark server but kept exact to avoid surprises). It
// is intentionally dependency-free — no net/url — so it cannot fail on the
// already-validated http(s) URLs setup feeds it.
func normalizeServerURL(raw string) string {
	s := strings.TrimRight(strings.TrimSpace(raw), "/")
	// Lowercase only the scheme://host authority; leave the path case intact.
	scheme := ""
	rest := s
	if i := strings.Index(s, "://"); i >= 0 {
		scheme = strings.ToLower(s[:i+3])
		rest = s[i+3:]
	}
	host := rest
	path := ""
	if j := strings.IndexByte(rest, '/'); j >= 0 {
		host = rest[:j]
		path = rest[j:]
	}
	return scheme + strings.ToLower(host) + path
}

// configDir returns the directory the config file lives in:
//
//	${XDG_CONFIG_HOME:-~/.config}/barkpark
//
// XDG_CONFIG_HOME wins when set (non-empty); otherwise it falls back to
// ~/.config under the user's home. os.UserHomeDir is the cross-platform home
// resolver, so this works the same on macOS and Linux.
func configDir() (string, error) {
	if xdg := os.Getenv("XDG_CONFIG_HOME"); xdg != "" {
		return filepath.Join(xdg, "barkpark"), nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("resolve home dir: %w", err)
	}
	return filepath.Join(home, ".config", "barkpark"), nil
}

// ConfigPath returns the absolute path to the persisted config file.
func ConfigPath() (string, error) {
	dir, err := configDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "config.json"), nil
}

// LoadConfig reads the persisted config. A MISSING file is not an error — it
// returns an empty &Config{} so a first run resolves purely off env/defaults.
// Only a present-but-unreadable or present-but-malformed file errors.
func LoadConfig() (*Config, error) {
	path, err := ConfigPath()
	if err != nil {
		return nil, err
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return &Config{}, nil
		}
		return nil, fmt.Errorf("read config %s: %w", path, err)
	}
	var c Config
	if err := json.Unmarshal(raw, &c); err != nil {
		return nil, fmt.Errorf("parse config %s: %w", path, err)
	}
	return &c, nil
}

// SaveConfig writes the config as pretty JSON, mkdir -p'ing the 0700 directory
// and writing the file 0600 (it holds tokens). It is idempotent: a re-save
// overwrites cleanly.
func SaveConfig(c *Config) error {
	if c == nil {
		c = &Config{}
	}
	dir, err := configDir()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("mkdir config dir %s: %w", dir, err)
	}
	path := filepath.Join(dir, "config.json")
	raw, err := json.MarshalIndent(c, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal config: %w", err)
	}
	raw = append(raw, '\n')
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		return fmt.Errorf("write config %s: %w", path, err)
	}
	// WriteFile honours the mode only on create; an overwrite keeps the prior
	// perms. Force 0600 explicitly so a re-save of a loosened file re-tightens it.
	if err := os.Chmod(path, 0o600); err != nil {
		return fmt.Errorf("chmod config %s: %w", path, err)
	}
	return nil
}

// RememberServer upserts entry into the connect history AND promotes it to the
// active flat context, so after RememberServer + SaveConfig the server is both
// the default `bp` lands on and the head of the pick-list.
//
// Upsert is by normalized Server URL (trailing slash trimmed, scheme+host
// lowercased): connecting to the same server twice collapses to one entry whose
// fields reflect the latest connect. The matched (or new) entry moves to the
// front so the list stays most-recent-first; the tail is trimmed to
// maxKnownServers. LastConnected is taken from entry.LastConnected verbatim —
// the caller stamps it (time.Now() in the executor, a fixed value in a test) so
// this stays a pure, deterministic helper.
func (c *Config) RememberServer(entry ServerEntry) {
	if c == nil {
		return
	}
	key := normalizeServerURL(entry.Server)

	// Drop any existing entry for the same normalized URL; we re-insert at front.
	kept := c.KnownServers[:0:0]
	for _, e := range c.KnownServers {
		if normalizeServerURL(e.Server) == key {
			continue
		}
		kept = append(kept, e)
	}
	c.KnownServers = append([]ServerEntry{entry}, kept...)
	if len(c.KnownServers) > maxKnownServers {
		c.KnownServers = c.KnownServers[:maxKnownServers]
	}

	// Promote to the active flat context.
	c.Server = entry.Server
	c.Token = entry.Token
	if entry.Workspace != "" {
		c.Workspace = entry.Workspace
	}
	if entry.Project != "" {
		c.Project = entry.Project
	}
	if entry.Dataset != "" {
		c.Dataset = entry.Dataset
	}
}

// KnownServerList returns the connect history most-recent-first. It returns a
// fresh slice (never the internal backing array) so callers cannot mutate the
// config's state by reordering the result. A nil history yields an empty slice.
func (c *Config) KnownServerList() []ServerEntry {
	if c == nil || len(c.KnownServers) == 0 {
		return []ServerEntry{}
	}
	out := make([]ServerEntry, len(c.KnownServers))
	copy(out, c.KnownServers)
	return out
}

// ActiveServer returns the URL of the currently-active server (the flat Server
// field) so a pick-list can mark which remembered entry is active. Equality is
// by normalized URL — IsActiveServer is the comparison callers should use.
func (c *Config) ActiveServer() string {
	if c == nil {
		return ""
	}
	return c.Server
}

// IsActiveServer reports whether server is the active one, compared by
// normalized URL.
func (c *Config) IsActiveServer(server string) bool {
	if c == nil || c.Server == "" {
		return false
	}
	return normalizeServerURL(c.Server) == normalizeServerURL(server)
}

// ToActiveContext projects the persisted config onto the manifest's
// ActiveContext layer — the persistence slot Resolve consults between env and
// defaults. Empty fields stay empty so they do not mask a lower default.
func (c *Config) ToActiveContext() manifest.ActiveContext {
	if c == nil {
		return manifest.ActiveContext{}
	}
	return manifest.ActiveContext{
		Server:    c.Server,
		Token:     c.Token,
		Workspace: c.Workspace,
		Project:   c.Project,
		Dataset:   c.Dataset,
		Output:    c.Output,
	}
}
