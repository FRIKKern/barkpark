// hcloud_context.go reads the token of the ACTIVE `hcloud` CLI context — the
// third rung of the token-resolution ladder (--token flag > HCLOUD_TOKEN >
// hcloud context). Someone who already drives Hetzner through the official
// `hcloud` CLI has a token on disk at ~/.config/hcloud/cli.toml; making bp read
// it means `bp cloud hetzner …` works with ZERO new setup for them.
//
// The parser is a deliberate TOML *subset* (no new dependency): the hcloud CLI
// writes cli.toml itself and only ever emits `key = "value"` pairs, an
// `active_context` top-level key, and `[[contexts]]` array-of-table headers —
// exactly the shapes handled here. Anything unrecognised is skipped, never an
// error: a half-parsed config just means "no context token", and resolution
// falls through to the clear no-token error.
package hetzner

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// userConfigDirFunc / userHomeDirFunc are the platform seams this file reads
// the filesystem through. They exist so a test can SHAPE a macOS host — where
// os.UserConfigDir() answers ~/Library/Application Support — on any machine,
// instead of hiding the darwin-only case behind a runtime.GOOS skip that never
// runs in CI.
var (
	userConfigDirFunc = os.UserConfigDir
	userHomeDirFunc   = os.UserHomeDir
)

// hcloudConfigCandidates lists the cli.toml locations to try, in order, when
// HCLOUD_CONFIG is unset.
//
// TWO spellings, because Go and the hcloud CLI disagree on macOS.
// os.UserConfigDir() answers ~/Library/Application Support there, while the
// hcloud CLI writes ~/.config/hcloud/cli.toml on EVERY platform — so a bp that
// consulted only the Go spelling had this whole rung silently dead for every
// macOS user while it worked on Linux and in CI. On Linux the two spellings
// collapse to the same path (os.UserConfigDir honours XDG_CONFIG_HOME), so the
// list is de-duplicated and the behaviour there is unchanged.
func hcloudConfigCandidates() []string {
	var out []string
	add := func(dir string) {
		if dir == "" {
			return
		}
		p := filepath.Join(dir, "hcloud", "cli.toml")
		for _, seen := range out {
			if seen == p {
				return
			}
		}
		out = append(out, p)
	}
	if dir, err := userConfigDirFunc(); err == nil {
		add(dir)
	}
	xdg := strings.TrimSpace(os.Getenv("XDG_CONFIG_HOME"))
	if xdg == "" {
		if home, err := userHomeDirFunc(); err == nil && home != "" {
			xdg = filepath.Join(home, ".config")
		}
	}
	add(xdg)
	return out
}

// hcloudConfigPath returns the hcloud CLI config file location: the
// HCLOUD_CONFIG override when set (the same env var the hcloud CLI honours),
// else the FIRST READABLE candidate — <UserConfigDir>/hcloud/cli.toml, then
// $XDG_CONFIG_HOME (default ~/.config)/hcloud/cli.toml, which is where the
// hcloud CLI actually writes on macOS. When none is readable the first
// candidate is returned anyway, so the caller's error names a real path.
func hcloudConfigPath() string {
	if p := strings.TrimSpace(os.Getenv("HCLOUD_CONFIG")); p != "" {
		return p
	}
	candidates := hcloudConfigCandidates()
	for _, p := range candidates {
		f, err := os.Open(p)
		if err != nil {
			continue
		}
		_ = f.Close()
		return p
	}
	if len(candidates) > 0 {
		return candidates[0]
	}
	return ""
}

// TokenFromCLIContext returns the API token of the hcloud CLI's selected
// context: $HCLOUD_CONTEXT when set (the CLI's own override), else the file's
// active_context. A missing file, no active context, or an unknown context
// name is an error — callers treat any error as "this rung has no token" and
// keep descending the resolution ladder.
func TokenFromCLIContext() (string, error) {
	path := hcloudConfigPath()
	if path == "" {
		return "", fmt.Errorf("hetzner: cannot locate the hcloud CLI config")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("hetzner: read hcloud CLI config: %w", err)
	}
	active, contexts := parseHcloudConfig(string(data))
	want := strings.TrimSpace(os.Getenv("HCLOUD_CONTEXT"))
	if want == "" {
		want = active
	}
	if want == "" {
		return "", fmt.Errorf("hetzner: %s has no active_context", path)
	}
	for _, c := range contexts {
		if c.name == want && c.token != "" {
			return c.token, nil
		}
	}
	return "", fmt.Errorf("hetzner: hcloud context %q not found in %s", want, path)
}

// hcloudContext is one [[contexts]] entry of cli.toml.
type hcloudContext struct {
	name  string
	token string
}

// parseHcloudConfig extracts active_context and the [[contexts]] entries from
// the cli.toml text. Tolerant by design: unknown keys/sections are skipped.
func parseHcloudConfig(text string) (active string, contexts []hcloudContext) {
	// section tracks where key=value pairs land: "" is top-level, "contexts"
	// the current [[contexts]] entry, anything else an ignored section.
	section := ""
	for _, raw := range strings.Split(text, "\n") {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, "[") {
			if line == "[[contexts]]" {
				contexts = append(contexts, hcloudContext{})
				section = "contexts"
			} else {
				section = "other"
			}
			continue
		}
		eq := strings.IndexByte(line, '=')
		if eq < 0 {
			continue
		}
		key := strings.TrimSpace(line[:eq])
		val := tomlValue(line[eq+1:])
		switch section {
		case "":
			if key == "active_context" {
				active = val
			}
		case "contexts":
			cur := &contexts[len(contexts)-1]
			switch key {
			case "name":
				cur.name = val
			case "token":
				cur.token = val
			}
		}
	}
	return active, contexts
}

// tomlValue decodes the value side of a `key = value` line: a double-quoted
// basic string (the only form the hcloud CLI writes) is unquoted, ignoring any
// trailing comment; anything else is returned trimmed as-is.
func tomlValue(s string) string {
	s = strings.TrimSpace(s)
	if strings.HasPrefix(s, `"`) {
		if end := strings.IndexByte(s[1:], '"'); end >= 0 {
			if v, err := strconv.Unquote(s[:end+2]); err == nil {
				return v
			}
		}
		return strings.Trim(s, `"`)
	}
	if hash := strings.IndexByte(s, '#'); hash >= 0 {
		s = strings.TrimSpace(s[:hash])
	}
	return s
}
