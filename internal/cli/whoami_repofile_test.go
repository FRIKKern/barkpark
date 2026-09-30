package cli

import (
	"path/filepath"
	"strings"
	"testing"
)

// TestWhoamiNamesTheRepoFile pins task-133b0da17e428eb1: a .barkpark.json that
// pins the server outranks the saved active config, and `bp whoami` must say so
// — naming the file — instead of labelling the server "default" (which tells
// the reader to run `bp setup`) or "saved" (which blames the global config).
// The repro is the one that filed the row: `bp use dnd`, then cd into a repo
// whose file pins guerrilla.
func TestWhoamiNamesTheRepoFile(t *testing.T) {
	cfg := &Config{
		Server: "https://dnd.example",
		Token:  "tok-dnd",
		KnownServers: []ServerEntry{
			{Name: "dnd", Server: "https://dnd.example", Token: "tok-dnd"},
			{Name: "guerrilla", Server: "https://guerrilla.example", Token: "tok-g"},
		},
	}
	cases := []struct {
		name       string
		file       string // "" = no repo file
		g          globals
		wantSource string
		wantPath   bool
	}{
		{name: "repo file names a saved server by URL", file: `{"server":"https://guerrilla.example"}`, wantSource: "repo-file", wantPath: true},
		{name: "repo file names a saved server by name", file: `{"server":"guerrilla"}`, wantSource: "repo-file", wantPath: true},
		{name: "repo file names an unknown raw URL", file: `{"server":"https://nowhere.example"}`, wantSource: "repo-file", wantPath: true},
		{name: "repo file carries scope only: the saved server still chose", file: `{"dataset":"staging"}`, wantSource: "saved"},
		{name: "no repo file: the saved server chose", file: "", wantSource: "saved"},
		{name: "-s beats the repo file", file: `{"server":"guerrilla"}`, g: globals{server: "dnd"}, wantSource: "flag"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			withTempConfigHome(t)
			clearBarkparkEnv(t)
			if err := SaveConfig(cfg); err != nil {
				t.Fatalf("SaveConfig: %v", err)
			}
			dir := t.TempDir()
			var want string
			if tc.file != "" {
				want = writeRepoFile(t, dir, tc.file)
			}
			t.Chdir(dir)

			ctx := resolveContext(tc.g)
			src, _, _ := whoamiSourceName(tc.g, ctx)
			if src != tc.wantSource {
				t.Fatalf("whoamiSourceName = %q, want %q (server %s)", src, tc.wantSource, ctx.Server)
			}
			loaded, _ := LoadConfig()
			path, ok := whoamiRepoFileServer(loaded, ctx)
			if ok != tc.wantPath {
				t.Fatalf("whoamiRepoFileServer ok = %v, want %v", ok, tc.wantPath)
			}
			if tc.wantPath {
				// Compare resolved paths: t.TempDir may sit behind a symlink (/var → /private/var).
				gotR, _ := filepath.EvalSymlinks(path)
				wantR, _ := filepath.EvalSymlinks(want)
				if gotR != wantR {
					t.Errorf("source path = %q, want %q", path, want)
				}
				if label := whoamiSourceLabel(src, false, path); !strings.Contains(label, repoFileName) || strings.Contains(label, "bp setup") {
					t.Errorf("label %q must name the repo file and must not send the reader to `bp setup`", label)
				}
			}
		})
	}
}
