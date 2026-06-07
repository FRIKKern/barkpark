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
//
// Name is the short handle the user types in `bp use <name>` and `bp -s <name>`.
// It is set explicitly via `bp setup --name`, else derived from the URL by
// DisplayName. An empty Name on a pre-existing entry is fine — DisplayName
// derives one on the fly, and bp never re-connects just to backfill it.
type ServerEntry struct {
	Name          string `json:"name,omitempty"`
	Server        string `json:"server,omitempty"`
	Token         string `json:"token,omitempty"`
	Workspace     string `json:"workspace,omitempty"`
	Project       string `json:"project,omitempty"`
	Dataset       string `json:"dataset,omitempty"`
	Tier          string `json:"tier,omitempty"`
	LastConnected string `json:"last_connected,omitempty"`
	// Kind is an OPTIONAL override for the derived local/cloud classification. It
	// is left empty by default — KindOf derives "local"/"cloud" from the URL on
	// demand — and exists only so a future workflow can pin an entry's kind (e.g.
	// a private-IP server the user wants treated as "cloud"). Empty → derived.
	Kind string `json:"kind,omitempty"`
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
	// If the incoming entry has no explicit Name, inherit the name the matched
	// entry already carried so a plain re-connect keeps a previously-chosen handle.
	kept := c.KnownServers[:0:0]
	for _, e := range c.KnownServers {
		if normalizeServerURL(e.Server) == key {
			if entry.Name == "" {
				entry.Name = e.Name
			}
			continue
		}
		kept = append(kept, e)
	}

	// Derive a Name when none was supplied (and none inherited). Uniqueness is
	// computed against the OTHER kept entries so the new handle never collides.
	if strings.TrimSpace(entry.Name) == "" {
		entry.Name = deriveUniqueName(entry.Server, kept)
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

// DisplayName returns the short handle for an entry: its explicit Name when set,
// else a handle auto-derived from the server URL. localhost / 127.0.0.1 / ::1 →
// "local"; any other host → the first meaningful DNS label with a leading "api"
// or "www" dropped (api.barkpark.cloud → "barkpark", staging.foo.com →
// "staging"). DisplayName does NOT enforce uniqueness on its own — call it
// through DisplayName on the Config (the method below) to get collision suffixes
// across known_servers. This free function is the per-entry derivation only.
func DisplayName(e ServerEntry) string {
	if n := strings.TrimSpace(e.Name); n != "" {
		return n
	}
	return deriveName(e.Server)
}

// DisplayName (method) returns the unique display handle for one entry within
// the context of the whole known-server list: an explicit Name is returned
// verbatim; an unnamed entry's derived handle is suffixed -2/-3/… when it would
// otherwise collide with another entry's display handle that sorts ahead of it
// (earlier in the most-recent-first list). This is what `bp servers` / `bp use`
// show so two unnamed servers that derive the same base never print identically.
func (c *Config) DisplayName(e ServerEntry) string {
	if n := strings.TrimSpace(e.Name); n != "" {
		return n
	}
	if c == nil {
		return deriveName(e.Server)
	}
	base := deriveName(e.Server)
	key := normalizeServerURL(e.Server)

	// Localhost family special-case: the bare "local" handle goes to whichever
	// local sorts FIRST (most-recent-first); any additional local disambiguates by
	// PORT ("local-4001") rather than a bare ordinal. "Already claimed" counts any
	// earlier entry whose DISPLAY handle is "local" — including one that carries an
	// explicit Name "local" — so we never print two identical "local" rows.
	if base == "local" {
		claimed := false
		for _, other := range c.KnownServers {
			if normalizeServerURL(other.Server) == key {
				break
			}
			if strings.EqualFold(c.DisplayName(other), "local") {
				claimed = true
				break
			}
		}
		name := localBaseName(e.Server, !claimed)
		if name != "local" || !claimed {
			return name
		}
		// Port-less additional local with the bare handle taken — ordinal fallback.
		return fmt.Sprintf("%s-2", base)
	}

	// Walk the list; count how many DISTINCT earlier servers derive the same base
	// (skipping ones that carry an explicit Name — those don't claim the base).
	rank := 0
	for _, other := range c.KnownServers {
		if normalizeServerURL(other.Server) == key {
			break
		}
		if strings.TrimSpace(other.Name) != "" {
			continue
		}
		if deriveName(other.Server) == base {
			rank++
		}
	}
	if rank == 0 {
		return base
	}
	return fmt.Sprintf("%s-%d", base, rank+1)
}

// ServerKind classifies a server URL as "local" or "cloud" from its host alone,
// dependency-free (no net/url, reusing hostOf / isIPv4). "local" covers the
// loopback family (localhost, 127.0.0.1, ::1, [::1]), any *.local mDNS name, and
// the RFC1918 private IPv4 ranges (10.0.0.0/8, 192.168.0.0/16, 172.16.0.0/12 —
// i.e. 172.16–172.31). Everything else — public DNS names and public IPs — is
// "cloud". This is the deriving classifier; an explicit ServerEntry.Kind
// override (when present) is honoured by Config.KindOf, not here.
func ServerKind(server string) string {
	host := strings.ToLower(hostOf(server))
	if host == "" {
		return "cloud"
	}
	switch host {
	case "localhost", "127.0.0.1", "::1", "[::1]":
		return "local"
	}
	// *.local mDNS names (e.g. mymac.local) are local.
	if strings.HasSuffix(host, ".local") {
		return "local"
	}
	// RFC1918 private IPv4 ranges → local.
	if isIPv4(host) {
		parts := strings.Split(host, ".")
		a := atoiByte(parts[0])
		b := atoiByte(parts[1])
		switch {
		case a == 10:
			return "local"
		case a == 192 && b == 168:
			return "local"
		case a == 172 && b >= 16 && b <= 31:
			return "local"
		}
		return "cloud"
	}
	return "cloud"
}

// atoiByte parses a 1–3 digit decimal octet to an int (0 on garbage). Cheap, no
// strconv — the input is already isIPv4-validated to be all-digit, ≤3 chars.
func atoiByte(s string) int {
	n := 0
	for _, r := range s {
		if r < '0' || r > '9' {
			return 0
		}
		n = n*10 + int(r-'0')
	}
	return n
}

// KindOf returns the kind of one entry: its explicit Kind override when set,
// else the derived ServerKind of its URL. The free ServerKind ignores overrides;
// this method is the one to call when an entry might carry a pin.
func (c *Config) KindOf(e ServerEntry) string {
	if k := strings.TrimSpace(e.Kind); k != "" {
		return k
	}
	return ServerKind(e.Server)
}

// deriveName turns a server URL into a base handle (no uniqueness). It is the
// dependency-free core of DisplayName: localhost family → "local"; otherwise the
// first meaningful DNS label with a leading "api"/"www" dropped, lowercased. A
// bare IP or unparseable host falls back to the host text itself; an empty URL
// yields "server".
func deriveName(server string) string {
	host := hostOf(server)
	if host == "" {
		return "server"
	}
	low := strings.ToLower(host)
	switch low {
	case "localhost", "127.0.0.1", "::1", "[::1]":
		return "local"
	}
	// Numeric IPv4 → use it verbatim (no DNS labels to mine).
	if isIPv4(low) {
		return low
	}
	labels := strings.Split(low, ".")
	// Drop a leading "api"/"www" so api.barkpark.cloud → barkpark.
	idx := 0
	if len(labels) > 1 && (labels[0] == "api" || labels[0] == "www") {
		idx = 1
	}
	if idx < len(labels) && labels[idx] != "" {
		return labels[idx]
	}
	return low
}

// deriveUniqueName derives a base handle for server and suffixes it -2/-3/… until
// it does not collide (case-insensitively) with any display handle already
// claimed by the others. Used by RememberServer when no explicit --name is given.
func deriveUniqueName(server string, others []ServerEntry) string {
	taken := map[string]bool{}
	for _, e := range others {
		taken[strings.ToLower(DisplayName(e))] = true
	}
	base := deriveName(server)
	if !taken[strings.ToLower(base)] {
		return base
	}
	// Localhost family: prefer "local-<port>" over a bare ordinal when the base
	// "local" is already claimed and this server carries a port.
	if base == "local" {
		if p := portOf(server); p != "" {
			cand := "local-" + p
			if !taken[strings.ToLower(cand)] {
				return cand
			}
		}
	}
	for n := 2; ; n++ {
		cand := fmt.Sprintf("%s-%d", base, n)
		if !taken[strings.ToLower(cand)] {
			return cand
		}
	}
}

// hostOf extracts the host (authority minus userinfo/port/path) from a URL
// without importing net/url. It mirrors normalizeServerURL's parsing.
func hostOf(raw string) string {
	s := strings.TrimSpace(raw)
	if i := strings.Index(s, "://"); i >= 0 {
		s = s[i+3:]
	}
	// Strip path.
	if j := strings.IndexByte(s, '/'); j >= 0 {
		s = s[:j]
	}
	// Strip userinfo.
	if at := strings.LastIndexByte(s, '@'); at >= 0 {
		s = s[at+1:]
	}
	// Bracketed IPv6 literal: keep the brackets intact (matched verbatim above).
	if strings.HasPrefix(s, "[") {
		if end := strings.IndexByte(s, ']'); end >= 0 {
			return s[:end+1]
		}
		return s
	}
	// Strip :port.
	if c := strings.LastIndexByte(s, ':'); c >= 0 {
		s = s[:c]
	}
	return s
}

// portOf extracts the port from a URL's authority, or "" when none is present.
// Mirrors hostOf's parsing: strips scheme, path, and userinfo, leaves an IPv6
// literal's bracketed body alone, and returns the text after the LAST ':' when
// that ':' sits outside any bracket. "http://localhost:4001/x" → "4001".
func portOf(raw string) string {
	s := strings.TrimSpace(raw)
	if i := strings.Index(s, "://"); i >= 0 {
		s = s[i+3:]
	}
	if j := strings.IndexByte(s, '/'); j >= 0 {
		s = s[:j]
	}
	if at := strings.LastIndexByte(s, '@'); at >= 0 {
		s = s[at+1:]
	}
	// Bracketed IPv6 literal — a port follows the closing ']'.
	if strings.HasPrefix(s, "[") {
		if end := strings.IndexByte(s, ']'); end >= 0 {
			rest := s[end+1:]
			if strings.HasPrefix(rest, ":") {
				return rest[1:]
			}
			return ""
		}
		return ""
	}
	if c := strings.LastIndexByte(s, ':'); c >= 0 {
		return s[c+1:]
	}
	return ""
}

// localBaseName derives the base handle for a server already known to derive the
// localhost base "local". The FIRST local keeps the bare "local"; an additional
// local on a DIFFERENT port disambiguates by port ("local-4001") rather than a
// bare ordinal "-2". isFirst tells the caller whether this entry is the one that
// claims the bare "local" (the most-recent-first front local). When the port is
// absent or the entry is the first local, the bare base "local" is returned.
func localBaseName(server string, isFirst bool) string {
	if isFirst {
		return "local"
	}
	if p := portOf(server); p != "" {
		return "local-" + p
	}
	return "local"
}

// isIPv4 reports whether s is a dotted-quad IPv4 literal (cheap check, no net).
func isIPv4(s string) bool {
	parts := strings.Split(s, ".")
	if len(parts) != 4 {
		return false
	}
	for _, p := range parts {
		if p == "" || len(p) > 3 {
			return false
		}
		for _, r := range p {
			if r < '0' || r > '9' {
				return false
			}
		}
	}
	return true
}

// FindServer resolves a name-or-URL to a known ServerEntry. It matches, in
// order: a case-insensitive equality against each entry's explicit Name; against
// each entry's unique DisplayName; and a normalized-URL equality against each
// entry's Server. The first hit wins (most-recent-first order). Returns ok=false
// when nothing matches.
func (c *Config) FindServer(nameOrURL string) (ServerEntry, bool) {
	if c == nil {
		return ServerEntry{}, false
	}
	q := strings.TrimSpace(nameOrURL)
	if q == "" {
		return ServerEntry{}, false
	}
	qLower := strings.ToLower(q)
	qURL := normalizeServerURL(q)
	for _, e := range c.KnownServers {
		if strings.TrimSpace(e.Name) != "" && strings.EqualFold(e.Name, q) {
			return e, true
		}
		if strings.ToLower(c.DisplayName(e)) == qLower {
			return e, true
		}
		if normalizeServerURL(e.Server) == qURL {
			return e, true
		}
	}
	return ServerEntry{}, false
}

// SetActiveServer promotes a known entry's server + token + scope to the active
// flat fields. The caller is responsible for SaveConfig afterwards. Empty scope
// fields on the entry leave the existing active scope intact (so promoting an
// entry that never recorded a workspace does not blank the current one); the
// Server and Token are always taken verbatim from the entry.
func (c *Config) SetActiveServer(e ServerEntry) {
	if c == nil {
		return
	}
	c.Server = e.Server
	c.Token = e.Token
	if e.Workspace != "" {
		c.Workspace = e.Workspace
	}
	if e.Project != "" {
		c.Project = e.Project
	}
	if e.Dataset != "" {
		c.Dataset = e.Dataset
	}
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
