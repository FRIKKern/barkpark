package chathost

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

// A session may name a bot folder, so several bots can share one computer:
// each new bot runs in its own folder directly under the host's approved root
// (/papers/barkbot-many-bots-plan, task 6). The server leases the name as
// payload.bot_folder beside payload.cwd, and only to a host that advertises
// providers.claude.bot_folders. A session that names no folder has no key, and
// its turns run in cwd exactly as before: claude keeps a session under a folder
// named for its cwd (~/.claude/projects/<cwd>), so moving the cwd would stop
// --resume.
//
// Every value is the server's, so the host checks it again: the name is one
// strict segment, cwd is an approved root itself, and the folder is made with
// the same checks as a turn's file folders (ensureRealFolder, turn_files.go).

// botFolderField is the send_turn payload key that names the session's bot
// folder.
const botFolderField = "bot_folder"

// maxBotFolderName is the longest bot folder name, in bytes.
const maxBotFolderName = 40

// BotFolderError is a bot folder the host refused or could not make. The turn
// fails with it and the provider is never started.
type BotFolderError struct {
	Reason string
	Err    error
}

func (e *BotFolderError) Error() string {
	if e.Err != nil {
		return "bot folder refused: " + e.Reason + ": " + e.Err.Error()
	}
	return "bot folder refused: " + e.Reason
}

func (e *BotFolderError) Unwrap() error { return e.Err }

func refuseBotFolder(format string, args ...any) *BotFolderError {
	return &BotFolderError{Reason: fmt.Sprintf(format, args...)}
}

// parseBotFolder reads payload.bot_folder. named is false only when the key is
// absent. A key that is present is a name the host checks itself: anything but
// a string matching validBotFolderName, the empty string included, refuses the
// turn.
func parseBotFolder(payload map[string]any) (folder string, named bool, err error) {
	raw, present := payload[botFolderField]
	if !present {
		return "", false, nil
	}
	folder, ok := raw.(string)
	if !ok {
		return "", true, refuseBotFolder("%s is not a string", botFolderField)
	}
	if !validBotFolderName(folder) {
		return "", true, refuseBotFolder("%q is not one folder name of 1 to %d lowercase letters, digits and dashes, starting with a letter or digit", folder, maxBotFolderName)
	}
	return folder, true, nil
}

// validBotFolderName is the server's rule, ^[a-z0-9][a-z0-9-]{0,39}$, over the
// whole string: no dot, slash, backslash, space, upper case, newline or byte
// outside ASCII can pass, so the name is never "..", never a path and never
// two segments.
func validBotFolderName(name string) bool {
	if len(name) < 1 || len(name) > maxBotFolderName {
		return false
	}
	for i := 0; i < len(name); i++ {
		c := name[i]
		switch {
		case c >= 'a' && c <= 'z', c >= '0' && c <= '9':
		case c == '-' && i > 0:
		default:
			return false
		}
	}
	return true
}

// BotFolderPath returns {cwd}/{folder} as a real folder, making it (0700) when
// it is missing. cwd must resolve to an approved root itself, so the bot folder
// sits directly under the root. A link or anything that is not a folder at
// that name is refused, and a folder that is already there keeps its mode: it
// may be one the person made. After the mkdir, the folder resolves to exactly
// the path built here, inside an approved root. Two turns making the same
// folder at once both get it.
func BotFolderPath(approvedRoots []string, cwd, folder string) (string, error) {
	if !validBotFolderName(folder) {
		return "", refuseBotFolder("%q is not one folder name", folder)
	}
	base, err := ResolveApprovedPath(approvedRoots, cwd)
	if err != nil {
		return "", &BotFolderError{Reason: "the working folder is not approved", Err: err}
	}
	if !isApprovedRoot(approvedRoots, base) {
		return "", refuseBotFolder("the working folder is not an approved root, so a bot folder would not sit directly under one")
	}
	project, err := os.OpenRoot(base)
	if err != nil {
		return "", &BotFolderError{Reason: "open the approved root", Err: err}
	}
	defer project.Close()

	if err := ensureRealFolder(project, folder, false); err != nil {
		var refused *TurnFileError
		if errors.As(err, &refused) {
			return "", &BotFolderError{Reason: refused.Reason, Err: refused.Err}
		}
		return "", &BotFolderError{Reason: "make " + folder, Err: err}
	}

	want := filepath.Join(base, folder)
	resolved, err := ResolveApprovedPath(approvedRoots, want)
	if err != nil {
		return "", &BotFolderError{Reason: "the bot folder is not inside an approved root", Err: err}
	}
	if resolved != want {
		return "", refuseBotFolder("the bot folder resolves to another place, through a link")
	}
	// The folder at the path is the one checked through the root: a swap in
	// between refuses.
	checked, err := project.Lstat(folder)
	if err != nil {
		return "", &BotFolderError{Reason: "read the bot folder", Err: err}
	}
	atPath, err := os.Lstat(want)
	if err != nil || !atPath.IsDir() || !os.SameFile(checked, atPath) {
		return "", refuseBotFolder("the bot folder changed while it was checked, through a link")
	}
	return want, nil
}

// isApprovedRoot reports whether resolved is one of the approved roots, each
// resolved through its links.
func isApprovedRoot(approvedRoots []string, resolved string) bool {
	for _, root := range approvedRoots {
		real, err := filepath.EvalSymlinks(root)
		if err != nil {
			continue
		}
		if real, err = filepath.Abs(real); err == nil && real == resolved {
			return true
		}
	}
	return false
}
