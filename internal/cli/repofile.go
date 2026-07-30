package cli

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// repoFileName is the per-repo context file: dropped at a repo's root (or any
// ancestor of the working directory), it pins which server/scope every bp
// command in that tree targets — so `bp tasks` genuinely auto-connects "to the
// server this repo resolves to". Discovery walks UP from cwd to the filesystem
// root and the nearest file wins, exactly like .git discovery.
const repoFileName = ".barkpark.json"

// repoFile is the parsed .barkpark.json — the repo-scoped context layer that
// sits BETWEEN the BARKPARK_* env and the global active config in the
// precedence chain (flags > env > repo file > active config > defaults; see
// resolveContext). Recognized fields only; unknown keys are ignored silently so
// an older bp keeps working against a newer file (forward compat).
//
// "server" may be a saved-server NAME (resolved against known_servers exactly
// like `bp -s <name>` — see overlayActive) or a raw URL. There is deliberately
// NO token field: the file lives in the repo and gets committed, so
// parseRepoFile REJECTS one loudly instead of shipping a leaked secret.
type repoFile struct {
	Server    string `json:"server,omitempty"`
	Workspace string `json:"workspace,omitempty"`
	Project   string `json:"project,omitempty"`
	Dataset   string `json:"dataset,omitempty"`

	// Path is where the file was found (attribution for error/receipt text);
	// never serialized.
	Path string `json:"-"`
}

// findRepoFile walks up from dir to the filesystem root looking for
// repoFileName. The NEAREST file wins (first hit on the way up); ok=false when
// no ancestor carries one. A directory named .barkpark.json is ignored — only a
// regular file counts.
func findRepoFile(dir string) (string, bool) {
	dir = filepath.Clean(dir)
	for {
		path := filepath.Join(dir, repoFileName)
		if fi, err := os.Stat(path); err == nil && !fi.IsDir() {
			return path, true
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			// filepath.Dir of a root returns the root itself — the walk is done.
			return "", false
		}
		dir = parent
	}
}

// parseRepoFile reads and parses one repo context file. A "token" key — even an
// empty one — is REJECTED loudly: the file lives in the repo and gets
// committed, so a token in it is a leaked credential, never a convenience.
// Credentials come from saved servers or the env, and the error says so.
// Unknown keys are ignored silently (forward compat); malformed JSON errors
// naming the path. The same UTF-8 BOM strip LoadConfig applies (BP-ONB-12)
// keeps a Windows-edited file loadable.
func parseRepoFile(path string) (*repoFile, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read repo context %s: %w", path, err)
	}
	raw = bytes.TrimPrefix(raw, []byte{0xEF, 0xBB, 0xBF})

	var keys map[string]json.RawMessage
	if err := json.Unmarshal(raw, &keys); err != nil {
		return nil, fmt.Errorf("parse repo context %s: %w", path, err)
	}
	if _, has := keys["token"]; has {
		return nil, fmt.Errorf("%s carries a \"token\" field — tokens NEVER live in the repo file (it gets committed). Remove it; credentials come from saved servers (`bp setup`, `bp use <name>`) or BARKPARK_API_TOKEN", path)
	}

	var f repoFile
	if err := json.Unmarshal(raw, &f); err != nil {
		return nil, fmt.Errorf("parse repo context %s: %w", path, err)
	}
	f.Path = path
	return &f, nil
}

// loadRepoFile discovers and parses the repo context for the current working
// directory. (nil, nil) when no ancestor carries a file — a missing file is the
// common case, never an error — and (nil, nil) too when the cwd itself cannot
// be resolved (a deleted working directory must not brick every command). A
// PRESENT-but-invalid file returns its error; Execute gates on it loudly before
// any dispatch, and resolveContext's lenient re-read treats it as absent (the
// gate has already refused to run by then).
func loadRepoFile() (*repoFile, error) {
	cwd, err := os.Getwd()
	if err != nil {
		return nil, nil
	}
	path, ok := findRepoFile(cwd)
	if !ok {
		return nil, nil
	}
	return parseRepoFile(path)
}

// overlayActive folds the repo layer over the global active context, per field:
// a field the file sets wins over the config's active value; a field it leaves
// empty falls through. The result is handed to manifest.Resolve AS the active
// layer, which is exactly what puts the file between env and the global config
// in the precedence chain — flags and env still win field-by-field.
//
// The "server" value runs the SAME lookup `bp -s <value>` does (FindServer:
// name / DisplayName / normalized URL / alias / InstanceID). A hit adopts the
// entry's URL + token and carries its remembered scope — below the file's own
// explicit workspace/project/dataset, which are applied after and win. A miss
// is a raw URL used verbatim with NO token contributed by the file layer
// (matching -s: whatever token the lower layers supply still applies). Nil-safe
// on both receiver and cfg.
func (r *repoFile) overlayActive(cfg *Config, active manifest.ActiveContext) manifest.ActiveContext {
	if r == nil {
		return active
	}
	if r.Server != "" {
		if entry, ok := cfg.FindServer(r.Server); ok {
			active.Server = entry.Server
			if entry.Token != "" {
				active.Token = entry.Token
			}
			if entry.Workspace != "" {
				active.Workspace = entry.Workspace
			}
			if entry.Project != "" {
				active.Project = entry.Project
			}
			if entry.Dataset != "" {
				active.Dataset = entry.Dataset
			}
		} else {
			active.Server = r.Server
		}
	}
	if r.Workspace != "" {
		active.Workspace = r.Workspace
	}
	if r.Project != "" {
		active.Project = r.Project
	}
	if r.Dataset != "" {
		active.Dataset = r.Dataset
	}
	return active
}
