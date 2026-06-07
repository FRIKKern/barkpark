package cli

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

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
type Config struct {
	Server      string `json:"server,omitempty"`
	Token       string `json:"token,omitempty"`
	AdminToken  string `json:"admin_token,omitempty"`
	IngestToken string `json:"ingest_token,omitempty"`
	Workspace   string `json:"workspace,omitempty"`
	Project     string `json:"project,omitempty"`
	Dataset     string `json:"dataset,omitempty"`
	Output      string `json:"output,omitempty"`
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
