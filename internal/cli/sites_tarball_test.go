package cli

// sites_tarball_test.go covers the tarball ignore-set builder. loadGitignore
// reads `<root>/.gitignore` line by line; the scanner is hardened to a 1MB
// token cap and falls back to the safe defaults on any read/oversize error so a
// pathological .gitignore never silently drops entries the user meant to keep.

import (
	"io"
	"math/rand"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestTarballMaxBytesAbortsEarly proves the MaxBytes cap trips mid-file rather
// than after a single oversized file has fully streamed to the upload. The
// archive reader is drained to completion; we assert it errors AND that the
// bytes emitted before the error are far below the full file size — i.e. the
// LimitReader bound stopped the copy near the budget instead of at EOF.
func TestTarballMaxBytesAbortsEarly(t *testing.T) {
	dir := t.TempDir()

	const maxBytes = 64 * 1024
	const fileSize = 4 * 1024 * 1024 // 64x the cap

	// Incompressible payload so the emitted (gzip) byte count tracks the number
	// of file bytes actually copied — a repetitive file would gzip to nothing
	// and hide a runaway copy.
	buf := make([]byte, fileSize)
	if _, err := rand.New(rand.NewSource(1)).Read(buf); err != nil {
		t.Fatalf("fill payload: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "big.bin"), buf, 0o644); err != nil {
		t.Fatalf("write big.bin: %v", err)
	}

	// Non-nil empty Ignores keeps loadGitignore (and its defaults) out of the way.
	r, err := streamTarball(tarballOptions{Root: dir, Ignores: []string{}, MaxBytes: maxBytes})
	if err != nil {
		t.Fatalf("streamTarball: %v", err)
	}
	defer r.Close()

	emitted, err := io.Copy(io.Discard, r)
	if err == nil {
		t.Fatalf("expected size-exceeded error, got nil (emitted %d bytes)", emitted)
	}
	if !strings.Contains(err.Error(), "exceeds") {
		t.Fatalf("expected size-exceeded error, got: %v", err)
	}
	// The offending file overshoots the budget by at most one byte, so the
	// compressed stream should be near the cap — nowhere near the 4 MB file.
	// Allow generous slack for gzip/tar framing.
	const slack = 128 * 1024
	if emitted > maxBytes+slack {
		t.Fatalf("emitted %d bytes before abort — cap did not stop the copy early (max %d + slack %d)", emitted, maxBytes, slack)
	}
}

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
