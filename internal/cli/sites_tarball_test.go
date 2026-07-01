package cli

// sites_tarball_test.go covers the tarball ignore-set builder. loadGitignore
// reads `<root>/.gitignore` line by line; the scanner is hardened to a 1MB
// token cap and falls back to the safe defaults on any read/oversize error so a
// pathological .gitignore never silently drops entries the user meant to keep.

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoadGitignoreLongLine(t *testing.T) {
	cases := []struct {
		name    string
		content string
	}{
		{
			name:    "over-64KB line before a real entry",
			content: strings.Repeat("a", 70*1024) + "\nsecret/\n",
		},
		{
			name:    "over-64KB line after a real entry",
			content: "secret/\n" + strings.Repeat("a", 70*1024) + "\n",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			if err := os.WriteFile(filepath.Join(dir, ".gitignore"), []byte(tc.content), 0o644); err != nil {
				t.Fatalf("write .gitignore: %v", err)
			}
			var found bool
			for _, l := range loadGitignore(dir) {
				if l == "secret/" {
					found = true
					break
				}
			}
			if !found {
				t.Fatalf("loadGitignore dropped \"secret/\" — the long line truncated the scan")
			}
		})
	}
}
