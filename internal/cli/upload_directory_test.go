package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Stranger walk (2026-09-30): `bp media upload <dir>` opened the directory
// fine, then failed INSIDE the streaming goroutine once the request was in
// flight — "request failed: Post …: multipart write: read <dir>: is a
// directory", code request_failed, exit 1. A directory is refused up front,
// with the same "read upload file" usage wording a missing path gets.
func TestBuildMultipartFileRefusesADirectoryBeforeAnyRequest(t *testing.T) {
	dir := t.TempDir()

	body, ctype, err := buildMultipartFile(dir)
	if err == nil {
		t.Fatalf("a directory must be refused before the request; got body=%v ctype=%q", body, ctype)
	}
	if body != nil || ctype != "" {
		t.Fatalf("a refused upload must return no body; got body=%v ctype=%q", body, ctype)
	}
	if !strings.Contains(err.Error(), "read upload file") || !strings.Contains(err.Error(), "is a directory") {
		t.Fatalf("err = %q, want the read-upload-file wording naming the directory", err)
	}

	t.Run("a regular file still streams", func(t *testing.T) {
		p := filepath.Join(dir, "a.txt")
		if err := os.WriteFile(p, []byte("hello"), 0o600); err != nil {
			t.Fatal(err)
		}
		body, ctype, err := buildMultipartFile(p)
		if err != nil || body == nil || !strings.HasPrefix(ctype, "multipart/form-data") {
			t.Fatalf("regular file: body=%v ctype=%q err=%v", body, ctype, err)
		}
	})
}
