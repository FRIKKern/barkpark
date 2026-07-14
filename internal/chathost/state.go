package chathost

import (
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
)

type State struct {
	ServerURL             string   `json:"server_url"`
	Credential            string   `json:"credential"`
	Host                  HostInfo `json:"host"`
	AllowInsecureLoopback bool     `json:"allow_insecure_loopback,omitempty"`
}

func SaveState(path string, state State) error {
	if state.Credential == "" {
		return fmt.Errorf("refusing to save empty credential")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	encoded, err := json.Marshal(state)
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, encoded, 0o600); err != nil {
		return err
	}
	if err := os.Chmod(tmp, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func LoadState(path string) (State, error) {
	var state State
	info, err := os.Stat(path)
	if err != nil {
		return state, err
	}
	if info.Mode().Perm()&0o077 != 0 {
		return state, fmt.Errorf("state file permissions must be 0600 or stricter")
	}
	encoded, err := os.ReadFile(path)
	if err != nil {
		return state, err
	}
	if err := json.Unmarshal(encoded, &state); err != nil {
		return state, err
	}
	if state.Credential == "" || state.ServerURL == "" {
		return state, fmt.Errorf("incomplete chat host state")
	}
	parsed, err := url.Parse(state.ServerURL)
	if err != nil {
		return state, fmt.Errorf("parse server URL: %w", err)
	}
	if err := validateServerURL(parsed, state.AllowInsecureLoopback); err != nil {
		return state, err
	}
	return state, nil
}
