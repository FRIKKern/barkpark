package chathost

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// A leased file is written to {cwd}/.barkpark/attachments/{session_id}/
// {sha256}.{ext}, so claude can open it with its own Read tool
// (/papers/chat-host-file-attachments-plan). Every part of that path is a
// value the host checked itself: the session id is a UUID, the sha256 is
// recomputed from the bytes, and the extension comes from a fixed character
// set. The file's name is never part of the path.
//
// Every folder on the path is a real folder: a link, or anything else that is
// not a folder, refuses the write. Each one is checked with Lstat, the
// session folder is resolved again after it is made, and all writes and
// removals go through an os.Root, so a link swapped in after a check still
// cannot take them out of the folder.

const (
	// TurnFileMaxAge is how long a session's files stay: a write sweeps
	// session folders last changed longer ago than this.
	TurnFileMaxAge = 7 * 24 * time.Hour

	turnFileGitignore = "*\n"
)

var turnFilesFolder = filepath.Join(".barkpark", "attachments")

// TurnFile is one file of a turn, written under the session folder.
type TurnFile struct {
	Name      string
	MediaType string
	ByteSize  int
	// Path is absolute and has no link in it.
	Path string
}

// TurnFileError is a file the host refused to write, or a write that failed.
// Nothing of a failed write is left behind: no temp file, no partial file.
type TurnFileError struct {
	Reason string
	Err    error
}

func (e *TurnFileError) Error() string {
	if e.Err != nil {
		return "chat file not written: " + e.Reason + ": " + e.Err.Error()
	}
	return "chat file not written: " + e.Reason
}

func (e *TurnFileError) Unwrap() error { return e.Err }

func refuseFile(format string, args ...any) *TurnFileError {
	return &TurnFileError{Reason: fmt.Sprintf(format, args...)}
}

func failFile(reason string, err error) *TurnFileError {
	return &TurnFileError{Reason: reason, Err: err}
}

// WriteTurnFile writes one fetched file under the session folder of cwd and
// returns where it is. The bytes are checked against the reference again
// first (length, sha256, sniffed type, the store's size cap), so nothing is
// created for bytes that are not the leased file. The file is written to a
// temp file (0600) in the session folder and renamed over the final name:
// two turns with the same bytes share one file and never see half of it, and
// a file already there with other bytes, or a link, is replaced. Folders the
// host makes are 0700. The attachments folder gets a .gitignore of "*" when
// it has none.
func WriteTurnFile(approvedRoots []string, cwd, sessionID string, ref AttachmentRef, data []byte) (TurnFile, error) {
	if refused := checkTurnFile(sessionID, ref, data); refused != nil {
		return TurnFile{}, refused
	}
	session, sessionPath, err := openSessionFolder(approvedRoots, cwd, sessionID)
	if err != nil {
		return TurnFile{}, err
	}
	defer session.Close()

	name := ref.ID + "." + turnFileExt(ref.MediaType, ref.Name)
	if err := writeReplacing(session, name, data); err != nil {
		return TurnFile{}, err
	}
	return TurnFile{Name: ref.Name, MediaType: ref.MediaType, ByteSize: len(data), Path: filepath.Join(sessionPath, name)}, nil
}

func checkTurnFile(sessionID string, ref AttachmentRef, data []byte) *TurnFileError {
	if !isSessionUUID(sessionID) {
		return refuseFile("the session id is not a lowercase UUID")
	}
	if !isAttachmentID(ref.ID) {
		return refuseFile("the id is not 64 lowercase hex characters")
	}
	if !isFileMediaType(ref.MediaType) {
		return refuseFile("%q is not a file type", ref.MediaType)
	}
	if len(data) < 1 || len(data) > MaxAttachmentBytes {
		return refuseFile("%d bytes, a file holds 1..%d bytes", len(data), MaxAttachmentBytes)
	}
	if len(data) != ref.ByteSize {
		return refuseFile("%d bytes, the reference says %d", len(data), ref.ByteSize)
	}
	sum := sha256.Sum256(data)
	if subtle.ConstantTimeCompare([]byte(hex.EncodeToString(sum[:])), []byte(ref.ID)) != 1 {
		return refuseFile("sha256 of the bytes is not the id")
	}
	if sniffMediaType(data) != ref.MediaType {
		return refuseFile("the bytes are not %s", ref.MediaType)
	}
	return nil
}

// openSessionFolder makes (or finds) .barkpark, .barkpark/attachments and
// the session folder under cwd, each a real folder, and opens the session
// folder as a root. The .gitignore is in place before any file is written.
func openSessionFolder(approvedRoots []string, cwd, sessionID string) (*os.Root, string, error) {
	base, err := ResolveApprovedPath(approvedRoots, cwd)
	if err != nil {
		return nil, "", failFile("the working folder is not approved", err)
	}
	project, err := os.OpenRoot(base)
	if err != nil {
		return nil, "", failFile("open the working folder", err)
	}
	defer project.Close()

	if err := ensureRealFolder(project, ".barkpark", false); err != nil {
		return nil, "", err
	}
	if err := ensureRealFolder(project, turnFilesFolder, true); err != nil {
		return nil, "", err
	}
	sessionRel := filepath.Join(turnFilesFolder, sessionID)
	if err := ensureRealFolder(project, sessionRel, true); err != nil {
		return nil, "", err
	}
	if err := ensureGitignore(project, filepath.Join(turnFilesFolder, ".gitignore")); err != nil {
		return nil, "", err
	}

	// After the mkdir: the folder resolves, through whatever links the file
	// system holds, to exactly the path built here, inside an approved root.
	want := filepath.Join(base, sessionRel)
	resolved, err := ResolveApprovedPath(approvedRoots, want)
	if err != nil {
		return nil, "", failFile("the session folder is not inside an approved root", err)
	}
	if resolved != want {
		return nil, "", refuseFile("the session folder resolves to another place, through a link")
	}
	checked, err := project.Lstat(sessionRel)
	if err != nil {
		return nil, "", failFile("read the session folder", err)
	}
	session, err := project.OpenRoot(sessionRel)
	if err != nil {
		return nil, "", failFile("open the session folder", err)
	}
	// The folder opened is the one checked: a swap in between refuses.
	opened, err := session.Stat(".")
	if err != nil || !os.SameFile(checked, opened) {
		session.Close()
		return nil, "", refuseFile("the session folder changed while it was opened, through a link")
	}
	return session, want, nil
}

// ensureRealFolder makes rel (0700) when it is missing, and refuses it when
// it is a link or not a folder. tighten narrows a folder the host owns to
// 0700; .barkpark may be the project's own and keeps its mode.
func ensureRealFolder(root *os.Root, rel string, tighten bool) error {
	info, err := root.Lstat(rel)
	if errors.Is(err, fs.ErrNotExist) {
		if err := root.Mkdir(rel, 0o700); err != nil && !errors.Is(err, fs.ErrExist) {
			return failFile("make "+rel, err)
		}
		info, err = root.Lstat(rel)
	}
	if err != nil {
		return failFile("read "+rel, err)
	}
	if info.Mode()&fs.ModeSymlink != 0 {
		return refuseFile("%s is a link", rel)
	}
	if !info.IsDir() {
		return refuseFile("%s is not a folder", rel)
	}
	if tighten && info.Mode().Perm()&0o077 != 0 {
		if err := root.Chmod(rel, 0o700); err != nil {
			return failFile("narrow "+rel+" to 0700", err)
		}
	}
	return nil
}

// ensureGitignore writes "*" to rel when it is missing, so "commit
// everything" in the project leaves the person's files out. One that exists
// is the person's and stays as it is, unless it is a link or not a file.
func ensureGitignore(root *os.Root, rel string) error {
	info, err := root.Lstat(rel)
	if err == nil {
		if !info.Mode().IsRegular() {
			return refuseFile("%s is a link or not a plain file", rel)
		}
		return nil
	}
	if !errors.Is(err, fs.ErrNotExist) {
		return failFile("read "+rel, err)
	}
	file, err := root.OpenFile(rel, os.O_WRONLY|os.O_CREATE|os.O_EXCL|oNoFollow, 0o600)
	if errors.Is(err, fs.ErrExist) {
		return ensureGitignore(root, rel)
	}
	if err != nil {
		return failFile("write "+rel, err)
	}
	_, err = file.WriteString(turnFileGitignore)
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		_ = root.Remove(rel)
		return failFile("write "+rel, err)
	}
	return nil
}

// writeReplacing writes data to a fresh temp file in the session folder and
// renames it over name. On any failure the temp file is removed.
func writeReplacing(session *os.Root, name string, data []byte) error {
	var random [8]byte
	if _, err := rand.Read(random[:]); err != nil {
		return failFile("name the temp file", err)
	}
	temp := ".tmp-" + hex.EncodeToString(random[:])
	file, err := session.OpenFile(temp, os.O_WRONLY|os.O_CREATE|os.O_EXCL|oNoFollow, 0o600)
	if err != nil {
		return failFile("create the temp file", err)
	}
	renamed := false
	defer func() {
		if !renamed {
			_ = session.Remove(temp)
		}
	}()
	_, err = file.Write(data)
	if err == nil {
		err = file.Sync()
	}
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return failFile("write the temp file", err)
	}
	if err := session.Rename(temp, name); err != nil {
		return failFile("rename the temp file over "+name, err)
	}
	renamed = true
	return nil
}

// TouchTurnFiles marks the session folder of cwd as used now. The sweep goes
// by the folder's mtime, so a session whose turns keep coming keeps the files
// its earlier turns named, even when no new file comes. No folder means
// nothing to do; a link, or a folder path that is not a real folder, is
// refused and left alone.
func TouchTurnFiles(approvedRoots []string, cwd, sessionID string, now time.Time) error {
	if !isSessionUUID(sessionID) {
		return refuseFile("the session id is not a lowercase UUID")
	}
	base, err := ResolveApprovedPath(approvedRoots, cwd)
	if err != nil {
		return failFile("the working folder is not approved", err)
	}
	project, err := os.OpenRoot(base)
	if err != nil {
		return failFile("open the working folder", err)
	}
	defer project.Close()

	sessionRel := filepath.Join(turnFilesFolder, sessionID)
	var checked fs.FileInfo
	for _, rel := range []string{".barkpark", turnFilesFolder, sessionRel} {
		info, err := project.Lstat(rel)
		if errors.Is(err, fs.ErrNotExist) {
			return nil
		}
		if err != nil {
			return failFile("read "+rel, err)
		}
		if info.Mode()&fs.ModeSymlink != 0 {
			return refuseFile("%s is a link", rel)
		}
		if !info.IsDir() {
			return refuseFile("%s is not a folder", rel)
		}
		checked = info
	}
	session, err := project.OpenRoot(sessionRel)
	if err != nil {
		return failFile("open the session folder", err)
	}
	defer session.Close()
	if opened, err := session.Stat("."); err != nil || !os.SameFile(checked, opened) {
		return refuseFile("the session folder changed while it was opened, through a link")
	}
	if err := session.Chtimes(".", now, now); err != nil {
		return failFile("mark the session folder as used", err)
	}
	return nil
}

// SweepTurnFiles removes the session folders under cwd's attachments folder
// that were last changed more than TurnFileMaxAge before now, except
// keepSessionID's. A folder's mtime moves when a file is written into it and
// when a turn of its session runs (TouchTurnFiles). No command tells a host that a session was deleted, so a
// write sweeps. It removes only real folders whose name is a lowercase UUID,
// never follows a link, and removes nothing outside the attachments folder.
// No attachments folder means nothing to do; a linked one is refused.
func SweepTurnFiles(approvedRoots []string, cwd, keepSessionID string, now time.Time) (int, error) {
	base, err := ResolveApprovedPath(approvedRoots, cwd)
	if err != nil {
		return 0, failFile("the working folder is not approved", err)
	}
	project, err := os.OpenRoot(base)
	if err != nil {
		return 0, failFile("open the working folder", err)
	}
	defer project.Close()

	var checked fs.FileInfo
	for _, rel := range []string{".barkpark", turnFilesFolder} {
		info, err := project.Lstat(rel)
		if errors.Is(err, fs.ErrNotExist) {
			return 0, nil
		}
		if err != nil {
			return 0, failFile("read "+rel, err)
		}
		if info.Mode()&fs.ModeSymlink != 0 {
			return 0, refuseFile("%s is a link", rel)
		}
		if !info.IsDir() {
			return 0, refuseFile("%s is not a folder", rel)
		}
		checked = info
	}
	folder, err := project.OpenRoot(turnFilesFolder)
	if err != nil {
		return 0, failFile("open "+turnFilesFolder, err)
	}
	defer folder.Close()
	if opened, err := folder.Stat("."); err != nil || !os.SameFile(checked, opened) {
		return 0, refuseFile("%s changed while it was opened, through a link", turnFilesFolder)
	}

	listing, err := folder.Open(".")
	if err != nil {
		return 0, failFile("list "+turnFilesFolder, err)
	}
	entries, err := listing.ReadDir(-1)
	listing.Close()
	if err != nil {
		return 0, failFile("list "+turnFilesFolder, err)
	}
	removed := 0
	for _, entry := range entries {
		name := entry.Name()
		if name == keepSessionID || !isSessionUUID(name) {
			continue
		}
		info, err := folder.Lstat(name)
		if err != nil || info.Mode()&fs.ModeSymlink != 0 || !info.IsDir() {
			continue
		}
		if now.Sub(info.ModTime()) <= TurnFileMaxAge {
			continue
		}
		if err := folder.RemoveAll(name); err != nil {
			return removed, failFile("remove an old session folder", err)
		}
		removed++
	}
	return removed, nil
}

// isSessionUUID accepts the canonical lowercase form only
// (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx), the form the server's session ids
// take.
func isSessionUUID(id string) bool {
	if len(id) != 36 {
		return false
	}
	for i := 0; i < len(id); i++ {
		c := id[i]
		switch i {
		case 8, 13, 18, 23:
			if c != '-' {
				return false
			}
		default:
			if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
				return false
			}
		}
	}
	return true
}

// turnFileExt is pdf for a PDF. For text it is the name's last extension,
// lowercased, when it is 1 to 10 ASCII letters or digits, and txt otherwise.
// A text file is never written under a PDF or picture extension, which would
// make claude's Read open it as one.
func turnFileExt(mediaType, name string) string {
	if mediaType == "application/pdf" {
		return "pdf"
	}
	dot := strings.LastIndexByte(name, '.')
	if dot < 0 {
		return "txt"
	}
	ext := name[dot+1:]
	if len(ext) < 1 || len(ext) > 10 {
		return "txt"
	}
	lower := make([]byte, len(ext))
	for i := 0; i < len(ext); i++ {
		switch c := ext[i]; {
		case c >= 'a' && c <= 'z', c >= '0' && c <= '9':
			lower[i] = c
		case c >= 'A' && c <= 'Z':
			lower[i] = c + ('a' - 'A')
		default:
			return "txt"
		}
	}
	switch string(lower) {
	case "pdf", "png", "jpg", "jpeg", "gif", "webp":
		return "txt"
	}
	return string(lower)
}
