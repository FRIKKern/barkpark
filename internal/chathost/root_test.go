package chathost

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestResolveApprovedPathAllowsRealChild(t *testing.T) {
	root := t.TempDir()
	child := filepath.Join(root, "repo")
	if err := os.Mkdir(child, 0o700); err != nil {
		t.Fatal(err)
	}

	got, err := ResolveApprovedPath([]string{root}, child)
	if err != nil {
		t.Fatal(err)
	}
	want, err := filepath.EvalSymlinks(child)
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}

func TestResolveApprovedPathRejectsSiblingPrefix(t *testing.T) {
	parent := t.TempDir()
	root := filepath.Join(parent, "repo")
	sibling := filepath.Join(parent, "repo-secret")
	for _, path := range []string{root, sibling} {
		if err := os.Mkdir(path, 0o700); err != nil {
			t.Fatal(err)
		}
	}

	_, err := ResolveApprovedPath([]string{root}, sibling)
	if !errors.Is(err, ErrRootDenied) {
		t.Fatalf("got %v want ErrRootDenied", err)
	}
}

func TestResolveApprovedPathRejectsSymlinkEscape(t *testing.T) {
	parent := t.TempDir()
	root := filepath.Join(parent, "approved")
	outside := filepath.Join(parent, "outside")
	if err := os.Mkdir(root, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(outside, 0o700); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(root, "escape")
	if err := os.Symlink(outside, link); err != nil {
		t.Fatal(err)
	}

	_, err := ResolveApprovedPath([]string{root}, link)
	if !errors.Is(err, ErrRootDenied) {
		t.Fatalf("got %v want ErrRootDenied", err)
	}
}
