package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// writeRepoFile drops a .barkpark.json with the given body into dir.
func writeRepoFile(t *testing.T, dir, body string) string {
	t.Helper()
	path := filepath.Join(dir, repoFileName)
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
	return path
}

// TestFindRepoFileWalkUp pins the discovery contract: the walk starts at the
// given dir, checks every ancestor, and stops at the filesystem root without
// looping. The nearest file wins.
func TestFindRepoFileWalkUp(t *testing.T) {
	root := t.TempDir()
	sub := filepath.Join(root, "a", "b", "c")
	if err := os.MkdirAll(sub, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	// Not found anywhere up the tree (the walk still terminates at the root).
	if path, ok := findRepoFile(sub); ok {
		t.Fatalf("no file written yet, but found %q", path)
	}

	// Found in an ancestor: file at root, cwd three levels down.
	want := writeRepoFile(t, root, `{"server":"http://localhost:4000"}`)
	got, ok := findRepoFile(sub)
	if !ok || got != want {
		t.Fatalf("walk-up should find the root file: got %q ok=%v, want %q", got, ok, want)
	}

	// The NEAREST file wins when both an ancestor and the cwd carry one.
	nearer := writeRepoFile(t, sub, `{"server":"http://localhost:4001"}`)
	got, ok = findRepoFile(sub)
	if !ok || got != nearer {
		t.Fatalf("nearest file should win: got %q ok=%v, want %q", got, ok, nearer)
	}

	// Found in the start dir itself.
	got, ok = findRepoFile(root)
	if !ok || got != want {
		t.Fatalf("start-dir file should be found: got %q ok=%v, want %q", got, ok, want)
	}
}

// TestParseRepoFileRejectsToken is the credential-hygiene gate: a "token" key in
// the repo file must be rejected LOUDLY — the file gets committed, so a token in
// it is a leaked secret, never a convenience. The error must say where tokens do
// live so the fix is obvious.
func TestParseRepoFileRejectsToken(t *testing.T) {
	cases := []struct {
		name string
		body string
	}{
		{"token alone", `{"token":"sekrit"}`},
		{"token beside valid fields", `{"server":"prod","dataset":"staging","token":"sekrit"}`},
		{"empty token still rejected", `{"token":""}`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			path := writeRepoFile(t, t.TempDir(), tc.body)
			_, err := parseRepoFile(path)
			if err == nil {
				t.Fatalf("a token field in %s must be rejected", repoFileName)
			}
			msg := strings.ToLower(err.Error())
			if !strings.Contains(msg, "token") || !strings.Contains(msg, "never") {
				t.Fatalf("rejection should explain that tokens never live in the repo file, got: %v", err)
			}
		})
	}
}

// TestParseRepoFileFields pins the recognized fields, forward-compat (unknown
// keys are ignored silently) and malformed-JSON handling.
func TestParseRepoFileFields(t *testing.T) {
	dir := t.TempDir()
	path := writeRepoFile(t, dir,
		`{"server":"prod","workspace":"w1","project":"p1","dataset":"d1","future_knob":true,"nested":{"x":1}}`)
	f, err := parseRepoFile(path)
	if err != nil {
		t.Fatalf("unknown fields must be ignored (forward compat), got: %v", err)
	}
	if f.Server != "prod" || f.Workspace != "w1" || f.Project != "p1" || f.Dataset != "d1" {
		t.Fatalf("recognized fields wrong: %+v", *f)
	}
	if f.Path != path {
		t.Fatalf("Path should record where the file was found: %q", f.Path)
	}

	// Malformed JSON errors with the path so the user knows which file to fix.
	bad := writeRepoFile(t, t.TempDir(), `{"server":`)
	if _, err := parseRepoFile(bad); err == nil || !strings.Contains(err.Error(), bad) {
		t.Fatalf("malformed repo file should error naming the path, got: %v", err)
	}
}

// TestResolveContextRepoFilePrecedence is the precedence matrix: per field,
// strictly flag > env > .barkpark.json > global active config > baked defaults —
// each field independently (a file server and an env workspace coexist).
func TestResolveContextRepoFilePrecedence(t *testing.T) {
	cases := []struct {
		name          string
		flagServer    string
		flagWorkspace string
		envServer     string
		envWorkspace  string
		file          string // "" = no .barkpark.json
		global        *Config
		wantServer    string
		wantWorkspace string
		wantDataset   string
	}{
		{
			name:          "no file → global active wins over defaults",
			global:        &Config{Server: "http://global:4000", Workspace: "w-global", Dataset: "d-global"},
			wantServer:    "http://global:4000",
			wantWorkspace: "w-global",
			wantDataset:   "d-global",
		},
		{
			name:          "file server beats global active",
			file:          `{"server":"http://repo:4000"}`,
			global:        &Config{Server: "http://global:4000", Workspace: "w-global"},
			wantServer:    "http://repo:4000",
			wantWorkspace: "w-global",
			wantDataset:   "production", // baked default — file/global silent
		},
		{
			name:          "env server beats file server",
			envServer:     "http://env:4000",
			file:          `{"server":"http://repo:4000"}`,
			global:        &Config{Server: "http://global:4000"},
			wantServer:    "http://env:4000",
			wantWorkspace: "default",
			wantDataset:   "production",
		},
		{
			name:          "flag server beats env and file",
			flagServer:    "http://flag:4000",
			envServer:     "http://env:4000",
			file:          `{"server":"http://repo:4000"}`,
			global:        &Config{Server: "http://global:4000"},
			wantServer:    "http://flag:4000",
			wantWorkspace: "default",
			wantDataset:   "production",
		},
		{
			name:          "file workspace beats global active",
			file:          `{"workspace":"w-repo"}`,
			global:        &Config{Server: "http://global:4000", Workspace: "w-global"},
			wantServer:    "http://global:4000",
			wantWorkspace: "w-repo",
			wantDataset:   "production",
		},
		{
			name:          "env workspace beats file workspace",
			envWorkspace:  "w-env",
			file:          `{"workspace":"w-repo"}`,
			global:        &Config{Workspace: "w-global"},
			wantServer:    "http://localhost:4000", // baked default
			wantWorkspace: "w-env",
			wantDataset:   "production",
		},
		{
			name:          "flag workspace beats env, file and global",
			flagWorkspace: "w-flag",
			envWorkspace:  "w-env",
			file:          `{"workspace":"w-repo"}`,
			global:        &Config{Workspace: "w-global"},
			wantServer:    "http://localhost:4000",
			wantWorkspace: "w-flag",
			wantDataset:   "production",
		},
		{
			name:          "fields resolve independently: file server+dataset, env workspace",
			envWorkspace:  "w-env",
			file:          `{"server":"http://repo:4000","dataset":"d-repo"}`,
			global:        &Config{Server: "http://global:4000", Workspace: "w-global", Dataset: "d-global"},
			wantServer:    "http://repo:4000",
			wantWorkspace: "w-env",
			wantDataset:   "d-repo",
		},
		{
			name:          "file field left empty falls through to global",
			file:          `{"dataset":"d-repo"}`,
			global:        &Config{Server: "http://global:4000", Workspace: "w-global", Dataset: "d-global"},
			wantServer:    "http://global:4000",
			wantWorkspace: "w-global",
			wantDataset:   "d-repo",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			withTempConfigHome(t)
			clearBarkparkEnv(t)
			if tc.global != nil {
				if err := SaveConfig(tc.global); err != nil {
					t.Fatalf("SaveConfig: %v", err)
				}
			}
			if tc.envServer != "" {
				t.Setenv("BARKPARK_SERVER", tc.envServer)
			}
			if tc.envWorkspace != "" {
				t.Setenv("BARKPARK_WORKSPACE", tc.envWorkspace)
			}
			dir := t.TempDir()
			if tc.file != "" {
				writeRepoFile(t, dir, tc.file)
			}
			t.Chdir(dir)

			ctx := resolveContext(globals{server: tc.flagServer, workspace: tc.flagWorkspace})
			if ctx.Server != tc.wantServer {
				t.Errorf("Server = %q, want %q", ctx.Server, tc.wantServer)
			}
			if ctx.Workspace != tc.wantWorkspace {
				t.Errorf("Workspace = %q, want %q", ctx.Workspace, tc.wantWorkspace)
			}
			if ctx.Dataset != tc.wantDataset {
				t.Errorf("Dataset = %q, want %q", ctx.Dataset, tc.wantDataset)
			}
		})
	}
}

// TestRepoFileServerNameResolution pins how the file's "server" value resolves
// against known_servers — the same lookup `bp -s <value>` runs (FindServer):
// a saved name adopts the entry's URL + token + remembered scope; a URL that
// matches a known entry adopts its token; an unknown URL is used verbatim with
// no token contributed by the file layer.
func TestRepoFileServerNameResolution(t *testing.T) {
	global := &Config{
		Server: "http://localhost:4000",
		Token:  "tok-global",
		KnownServers: []ServerEntry{
			{Name: "prod", Server: "https://api.prod.example", Token: "tok-prod", Workspace: "w-prod", Dataset: "staging"},
		},
	}
	cases := []struct {
		name          string
		file          string
		wantServer    string
		wantToken     string
		wantWorkspace string
		wantDataset   string
	}{
		{
			name:          "saved name resolves like -s: URL + token + remembered scope",
			file:          `{"server":"prod"}`,
			wantServer:    "https://api.prod.example",
			wantToken:     "tok-prod",
			wantWorkspace: "w-prod",
			wantDataset:   "staging",
		},
		{
			name:          "file's own scope beats the entry's remembered scope",
			file:          `{"server":"prod","workspace":"w-repo","dataset":"d-repo"}`,
			wantServer:    "https://api.prod.example",
			wantToken:     "tok-prod",
			wantWorkspace: "w-repo",
			wantDataset:   "d-repo",
		},
		{
			name:          "URL matching a known entry adopts its token (normalized match)",
			file:          `{"server":"https://API.prod.example/"}`,
			wantServer:    "https://api.prod.example",
			wantToken:     "tok-prod",
			wantWorkspace: "w-prod",
			wantDataset:   "staging",
		},
		{
			name:          "unknown URL is used verbatim, tokenless from the file layer",
			file:          `{"server":"https://nowhere.example"}`,
			wantServer:    "https://nowhere.example",
			wantToken:     "tok-global", // same as -s today: lower layers still supply the token
			wantWorkspace: "default",
			wantDataset:   "production",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			withTempConfigHome(t)
			clearBarkparkEnv(t)
			if err := SaveConfig(global); err != nil {
				t.Fatalf("SaveConfig: %v", err)
			}
			dir := t.TempDir()
			writeRepoFile(t, dir, tc.file)
			t.Chdir(dir)

			ctx := resolveContext(globals{})
			if ctx.Server != tc.wantServer {
				t.Errorf("Server = %q, want %q", ctx.Server, tc.wantServer)
			}
			if ctx.Token != tc.wantToken {
				t.Errorf("Token = %q, want %q", ctx.Token, tc.wantToken)
			}
			if ctx.Workspace != tc.wantWorkspace {
				t.Errorf("Workspace = %q, want %q", ctx.Workspace, tc.wantWorkspace)
			}
			if ctx.Dataset != tc.wantDataset {
				t.Errorf("Dataset = %q, want %q", ctx.Dataset, tc.wantDataset)
			}
		})
	}
}

// TestExecuteRejectsRepoFileToken proves the loud gate: any command run inside a
// repo whose .barkpark.json carries a token fails up front with a usage error —
// never a silent ignore, never a request sent. `bp version` stays reachable (it
// returns before context resolution, so a poisoned file can't brick it).
func TestExecuteRejectsRepoFileToken(t *testing.T) {
	withTempConfigHome(t)
	clearBarkparkEnv(t)
	dir := t.TempDir()
	writeRepoFile(t, dir, `{"server":"http://localhost:4000","token":"sekrit"}`)
	t.Chdir(dir)

	if code := Execute([]string{"whoami"}); code != exitUsage {
		t.Fatalf("Execute with a token-carrying repo file = %d, want %d (usage error)", code, exitUsage)
	}
	if code := Execute([]string{"--version"}); code != exitOK {
		t.Fatalf("bp --version must still work with a poisoned repo file, got %d", code)
	}
}
