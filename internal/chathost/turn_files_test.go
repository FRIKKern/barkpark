package chathost

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"
)

const testSessionID = "6f1c2a3b-4d5e-4f60-8a1b-2c3d4e5f6a7b"

// fileRef is the leased reference of a file whose bytes are data.
func fileRef(data []byte, mediaType, name string) AttachmentRef {
	ref := refFor(data, mediaType)
	ref.Name = name
	return ref
}

// turnFileWorld is an approved root holding a project folder (the turn's
// cwd), and a folder outside every approved root that a planted link points
// at. Nothing may ever be written into outside.
func turnFileWorld(t *testing.T) (roots []string, cwd, outside string) {
	t.Helper()
	root := t.TempDir()
	cwd = filepath.Join(root, "project")
	if err := os.Mkdir(cwd, 0o755); err != nil {
		t.Fatal(err)
	}
	return []string{root}, cwd, t.TempDir()
}

func wantTurnFileRefused(t *testing.T, err error, fragment string) {
	t.Helper()
	var refused *TurnFileError
	if !errors.As(err, &refused) {
		t.Fatalf("got %v, want a *TurnFileError", err)
	}
	if !strings.Contains(err.Error(), fragment) {
		t.Fatalf("error %q does not name %q", err, fragment)
	}
}

// listTree names every entry under dir, relative to it, links included.
func listTree(t *testing.T, dir string) []string {
	t.Helper()
	var names []string
	err := filepath.WalkDir(dir, func(path string, _ os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if path != dir {
			rel, _ := filepath.Rel(dir, path)
			names = append(names, rel)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	sort.Strings(names)
	return names
}

func sessionFolder(cwd string) string {
	return filepath.Join(cwd, ".barkpark", "attachments", testSessionID)
}

// The criterion: a planted link anywhere on the folder path refuses the
// write, and nothing lands outside the root, nor anywhere inside it.
func TestWriteTurnFileRefusesALinkedAttachmentsFolder(t *testing.T) {
	data := []byte("name,size\nnotes,12\n")
	ref := fileRef(data, "text/plain", "notes.csv")
	plant := map[string]func(t *testing.T, cwd, outside string){
		".barkpark is a link out of the root": func(t *testing.T, cwd, outside string) {
			mustSymlink(t, outside, filepath.Join(cwd, ".barkpark"))
		},
		".barkpark is a link inside the root": func(t *testing.T, cwd, _ string) {
			mustMkdir(t, filepath.Join(cwd, "elsewhere"))
			mustSymlink(t, filepath.Join(cwd, "elsewhere"), filepath.Join(cwd, ".barkpark"))
		},
		"attachments is a link out of the root": func(t *testing.T, cwd, outside string) {
			mustMkdir(t, filepath.Join(cwd, ".barkpark"))
			mustSymlink(t, outside, filepath.Join(cwd, ".barkpark", "attachments"))
		},
		"attachments is a relative link up and out": func(t *testing.T, cwd, _ string) {
			mustMkdir(t, filepath.Join(cwd, ".barkpark"))
			mustSymlink(t, "../..", filepath.Join(cwd, ".barkpark", "attachments"))
		},
		"the session folder is a link out of the root": func(t *testing.T, cwd, outside string) {
			mustMkdir(t, filepath.Join(cwd, ".barkpark", "attachments"))
			mustSymlink(t, outside, sessionFolder(cwd))
		},
		"the session folder is a dangling link": func(t *testing.T, cwd, outside string) {
			mustMkdir(t, filepath.Join(cwd, ".barkpark", "attachments"))
			mustSymlink(t, filepath.Join(outside, "not-yet"), sessionFolder(cwd))
		},
	}
	for name, setup := range plant {
		t.Run(name, func(t *testing.T) {
			roots, cwd, outside := turnFileWorld(t)
			setup(t, cwd, outside)
			before := listTree(t, cwd)

			got, err := WriteTurnFile(roots, cwd, testSessionID, ref, data)
			wantTurnFileRefused(t, err, "link")
			if got.Path != "" {
				t.Fatalf("a refused write returned path %q", got.Path)
			}
			if entries := listTree(t, outside); len(entries) != 0 {
				t.Fatalf("wrote outside the root: %v", entries)
			}
			if after := listTree(t, cwd); strings.Join(after, "|") != strings.Join(before, "|") {
				t.Fatalf("the refused write changed the project: before %v, after %v", before, after)
			}
		})
	}
}

func TestWriteTurnFileRefusesAFolderThatIsAFile(t *testing.T) {
	data := []byte("plain text")
	ref := fileRef(data, "text/plain", "a.txt")
	for _, rel := range []string{".barkpark", ".barkpark/attachments", ".barkpark/attachments/" + testSessionID} {
		roots, cwd, _ := turnFileWorld(t)
		mustMkdir(t, filepath.Dir(filepath.Join(cwd, rel)))
		if err := os.WriteFile(filepath.Join(cwd, rel), []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
		_, err := WriteTurnFile(roots, cwd, testSessionID, ref, data)
		wantTurnFileRefused(t, err, "not a folder")
	}
}

// The criterion: the path holds only the session id, the sha256 and an
// extension from a fixed set; the name never touches the file system.
func TestWriteTurnFilePathNeverHoldsTheName(t *testing.T) {
	data := []byte("#!/bin/sh\necho hi\n")
	cases := map[string]string{
		"../../x.sh":            "sh",
		"notes.CSV":             "csv",
		"README":                "txt",
		"trailing.":             "txt",
		"a.tar.gz":              "gz",
		"long.abcdefghijk":      "txt",
		"kelvin.\u212A":         "txt", // KELVIN SIGN lowercases to an ASCII k
		"space.s h":             "txt",
		"looks-like.pdf":        "txt", // text bytes are never written under a binary type's extension
		"looks-like.PNG":        "txt",
		".bashrc":               "bashrc",
		"x.sh\u202Egpj.exe":     "exe",
		"C:\\Windows\\evil.bat": "bat",
	}
	for name, ext := range cases {
		roots, cwd, outside := turnFileWorld(t)
		ref := fileRef(data, "text/plain", name)
		got, err := WriteTurnFile(roots, cwd, testSessionID, ref, data)
		if err != nil {
			t.Fatalf("%q: %v", name, err)
		}
		real, _ := filepath.EvalSymlinks(cwd)
		want := filepath.Join(real, ".barkpark", "attachments", testSessionID, ref.ID+"."+ext)
		if got.Path != want {
			t.Fatalf("%q: path %q, want %q", name, got.Path, want)
		}
		if got.Name != name || got.MediaType != "text/plain" || got.ByteSize != len(data) {
			t.Fatalf("%q: got %+v", name, got)
		}
		if tree := listTree(t, cwd); strings.Join(tree, "|") != strings.Join([]string{
			".barkpark", ".barkpark/attachments", ".barkpark/attachments/.gitignore",
			".barkpark/attachments/" + testSessionID, ".barkpark/attachments/" + testSessionID + "/" + ref.ID + "." + ext,
		}, "|") {
			t.Fatalf("%q: tree %v", name, tree)
		}
		if entries := listTree(t, outside); len(entries) != 0 {
			t.Fatalf("%q: wrote outside the root: %v", name, entries)
		}
	}

	pdf := []byte("%PDF-1.7\n%\xe2\xe3\xcf\xd3\n")
	roots, cwd, _ := turnFileWorld(t)
	ref := fileRef(pdf, "application/pdf", "report.txt")
	got, err := WriteTurnFile(roots, cwd, testSessionID, ref, pdf)
	if err != nil || !strings.HasSuffix(got.Path, "/"+ref.ID+".pdf") {
		t.Fatalf("pdf: path %q err=%v; want {sha}.pdf whatever the name says", got.Path, err)
	}
}

func TestWriteTurnFileRefusesASessionIDThatIsNotAUUID(t *testing.T) {
	data := []byte("text")
	ref := fileRef(data, "text/plain", "a.txt")
	for _, sessionID := range []string{
		"", "session-images", "..", "../" + testSessionID, testSessionID + "/x",
		strings.ToUpper(testSessionID), "6f1c2a3b4d5e4f608a1b2c3d4e5f6a7b", testSessionID + "0",
		"6f1c2a3b-4d5e-4f60-8a1b-2c3d4e5f6a7g",
	} {
		roots, cwd, _ := turnFileWorld(t)
		_, err := WriteTurnFile(roots, cwd, sessionID, ref, data)
		wantTurnFileRefused(t, err, "session id")
		if tree := listTree(t, cwd); len(tree) != 0 {
			t.Fatalf("%q: wrote %v", sessionID, tree)
		}
	}
}

// Bytes that are not the leased file are refused before anything is created.
func TestWriteTurnFileRefusesBytesThatAreNotTheReference(t *testing.T) {
	data := []byte("the file the person sent")
	ref := fileRef(data, "text/plain", "a.txt")
	big := bytes.Repeat([]byte("a"), MaxAttachmentBytes+1)
	bigRef := fileRef(big, "text/plain", "big.txt")
	bigRef.ByteSize = len(big)
	cases := map[string]struct {
		ref      AttachmentRef
		data     []byte
		fragment string
	}{
		"other bytes, same length": {ref, []byte("THE FILE THE PERSON SENT"), "sha256"},
		"shorter":                  {ref, data[:5], "bytes"},
		"empty":                    {fileRef(nil, "text/plain", "a.txt"), nil, "bytes"},
		"over the store cap":       {bigRef, big, "bytes"},
		"not utf-8":                {fileRef([]byte{0xff, 0xfe, 'a'}, "text/plain", "a.txt"), []byte{0xff, 0xfe, 'a'}, "not text/plain"},
		"a NUL byte":               {fileRef([]byte("a\x00b"), "text/plain", "a.txt"), []byte("a\x00b"), "not text/plain"},
		"a pdf without %PDF-":      {fileRef([]byte("PDF-1.7"), "application/pdf", "a.pdf"), []byte("PDF-1.7"), "not application/pdf"},
		"an image":                 {fileRef(pngBytes("x"), "image/png", ""), pngBytes("x"), "not a file type"},
		"an uppercase id":          {AttachmentRef{ID: strings.ToUpper(ref.ID), MediaType: "text/plain", ByteSize: len(data), Name: "a.txt"}, data, "id"},
	}
	for name, c := range cases {
		roots, cwd, _ := turnFileWorld(t)
		_, err := WriteTurnFile(roots, cwd, testSessionID, c.ref, c.data)
		wantTurnFileRefused(t, err, c.fragment)
		if tree := listTree(t, cwd); len(tree) != 0 {
			t.Fatalf("%s: wrote %v", name, tree)
		}
	}
}

func TestWriteTurnFileRefusesACwdOutsideTheApprovedRoots(t *testing.T) {
	data := []byte("text")
	_, _, outside := turnFileWorld(t)
	_, err := WriteTurnFile([]string{t.TempDir()}, outside, testSessionID, fileRef(data, "text/plain", "a.txt"), data)
	if !errors.Is(err, ErrRootDenied) {
		t.Fatalf("got %v, want ErrRootDenied", err)
	}
	if tree := listTree(t, outside); len(tree) != 0 {
		t.Fatalf("wrote %v outside the approved roots", tree)
	}
}

// The criterion: a stale file of the same name with other bytes is replaced
// whole, and no temp file is left beside it.
func TestWriteTurnFileReplacesAFileWhoseBytesDiffer(t *testing.T) {
	roots, cwd, outside := turnFileWorld(t)
	data := []byte("the right bytes\n")
	ref := fileRef(data, "text/plain", "notes.md")
	first, err := WriteTurnFile(roots, cwd, testSessionID, ref, data)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(first.Path, []byte("stale, other bytes"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(first.Path, 0o644); err != nil {
		t.Fatal(err)
	}
	again, err := WriteTurnFile(roots, cwd, testSessionID, ref, data)
	if err != nil || again.Path != first.Path {
		t.Fatalf("second write: %+v err=%v", again, err)
	}
	wantFile(t, again.Path, data, 0o600)

	// A link planted at the final name is replaced, never written through.
	target := filepath.Join(outside, "victim")
	if err := os.WriteFile(target, []byte("keep me"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(first.Path); err != nil {
		t.Fatal(err)
	}
	mustSymlink(t, target, first.Path)
	if _, err := WriteTurnFile(roots, cwd, testSessionID, ref, data); err != nil {
		t.Fatal(err)
	}
	wantFile(t, first.Path, data, 0o600)
	wantFile(t, target, []byte("keep me"), 0o600)

	entries, err := os.ReadDir(sessionFolder(cwd))
	if err != nil || len(entries) != 1 || entries[0].Name() != ref.ID+".md" {
		t.Fatalf("session folder holds %v (err=%v); want only the file", entries, err)
	}
}

// A folder squatting on the final name fails the write and leaves no temp.
func TestWriteTurnFileLeavesNoTempWhenTheRenameFails(t *testing.T) {
	roots, cwd, _ := turnFileWorld(t)
	data := []byte("text")
	ref := fileRef(data, "text/plain", "a.txt")
	squat := filepath.Join(sessionFolder(cwd), ref.ID+".txt")
	mustMkdir(t, filepath.Join(squat, "inner"))
	if _, err := WriteTurnFile(roots, cwd, testSessionID, ref, data); err == nil {
		t.Fatal("wrote over a folder")
	}
	entries, _ := os.ReadDir(sessionFolder(cwd))
	if len(entries) != 1 || entries[0].Name() != ref.ID+".txt" || !entries[0].IsDir() {
		t.Fatalf("session folder holds %v; want only the squatting folder", entries)
	}
}

// The criterion: the attachments folder carries a .gitignore of "*", and the
// folders and file are the person's alone.
func TestWriteTurnFileLeavesAGitignore(t *testing.T) {
	roots, cwd, _ := turnFileWorld(t)
	data := []byte("%PDF-1.4 tiny")
	got, err := WriteTurnFile(roots, cwd, testSessionID, fileRef(data, "application/pdf", "a.pdf"), data)
	if err != nil {
		t.Fatal(err)
	}
	gitignore := filepath.Join(cwd, ".barkpark", "attachments", ".gitignore")
	wantFile(t, gitignore, []byte("*\n"), 0o600)
	wantFile(t, got.Path, data, 0o600)
	for _, dir := range []string{filepath.Join(cwd, ".barkpark"), filepath.Join(cwd, ".barkpark", "attachments"), sessionFolder(cwd)} {
		info, err := os.Lstat(dir)
		if err != nil || info.Mode().Perm() != 0o700 || !info.IsDir() {
			t.Fatalf("%s: mode %v err=%v; want a 0700 folder", dir, info.Mode(), err)
		}
	}

	// A .gitignore the person changed stays theirs.
	if err := os.WriteFile(gitignore, []byte("*\n!keep.txt\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := WriteTurnFile(roots, cwd, testSessionID, fileRef(data, "application/pdf", "a.pdf"), data); err != nil {
		t.Fatal(err)
	}
	if body, _ := os.ReadFile(gitignore); string(body) != "*\n!keep.txt\n" {
		t.Fatalf(".gitignore rewritten to %q", body)
	}

	// A linked .gitignore refuses the write.
	_, cwd2, outside := turnFileWorld(t)
	mustMkdir(t, filepath.Join(cwd2, ".barkpark", "attachments"))
	mustSymlink(t, filepath.Join(outside, "gi"), filepath.Join(cwd2, ".barkpark", "attachments", ".gitignore"))
	_, err = WriteTurnFile([]string{filepath.Dir(cwd2)}, cwd2, testSessionID, fileRef(data, "application/pdf", "a.pdf"), data)
	wantTurnFileRefused(t, err, "link")
	if tree := listTree(t, outside); len(tree) != 0 {
		t.Fatalf("wrote %v through the linked .gitignore", tree)
	}
}

// An existing .barkpark keeps its mode; only the folders the host owns are
// tightened.
func TestWriteTurnFileTightensTheAttachmentFolders(t *testing.T) {
	roots, cwd, _ := turnFileWorld(t)
	mustMkdir(t, filepath.Join(cwd, ".barkpark", "attachments", testSessionID))
	for _, dir := range []string{".barkpark", ".barkpark/attachments", ".barkpark/attachments/" + testSessionID} {
		if err := os.Chmod(filepath.Join(cwd, dir), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	data := []byte("text")
	if _, err := WriteTurnFile(roots, cwd, testSessionID, fileRef(data, "text/plain", "a.txt"), data); err != nil {
		t.Fatal(err)
	}
	for dir, want := range map[string]os.FileMode{".barkpark": 0o755, ".barkpark/attachments": 0o700, ".barkpark/attachments/" + testSessionID: 0o700} {
		if info, _ := os.Lstat(filepath.Join(cwd, dir)); info.Mode().Perm() != want {
			t.Errorf("%s: mode %v, want %v", dir, info.Mode().Perm(), want)
		}
	}
}

// The criterion: the sweep removes only real, UUID-named session folders
// last changed more than 7 days ago, never the turn's own, and never follows
// a link.
func TestSweepRemovesOnlyOldSessionFolders(t *testing.T) {
	roots, cwd, outside := turnFileWorld(t)
	attachments := filepath.Join(cwd, ".barkpark", "attachments")
	now := time.Now()
	old := now.Add(-8 * 24 * time.Hour)

	const (
		oldID     = "11111111-1111-4111-8111-111111111111"
		recentID  = "22222222-2222-4222-8222-222222222222"
		linkID    = "33333333-3333-4333-8333-333333333333"
		fileID    = "44444444-4444-4444-8444-444444444444"
		linkInsID = "55555555-5555-4555-8555-555555555555"
		linkAttID = "66666666-6666-4666-8666-666666666666"
	)
	// An old session folder holding a file and a link out of the root.
	mustMkdir(t, filepath.Join(attachments, oldID))
	if err := os.WriteFile(filepath.Join(attachments, oldID, "f.txt"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	victim := filepath.Join(outside, "victim")
	mustMkdir(t, victim)
	if err := os.WriteFile(filepath.Join(victim, "keep.txt"), []byte("keep"), 0o600); err != nil {
		t.Fatal(err)
	}
	mustSymlink(t, victim, filepath.Join(attachments, oldID, "out"))
	// A recent one, the turn's own (old), a non-UUID one (old), an old link
	// named like a session, an old regular file named like a session.
	mustMkdir(t, filepath.Join(attachments, recentID))
	mustMkdir(t, filepath.Join(attachments, testSessionID))
	mustMkdir(t, filepath.Join(attachments, "not-a-session"))
	mustSymlink(t, victim, filepath.Join(attachments, linkID))
	if err := os.WriteFile(filepath.Join(attachments, fileID), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	mustMkdir(t, filepath.Join(cwd, "src"))
	mustSymlink(t, filepath.Join(cwd, "src"), filepath.Join(attachments, linkInsID))
	// A link that stays inside the attachments folder, at an old folder.
	mustSymlink(t, "not-a-session", filepath.Join(attachments, linkAttID))
	for _, name := range []string{oldID, testSessionID, "not-a-session", fileID} {
		if err := os.Chtimes(filepath.Join(attachments, name), old, old); err != nil {
			t.Fatal(err)
		}
	}
	// The links are new, but what they point at is old: a sweep that follows
	// a link sees an old folder there.
	for _, target := range []string{victim, filepath.Join(cwd, "src")} {
		if err := os.Chtimes(target, old, old); err != nil {
			t.Fatal(err)
		}
	}

	removed, err := SweepTurnFiles(roots, cwd, testSessionID, now)
	if err != nil {
		t.Fatal(err)
	}
	if removed != 1 {
		t.Fatalf("removed %d folders, want 1", removed)
	}
	entries, _ := os.ReadDir(attachments)
	var left []string
	for _, entry := range entries {
		left = append(left, entry.Name())
	}
	sort.Strings(left)
	want := []string{recentID, linkID, fileID, linkInsID, linkAttID, testSessionID, "not-a-session"}
	sort.Strings(want)
	if strings.Join(left, "|") != strings.Join(want, "|") {
		t.Fatalf("left %v, want %v", left, want)
	}
	wantFile(t, filepath.Join(victim, "keep.txt"), []byte("keep"), 0o600)
	if _, err := os.Stat(filepath.Join(cwd, "src")); err != nil {
		t.Fatalf("the link's target inside the project went: %v", err)
	}
}

func TestSweepRefusesALinkedAttachmentsFolder(t *testing.T) {
	roots, cwd, outside := turnFileWorld(t)
	old := time.Now().Add(-30 * 24 * time.Hour)
	const oldID = "11111111-1111-4111-8111-111111111111"
	mustMkdir(t, filepath.Join(outside, oldID))
	if err := os.Chtimes(filepath.Join(outside, oldID), old, old); err != nil {
		t.Fatal(err)
	}
	mustMkdir(t, filepath.Join(cwd, ".barkpark"))
	mustSymlink(t, outside, filepath.Join(cwd, ".barkpark", "attachments"))
	_, err := SweepTurnFiles(roots, cwd, testSessionID, time.Now())
	wantTurnFileRefused(t, err, "link")
	if _, err := os.Stat(filepath.Join(outside, oldID)); err != nil {
		t.Fatalf("the sweep followed the link and removed %s: %v", oldID, err)
	}
}

// A session folder idle for more than 7 days that a turn touches again is
// kept by the next sweep, with the files its earlier turns named.
func TestTouchTurnFilesKeepsAResumedSessionFromTheSweep(t *testing.T) {
	roots, cwd, _ := turnFileWorld(t)
	data := []byte("an earlier turn's file")
	file, err := WriteTurnFile(roots, cwd, testSessionID, fileRef(data, "text/plain", "a.txt"), data)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	stale := now.Add(-8 * 24 * time.Hour)
	for _, path := range []string{file.Path, sessionFolder(cwd)} {
		if err := os.Chtimes(path, stale, stale); err != nil {
			t.Fatal(err)
		}
	}
	if err := TouchTurnFiles(roots, cwd, testSessionID, now); err != nil {
		t.Fatal(err)
	}
	const otherID = "77777777-7777-4777-8777-777777777777"
	if removed, err := SweepTurnFiles(roots, cwd, otherID, now); err != nil || removed != 0 {
		t.Fatalf("removed=%d err=%v; want the touched session kept", removed, err)
	}
	wantFile(t, file.Path, data, 0o600)
}

func TestTouchTurnFilesCreatesNothingAndNeverFollowsALink(t *testing.T) {
	roots, cwd, outside := turnFileWorld(t)
	if err := TouchTurnFiles(roots, cwd, testSessionID, time.Now()); err != nil {
		t.Fatalf("no folder: %v", err)
	}
	if tree := listTree(t, cwd); len(tree) != 0 {
		t.Fatalf("touch created %v", tree)
	}

	stale := time.Now().Add(-30 * 24 * time.Hour)
	if err := os.Chtimes(outside, stale, stale); err != nil {
		t.Fatal(err)
	}
	mustMkdir(t, filepath.Join(cwd, ".barkpark", "attachments"))
	mustSymlink(t, outside, sessionFolder(cwd))
	err := TouchTurnFiles(roots, cwd, testSessionID, time.Now())
	wantTurnFileRefused(t, err, "link")
	if info, _ := os.Stat(outside); !info.ModTime().Equal(stale) {
		t.Fatalf("the link's target was touched: mtime %v", info.ModTime())
	}
	wantTurnFileRefused(t, TouchTurnFiles(roots, cwd, "../x", time.Now()), "session id")
}

func TestSweepWithNoAttachmentsFolderDoesNothing(t *testing.T) {
	roots, cwd, _ := turnFileWorld(t)
	removed, err := SweepTurnFiles(roots, cwd, testSessionID, time.Now())
	if err != nil || removed != 0 {
		t.Fatalf("removed=%d err=%v", removed, err)
	}
	if tree := listTree(t, cwd); len(tree) != 0 {
		t.Fatalf("the sweep created %v", tree)
	}
}

func mustMkdir(t *testing.T, dir string) {
	t.Helper()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
}

func mustSymlink(t *testing.T, target, link string) {
	t.Helper()
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
}

func wantFile(t *testing.T, path string, data []byte, mode os.FileMode) {
	t.Helper()
	info, err := os.Lstat(path)
	if err != nil {
		t.Fatal(err)
	}
	if !info.Mode().IsRegular() || info.Mode().Perm() != mode {
		t.Fatalf("%s: mode %v, want a regular %v file", path, info.Mode(), mode)
	}
	got, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(got, data) {
		t.Fatalf("%s holds %q (err=%v), want %q", path, got, err, data)
	}
}
