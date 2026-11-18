package hostguard

// task-9ef60a4a9bac92fe: a cut whose budget falls between the two regional
// indicators of a flag ends on a grapheme boundary, never on a lone 🇳.

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestScanHitTextCutsOnAGraphemeBoundary(t *testing.T) {
	head := "see evil.example " + strings.Repeat("a", 139) // 156 bytes, then the flag
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "f.txt"), []byte(head+"🇳🇴 tail\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	hits, err := Scan(dir, []string{"evil.example"})
	if err != nil || len(hits) != 1 {
		t.Fatalf("Scan = %v, %v; want one hit", hits, err)
	}
	if hits[0].Text != head+"…" {
		t.Errorf("hit text ends %q, want the text before the flag and an ellipsis", hits[0].Text[150:])
	}
}
