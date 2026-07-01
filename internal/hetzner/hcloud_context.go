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

// hcloudConfigPath returns the hcloud CLI config file location: the
// HCLOUD_CONFIG override when set (the same env var the hcloud CLI honours),
// else <UserConfigDir>/hcloud/cli.toml (the CLI's own default).
func hcloudConfigPath() string {
	if p := strings.TrimSpace(os.Getenv("HCLOUD_CONFIG")); p != "" {
		return p
	}
	dir, err := os.UserConfigDir()
	if err != nil {
		return ""
	}
	return filepath.Join(dir, "hcloud", "cli.toml")
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
