package cli

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
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

	// Theme is the persisted theme IDENTITY the CLI/TUI renders with (the emitted
	// skin — "evergreen" today). It is ORTHOGONAL to light/dark MODE (the --theme
	// flag still selects mode this wave, D30). Empty → the evergreen default.
	// BP_THEME overrides it per invocation; ResolveThemeID applies the precedence.
	Theme string `json:"theme,omitempty"`

	// Cloud control-plane credentials (cloud-12). These are SEPARATE from the
	// per-server Token above: Token authenticates against ONE content server,
	// CloudToken authenticates the user against the Barkpark Cloud control plane
	// that owns the whole fleet. `bp login` writes all three; everything else
	// (bp barkparks / provider add / launch / go-live) reads them. Empty CloudToken
	// → not logged in; the Cloud commands tell the user to run `bp login`.
	//
	// CloudToken is the PERSISTED tier only — read it through ResolveCloudToken so
	// the BARKPARK_CLOUD_TOKEN env override (how CI authenticates, since there is
	// no `bp login` there) wins as documented.
	CloudURL   string `json:"cloud_url,omitempty"`
	CloudToken string `json:"cloud_token,omitempty"`
	CloudTeam  string `json:"cloud_team,omitempty"`

	// KnownServers is the connect history, most-recent-first, capped at
	// maxKnownServers. RememberServer maintains it.
	KnownServers []ServerEntry `json:"known_servers,omitempty"`
}

// configPersist is Config WITHOUT its MarshalJSON method: converting to a
// distinct defined type drops the method set, so json.Marshal of a
// *configPersist uses the DEFAULT struct marshalling and emits the real token
// fields. It exists solely so SaveConfig can persist live credentials to the
// 0600 config.json — it MUST be marshalled ONLY by SaveConfig. Every other
// marshal of a Config (a debug dump, a future `-o json` of the resolved
// context) goes through Config.MarshalJSON below and is redacted.
type configPersist Config

// MarshalJSON redacts every token-bearing field so a PUBLIC marshal of a Config
// can never serialize a live credential. It blanks the four flat tokens (Token,
// AdminToken, IngestToken, CloudToken) AND the nested per-server
// KnownServers[].Token, deep-copying KnownServers first so the caller's live
// Config is never mutated — a slice shares its backing array, so blanking in
// place would wipe the real token from the in-memory config the caller still
// holds. The value receiver means both a Config and a *Config redact. The only
// path that persists real tokens is SaveConfig, which marshals a configPersist
// (no MarshalJSON) to write the 0600 config.json.
//
// NOTE: the literal filed hazard — retagging Config.Token to json:"-" — is
// REFUTED: SaveConfig marshals the SAME *Config it persists, so json:"-" would
// silently stop writing the token to disk (a silent-logout regression, not a
// leak-plug). Redacting at the public marshal seam while persisting through
// configPersist plugs the leak WITHOUT breaking persistence.
func (c Config) MarshalJSON() ([]byte, error) {
	redacted := c
	redacted.Token = ""
	redacted.AdminToken = ""
	redacted.IngestToken = ""
	redacted.CloudToken = ""
	if len(c.KnownServers) > 0 {
		redacted.KnownServers = make([]ServerEntry, len(c.KnownServers))
		copy(redacted.KnownServers, c.KnownServers)
		for i := range redacted.KnownServers {
			redacted.KnownServers[i].Token = ""
		}
	}
	return json.Marshal(configPersist(redacted))
}

// CloudTokenEnv is the environment variable a NON-INTERACTIVE client (a GitHub
// Action, any CI job) sets to authenticate against the Cloud control plane
// without a config.json — there is no `bp login` in CI to write one.
const CloudTokenEnv = "BARKPARK_CLOUD_TOKEN"

// Where a resolved Cloud token came from. It names the ORIGIN only and never
// carries any part of the credential, so it is safe in any diagnostic output.
const (
	CloudTokenSourceNone   = ""                     // no token anywhere → not logged in
	CloudTokenSourceEnv    = "env:" + CloudTokenEnv // the CI/env override
	CloudTokenSourceConfig = "config:cloud_token"   // ~/.config/barkpark/config.json
)

// ResolveCloudToken picks the Cloud control-plane Bearer by PRECEDENCE:
//
//  1. the BARKPARK_CLOUD_TOKEN env var (highest — a per-invocation override)
//  2. the persisted config.json "cloud_token" (what `bp login` writes)
//
// A whitespace-only value at either tier falls through to the next, so an
// exported-but-empty BARKPARK_CLOUD_TOKEN leaves every interactive user on the
// value in their config file, unchanged. The token is returned TRIMMED.
//
// The second return is the SOURCE — an origin label, never any part of the
// credential — so a CI failure is debuggable ("which credential did bp even
// use?") without printing a live secret. Nothing in bp logs, echoes or persists
// the value: the env tier is resolved at USE time and is deliberately NOT folded
// into Config.CloudToken, so a load → mutate → SaveConfig cycle (login, logout,
// setup) can never write a CI credential into config.json.
//
// The Bearer is OPAQUE to the client: the control plane's require_user_or_pat
// accepts a session token (43 chars) or a PAT ("bpc_pat_" + 43 = 51 chars) on
// the same Authorization header, so a PAT in the env drives this identical path
// with no other change (the artifact route gates on {:ability,"write"},
// cloud/…/router.ex:6292 — superseding charter D91's session-only record).
func (c *Config) ResolveCloudToken() (string, string) {
	if env := strings.TrimSpace(os.Getenv(CloudTokenEnv)); env != "" {
		return env, CloudTokenSourceEnv
	}
	if c != nil {
		if tok := strings.TrimSpace(c.CloudToken); tok != "" {
			return tok, CloudTokenSourceConfig
		}
	}
	return "", CloudTokenSourceNone
}

// CloudTokenSource names where the active Cloud credential came from (env,
// config, or none) WITHOUT exposing it — the attributable half of
// ResolveCloudToken, for receipts and diagnostics.
func (c *Config) CloudTokenSource() string {
	_, source := c.ResolveCloudToken()
	return source
}

// CloudClient builds a control-plane client from the resolved Cloud credentials.
// It is the single seam between the on-disk config and internal/cloudclient: the
// CloudURL falls back to cloudclient.DefaultBaseURL when unset, and the token
// ResolveCloudToken picks (env > config, see there) is attached as the Bearer for
// every authed call. HasCloudToken gates whether a command may use it — this just
// constructs it.
func (c *Config) CloudClient() *cloudclient.Client {
	base := ""
	if c != nil {
		base = c.CloudURL
	}
	if base == "" {
		base = cloudclient.DefaultBaseURL
	}
	token, _ := c.ResolveCloudToken()
	return &cloudclient.Client{BaseURL: base, Token: token}
}

// HasCloudToken reports whether a Cloud credential is present — from the
// BARKPARK_CLOUD_TOKEN env or the persisted config, same precedence as
// ResolveCloudToken. It is the gate the authed Cloud commands check before making
// any control-plane call, so CI sets one env var and the whole authed surface
// (including `bp cloud site deploy --prebuilt`) becomes reachable.
func (c *Config) HasCloudToken() bool {
	token, _ := c.ResolveCloudToken()
	return token != ""
}

// DefaultThemeID is the built-in skin every surface falls back to. It mirrors the
// emitted pdrender.DefaultTheme / semrole.DefaultTheme const, duplicated here so
// internal/cli need not import a render package for one string.
const DefaultThemeID = "evergreen"

// ResolveThemeID picks the active theme IDENTITY by precedence: the BP_THEME env
// (highest — a per-invocation override), then the persisted config.json "theme"
// key, then the built-in evergreen default. An empty/whitespace value at any tier
// falls through to the next. This is theme identity only — orthogonal to the
// light/dark MODE the --theme flag selects this wave (charter D30). An unknown id
// is returned as-is; the render-side Resolve(theme) is what falls back to
// evergreen for it, so a typo degrades to the default skin instead of erroring.
func ResolveThemeID(c *Config) string {
	if env := strings.TrimSpace(os.Getenv("BP_THEME")); env != "" {
		return env
	}
	if c != nil {
		if t := strings.TrimSpace(c.Theme); t != "" {
			return t
		}
	}
	return DefaultThemeID
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
	Name   string `json:"name,omitempty"`
	Server string `json:"server,omitempty"`
	// InstanceID is the STABLE server-side identity of the Barkpark instance this
	// entry points at (the control plane's DomainStatusResult.Instance.ID). It is
	// the primary upsert key: two hostnames that resolve to the same InstanceID
	// collapse to ONE known-server entry instead of minting a phantom "-2" second
	// server (the gyldendal-2 class). Empty for a bare local dev server whose ID
	// was never learned — those fall back to normalized-URL equality (D4). A caller
	// that knows the ID (attach/connect against the control plane) stamps it here.
	InstanceID string `json:"instance_id,omitempty"`
	// Aliases are the OTHER hostnames known to reach this same instance, most-recent
	// primary-first exclusive of the current Server. When a saved instance is
	// re-reached via a new hostname, the prior primary URL folds into Aliases so no
	// URL is lost and `bp use <either-host>` still resolves to the one entry.
	Aliases []string `json:"aliases,omitempty"`
	// Team is the human name of the Cloud team that owns this instance, learned
	// from the control-plane fleet row at connect time (cloudclient.Barkpark.Team).
	// It is IDENTITY only — the credential is still the per-server Token — and lets
	// a receipt (whoami / doctor) name the owning team from the local entry without
	// a live fleet round-trip. Empty for a self-hosted attach with no control plane.
	Team          string `json:"team,omitempty"`
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

// FirstRun reports whether bp has never been configured: no config file on
// disk AND no BARKPARK_* server env actually set (the same actually-set test
// envContext applies — an unset var is unset, never the baked localhost floor).
// It routes first-run UX only (the bare-`bp` wizard, the friendlier manifest
// error) and never changes command semantics.
func FirstRun() bool {
	// axi-b4: read from the shared dialect lists, so a name the resolver honours
	// can never leave a configured user being offered the first-run wizard.
	if anyEnvSet(ServerEnvNames...) || anyEnvSet(TokenEnvNames...) {
		return false
	}
	path, err := ConfigPath()
	if err != nil {
		return false
	}
	if _, err := os.Stat(path); err == nil {
		return false
	}
	return true
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
	// Strip a leading UTF-8 BOM (EF BB BF) before unmarshalling. Windows editors
	// (Notepad, PowerShell's `>` redirection) prepend one, and encoding/json rejects
	// it — a single stray BOM would otherwise brick the whole CLI with a parse error
	// on every command. SaveConfig always emits BOM-free bytes, so a re-save
	// self-heals the file (BP-ONB-12).
	raw = bytes.TrimPrefix(raw, []byte{0xEF, 0xBB, 0xBF})
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
	// Marshal through configPersist (which has NO MarshalJSON) so the persisted
	// 0600 file carries the REAL tokens. Marshalling c directly would hit
	// Config.MarshalJSON and redact every credential — a silent logout on every
	// save. This is the ONLY sanctioned marshal of a configPersist.
	raw, err := json.MarshalIndent((*configPersist)(c), "", "  ")
	if err != nil {
		return fmt.Errorf("marshal config: %w", err)
	}
	raw = append(raw, '\n')
	// Write to a temp file in the same dir (same filesystem → atomic rename), then
	// rename over the target. A crash or a concurrent bp can't observe a truncated
	// or interleaved config.json — the reader sees either the old file or the new
	// one, never a half-written one. CreateTemp defaults to 0600; Chmod re-tightens
	// belt-and-suspenders so a re-save of a loosened file lands at 0600.
	tmp, err := os.CreateTemp(dir, "config-*.json")
	if err != nil {
		return fmt.Errorf("create temp config in %s: %w", dir, err)
	}
	if _, err := tmp.Write(raw); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		return fmt.Errorf("write temp config %s: %w", tmp.Name(), err)
	}
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		return fmt.Errorf("chmod temp config %s: %w", tmp.Name(), err)
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmp.Name())
		return fmt.Errorf("close temp config %s: %w", tmp.Name(), err)
	}
	if err := os.Rename(tmp.Name(), path); err != nil {
		os.Remove(tmp.Name())
		return fmt.Errorf("rename config %s: %w", path, err)
	}
	return nil
}

// sameEntryIdentity reports whether two entries refer to the same Barkpark
// instance. Identity is by InstanceID FIRST — when BOTH carry one, only the ID
// decides (case-insensitive), so a second hostname of one instance is the same
// entry regardless of URL. When either lacks an ID (bare local dev, or a legacy
// entry saved before IDs were tracked), it falls back to normalized-URL equality
// against the primary Server or any recorded alias (D4).
func sameEntryIdentity(a, b ServerEntry) bool {
	aid := strings.TrimSpace(a.InstanceID)
	bid := strings.TrimSpace(b.InstanceID)
	if aid != "" && bid != "" {
		return strings.EqualFold(aid, bid)
	}
	return entryHasURL(a, b.Server) || entryHasURL(b, a.Server)
}

// entryHasURL reports whether rawURL (normalized) matches the entry's primary
// Server URL or any of its recorded aliases. It is the URL-fallback half of
// identity and the alias-aware resolver `bp use <host>` / whoami rely on.
func entryHasURL(entry ServerEntry, rawURL string) bool {
	key := normalizeServerURL(rawURL)
	if key == "" {
		return false
	}
	if normalizeServerURL(entry.Server) == key {
		return true
	}
	for _, a := range entry.Aliases {
		if normalizeServerURL(a) == key {
			return true
		}
	}
	return false
}

// mergeAliases builds the alias set for a re-connected instance: every hostname
// previously known for it EXCEPT the new primary URL, deduped by normalized form
// and order-stable (the matched entry's old primary first, then its prior
// aliases, then any the incoming entry itself carried). The raw string of the
// first occurrence is kept. A plain re-connect to the SAME URL yields exactly the
// matched entry's existing aliases (the old primary == new primary is skipped).
func mergeAliases(primary string, matched ServerEntry, incoming []string) []string {
	seen := map[string]bool{}
	if k := normalizeServerURL(primary); k != "" {
		seen[k] = true
	}
	var out []string
	add := func(raw string) {
		k := normalizeServerURL(raw)
		if k == "" || seen[k] {
			return
		}
		seen[k] = true
		out = append(out, raw)
	}
	add(matched.Server)
	for _, a := range matched.Aliases {
		add(a)
	}
	for _, a := range incoming {
		add(a)
	}
	return out
}

// RememberServer upserts entry into the connect history AND promotes it to the
// active flat context, so after RememberServer + SaveConfig the server is both
// the default `bp` lands on and the head of the pick-list.
//
// Upsert is by INSTANCE IDENTITY (sameEntryIdentity): InstanceID when both sides
// carry one, else normalized Server URL (trailing slash trimmed, scheme+host
// lowercased). Re-connecting to the same instance — even via a DIFFERENT hostname
// once its InstanceID is known — collapses to one entry whose fields reflect the
// latest connect and whose prior hostname folds into Aliases (no phantom "-2"
// second server). The matched (or new) entry moves to the front so the list stays
// most-recent-first; the tail is trimmed to maxKnownServers. LastConnected is
// taken verbatim so this stays a pure, deterministic helper.
func (c *Config) RememberServer(entry ServerEntry) {
	if c == nil {
		return
	}

	// Split off the first entry that is the SAME instance; keep the rest in order.
	kept := c.KnownServers[:0:0]
	matched := ServerEntry{}
	haveMatch := false
	for _, e := range c.KnownServers {
		if !haveMatch && sameEntryIdentity(e, entry) {
			matched = e
			haveMatch = true
			continue
		}
		kept = append(kept, e)
	}

	if haveMatch {
		// A plain re-connect that didn't set a name/ID inherits what the matched
		// entry already carried, so nothing a prior connect learned is lost.
		if entry.Name == "" {
			entry.Name = matched.Name
		}
		if strings.TrimSpace(entry.InstanceID) == "" {
			entry.InstanceID = matched.InstanceID
		}
		// Fold every previously-known hostname (except the new primary) into aliases.
		entry.Aliases = mergeAliases(entry.Server, matched, entry.Aliases)
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

	// Localhost family special-case: the bare "local" handle goes to whichever
	// local sorts FIRST (most-recent-first); any additional local disambiguates by
	// PORT ("local-4001") rather than a bare ordinal. "Already claimed" counts any
	// earlier entry whose DISPLAY handle is "local" — including one that carries an
	// explicit Name "local" — so we never print two identical "local" rows.
	if base == "local" {
		claimed := false
		for _, other := range c.KnownServers {
			if sameEntryIdentity(other, e) {
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
		if sameEntryIdentity(other, e) {
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
	// Loopback (127.0.0.0/8, e.g. Debian/Ubuntu's 127.0.1.1) + RFC1918 private
	// IPv4 ranges → local.
	if isIPv4(host) {
		parts := strings.Split(host, ".")
		a := atoiByte(parts[0])
		b := atoiByte(parts[1])
		switch {
		case a == 127:
			return "local"
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
	// Any 127.0.0.0/8 loopback (e.g. Debian/Ubuntu's 127.0.1.1) → "local".
	if isIPv4(low) && atoiByte(strings.Split(low, ".")[0]) == 127 {
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

// FindServer resolves a name-or-URL-or-instance-ID to a known ServerEntry. It
// matches, in order per entry: a case-insensitive equality against the explicit
// Name; against the InstanceID; against the unique DisplayName; and a normalized-
// URL equality against the entry's Server OR any of its aliases. The first hit
// wins (most-recent-first order) — so either hostname of a multi-alias instance
// resolves to the one entry. Returns ok=false when nothing matches.
func (c *Config) FindServer(nameOrURL string) (ServerEntry, bool) {
	if c == nil {
		return ServerEntry{}, false
	}
	q := strings.TrimSpace(nameOrURL)
	if q == "" {
		return ServerEntry{}, false
	}
	qLower := strings.ToLower(q)
	for _, e := range c.KnownServers {
		if strings.TrimSpace(e.Name) != "" && strings.EqualFold(e.Name, q) {
			return e, true
		}
		if id := strings.TrimSpace(e.InstanceID); id != "" && strings.EqualFold(id, q) {
			return e, true
		}
		if strings.ToLower(c.DisplayName(e)) == qLower {
			return e, true
		}
		if entryHasURL(e, q) {
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

// IsActiveServer reports whether server is the active one. The fast path is
// normalized-URL equality against the active flat Server (the only signal for a
// bare local dev server with no known entry). Beyond that it is instance-aware:
// if `server` is an alias of the active entry, or resolves to a known entry that
// shares the active entry's InstanceID, it is still "active" — so `bp servers`
// marks the one row for a multi-hostname instance no matter which host is active.
func (c *Config) IsActiveServer(server string) bool {
	if c == nil || c.Server == "" {
		return false
	}
	if normalizeServerURL(c.Server) == normalizeServerURL(server) {
		return true
	}
	active, ok := c.activeKnownEntry()
	if !ok {
		return false
	}
	if entryHasURL(active, server) {
		return true
	}
	id := strings.TrimSpace(active.InstanceID)
	if id == "" {
		return false
	}
	for _, e := range c.KnownServers {
		if entryHasURL(e, server) {
			return strings.EqualFold(strings.TrimSpace(e.InstanceID), id)
		}
	}
	return false
}

// activeKnownEntry returns the known entry the active flat Server points at,
// matching by primary URL or alias. It is the seam IsActiveServer / callers use
// to recover the active instance's identity (InstanceID, aliases) from the flat
// context, which stores only the active URL.
func (c *Config) activeKnownEntry() (ServerEntry, bool) {
	if c == nil || c.Server == "" {
		return ServerEntry{}, false
	}
	for _, e := range c.KnownServers {
		if entryHasURL(e, c.Server) {
			return e, true
		}
	}
	return ServerEntry{}, false
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
