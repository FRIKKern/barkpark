package cli

// cmux_install_merge.go — `bp cmux install --merge [--yes]`: the ADDITIVE writer
// that folds the four `bp cmux hook <event>` entries into ~/.claude/settings.json
// so the pane-auto-owns bridge is wired without hand-editing (task-TUI epic,
// wave 14, design §5c — the slice cmux_install.go line 91 reserves).
//
// The contract, in one breath: it ONLY adds. Unknown top-level keys are carried
// through byte-for-byte (parsed as json.RawMessage, never re-keyed); foreign hooks
// — cmux's own `cmux claude-hook` included — are never removed or reordered; our
// four groups are appended per event, DEDUPED by exact command string so a second
// run (or a manual paste of the same block) adds nothing. Before any write it
// times-stamps a backup sibling and prints a diff; without --yes it prints the
// diff and exits WITHOUT writing (the preview IS the product, exit 0). A settings
// file that will not parse as JSON falls back to print-only guidance with a plain
// note — never a destructive rewrite, always exit 0. The verb only runs when a
// human invokes it and NEVER touches a repo-local .claude/settings.json.

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// cmuxHookEvents is the fixed, deterministic order our four groups are ensured in
// (map iteration is unordered; this list makes the merge — and its diff — stable).
var cmuxHookEvents = []string{"SessionStart", "PreToolUse", "Stop", "SessionEnd"}

// cmuxNow is the clock seam (backup filenames carry a UTC timestamp); overridable
// in tests for a deterministic sibling name.
var cmuxNow = time.Now

// hookGroup / hookCmd mirror the Claude Code settings hooks shape just deeply
// enough to read a group's command strings for dedup. We never re-serialize a
// foreign group through these types (that would drop unknown fields) — they are
// read-only probes; foreign groups ride as json.RawMessage.
type hookCmd struct {
	Command string `json:"command"`
}
type hookGroup struct {
	Hooks []hookCmd `json:"hooks"`
}

// defaultCmuxSettingsPath resolves ~/.claude/settings.json. It NEVER falls back to
// a repo-relative path — the merge writer only ever touches the user's home config.
func defaultCmuxSettingsPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil || strings.TrimSpace(home) == "" {
		return "", errors.New("no home directory")
	}
	return filepath.Join(home, ".claude", "settings.json"), nil
}

// runCmuxInstallMerge is the --merge entrypoint dispatched from runCmuxInstall. It
// resolves the default target and delegates to cmuxInstallMergeAt (the path seam
// tests drive directly). A missing home dir degrades to print-only guidance.
func runCmuxInstallMerge(out *writer, g globals) int {
	path, err := defaultCmuxSettingsPath()
	if err != nil {
		return cmuxMergeFallback(out, "", err)
	}
	return cmuxInstallMergeAt(out, g, path)
}

// cmuxInstallMergeAt is the testable core: read settings at path, compute the
// additive merge, and either preview (no --yes) or write (backup first). It is
// non-destructive on every unhappy path and returns exitOK throughout — this is a
// convenience installer, not a gate; the only "failure" is a JSON it won't parse,
// which becomes honest print-only guidance.
func cmuxInstallMergeAt(out *writer, g globals, path string) int {
	orig, exists, err := readSettings(path)
	if err != nil {
		// Unreadable for a reason other than absence (permissions, a directory):
		// print-only guidance, write nothing.
		return cmuxMergeFallback(out, path, err)
	}

	top, hooks, perr := parseSettings(orig, exists)
	if perr != nil {
		return cmuxMergeFallback(out, path, perr)
	}

	added := mergeHooks(hooks)
	next, merr := renderSettings(top, hooks)
	if merr != nil {
		return cmuxMergeFallback(out, path, merr)
	}

	changed := !exists || !bytes.Equal(orig, next)

	if !changed {
		return cmuxMergeNoop(out, g, path)
	}
	if !g.yes {
		return cmuxMergePreview(out, g, path, exists, orig, next, added)
	}
	return cmuxMergeWrite(out, g, path, exists, orig, next, added)
}

// readSettings returns the file bytes and whether it existed. A missing file is
// (nil, false, nil) — a legitimate first-install; any other read error surfaces.
func readSettings(path string) (data []byte, exists bool, err error) {
	b, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, false, nil
		}
		return nil, false, err
	}
	return b, true, nil
}

// parseSettings decodes the top level as map[string]json.RawMessage (unknown keys
// survive byte-untouched) and the "hooks" key as event → groups. A file that will
// not parse into these shapes returns an error → the caller's print-only fallback.
// A missing/absent file starts from empty objects.
func parseSettings(data []byte, exists bool) (map[string]json.RawMessage, map[string][]json.RawMessage, error) {
	top := map[string]json.RawMessage{}
	if exists && len(bytes.TrimSpace(data)) > 0 {
		if err := json.Unmarshal(data, &top); err != nil {
			return nil, nil, err
		}
	}
	hooks := map[string][]json.RawMessage{}
	if raw, ok := top["hooks"]; ok && len(bytes.TrimSpace(raw)) > 0 {
		if err := json.Unmarshal(raw, &hooks); err != nil {
			return nil, nil, err
		}
	}
	return top, hooks, nil
}

// mergeHooks appends our group to each event that does not already carry a hook
// with our exact command string. Foreign groups are never removed or reordered —
// we only append. Returns the events we actually added (empty ⇒ already wired).
func mergeHooks(hooks map[string][]json.RawMessage) []string {
	desired := cmuxDesiredHooks()
	var added []string
	for _, ev := range cmuxHookEvents {
		cmd := "bp cmux hook " + ev
		if eventHasCommand(hooks[ev], cmd) {
			continue // dedup by exact command string — already present
		}
		hooks[ev] = append(hooks[ev], desired[ev]...)
		added = append(added, ev)
	}
	return added
}

// eventHasCommand reports whether any group in an event already carries a hook
// whose command equals cmd. A group that does not parse into hookGroup contributes
// no match (safe: at worst we append, never drop a foreign entry).
func eventHasCommand(groups []json.RawMessage, cmd string) bool {
	for _, raw := range groups {
		var g hookGroup
		if json.Unmarshal(raw, &g) != nil {
			continue
		}
		for _, h := range g.Hooks {
			if h.Command == cmd {
				return true
			}
		}
	}
	return false
}

// renderSettings re-marshals the merged hooks back onto the top-level map and
// pretty-prints the whole document with stable 2-space indentation + a trailing
// newline. MarshalIndent normalizes formatting deterministically, which is what
// makes the second run a byte-identical no-op.
func renderSettings(top map[string]json.RawMessage, hooks map[string][]json.RawMessage) ([]byte, error) {
	hraw, err := json.Marshal(hooks)
	if err != nil {
		return nil, err
	}
	top["hooks"] = hraw
	pretty, err := json.MarshalIndent(top, "", "  ")
	if err != nil {
		return nil, err
	}
	return append(pretty, '\n'), nil
}

// cmuxDesiredHooks parses the four groups out of the single-source-of-truth
// cmuxHooksBlock so the merge and the --print block can never drift.
func cmuxDesiredHooks() map[string][]json.RawMessage {
	var src struct {
		Hooks map[string][]json.RawMessage `json:"hooks"`
	}
	// cmuxHooksBlock is a compile-time constant already asserted valid by
	// TestCmuxInstallPrint; a decode error here is impossible, but be total.
	_ = json.Unmarshal([]byte(cmuxHooksBlock), &src)
	return src.Hooks
}

// --- outcome renderers (human + machine parity) ---------------------------------

func cmuxMergeNoop(out *writer, g globals, path string) int {
	if out.machineOut() {
		out.renderJSON(map[string]any{
			"ok": true, "path": path, "changed": false, "written": false,
			"added": []string{}, "note": "already wired; nothing to do",
		})
		return exitOK
	}
	out.outf("# bp cmux install --merge — already wired; nothing to do.")
	out.outf("# target: %s (unchanged)", path)
	return exitOK
}

func cmuxMergePreview(out *writer, g globals, path string, exists bool, orig, next []byte, added []string) int {
	if out.machineOut() {
		out.renderJSON(map[string]any{
			"ok": true, "path": path, "changed": true, "written": false,
			"added": added, "diff": string(bytes.Join(diffLines(orig, next), []byte{'\n'})),
			"note": "preview only — re-run with --yes to write",
		})
		return exitOK
	}
	verb := "merge into"
	if !exists {
		verb = "create"
	}
	out.outf("# bp cmux install --merge — preview (nothing written).")
	out.outf("# would %s: %s", verb, path)
	out.outf("# adds hooks for: %s", strings.Join(added, ", "))
	out.outf("#")
	out.outf("# diff (- current, + after merge):")
	printDiff(out, orig, next)
	out.outf("#")
	out.outf("# Re-run with --yes to write it (a timestamped backup is made first).")
	return exitOK
}

func cmuxMergeWrite(out *writer, g globals, path string, exists bool, orig, next []byte, added []string) int {
	// Captured BEFORE any write touches path, while the original file (and its
	// mode) is still the thing sitting there — this is what lets a tightened
	// 0600 settings.json stay 0600 after the merge.
	mode := targetMode(path)

	backup := ""
	if exists {
		var err error
		backup, err = backupSettings(path, orig, mode)
		if err != nil {
			// Refuse to overwrite without a backup — that is the one destructive
			// move the contract forbids. Honest failure, nothing written.
			return cmuxMergeFallback(out, path, err)
		}
	}
	if err := writeSettings(path, next, mode); err != nil {
		// writeSettings is temp-file-plus-rename: `path` itself is never opened
		// for writing, so ANY failure here (create, flush, chmod, or the rename
		// itself) leaves whatever was already at `path` byte-for-byte untouched.
		// The non-destructive fallback's "Nothing was written" claim is still
		// true — unlike the direct os.WriteFile this replaced, which opened
		// `path` with O_TRUNC before writing and so could truncate it first.
		return cmuxMergeFallback(out, path, err)
	}
	if err := verifyWrittenSettings(path); err != nil {
		// Past this point the rename already committed — `path` HAS changed,
		// so this is no longer the "nothing was written" case and does not get
		// the print-only fallback. Honest failure, non-zero exit, stderr.
		return cmuxMergeWriteUnverified(out, path, backup, err)
	}
	if out.machineOut() {
		out.renderJSON(map[string]any{
			"ok": true, "path": path, "changed": true, "written": true,
			"backup": backup, "added": added,
		})
		return exitOK
	}
	if backup != "" {
		out.outf("# backed up %s → %s", path, backup)
	} else {
		out.outf("# created %s", path)
	}
	out.outf("# wrote %s — hooks ensured for: %s", path, strings.Join(added, ", "))
	return exitOK
}

// cmuxMergeWriteUnverified fires only when the atomic rename onto `path`
// already committed but the read-back afterward could not confirm the file
// holds valid, merged JSON. Unlike cmuxMergeFallback this is NOT a "nothing
// was written" situation — the file changed — so it is honest about that,
// points at the backup when one exists, and exits non-zero to stderr instead
// of the usual exit-0 convenience-installer path.
func cmuxMergeWriteUnverified(out *writer, path, backup string, cause error) int {
	msg := fmt.Sprintf("wrote %s but could not verify it afterward: %s", path, cause.Error())
	if backup != "" {
		msg += "; the previous content is backed up at " + backup
	}
	if out.machineOut() {
		out.renderJSON(map[string]any{
			"ok": false, "path": path, "written": true, "verified": false,
			"backup": backup, "error": msg,
		})
		return exitGeneric
	}
	out.userErr("%s", msg)
	return exitGeneric
}

// cmuxMergeFallback is the non-destructive escape hatch: when the settings file
// cannot be parsed or written, print the block to add by hand and exit 0. A merge
// convenience must never leave the user worse off than the print-only default.
func cmuxMergeFallback(out *writer, path string, cause error) int {
	if out.machineOut() {
		out.renderJSON(map[string]any{
			"ok": true, "path": path, "changed": false, "written": false,
			"fallback": true, "note": fallbackNote(path, cause),
		})
		return exitOK
	}
	out.outf("# bp cmux install --merge — %s", fallbackNote(path, cause))
	out.outf("# Nothing was written. Add these entries to the \"hooks\" object by hand:")
	out.outf("")
	out.outf("%s", cmuxHooksBlock)
	return exitOK
}

func fallbackNote(path string, cause error) string {
	if path == "" {
		return "could not locate ~/.claude/settings.json (" + cause.Error() + ")"
	}
	return "could not use " + path + " (" + cause.Error() + ")"
}

// backupSettings copies the current bytes to a timestamped sibling
// (settings.json.bak-YYYYMMDDThhmmssZ) preserving them before any overwrite.
// Written atomically (temp + rename) so a failure mid-backup never leaves a
// partial .bak file sitting on disk, and carries the SAME mode as the real
// settings file it is a copy of.
func backupSettings(path string, orig []byte, mode os.FileMode) (string, error) {
	stamp := cmuxNow().UTC().Format("20060102T150405Z")
	backup := path + ".bak-" + stamp
	if err := cmuxAtomicWriteFile(backup, orig, mode); err != nil {
		return "", err
	}
	return backup, nil
}

// writeSettings creates the parent directory as needed and atomically writes
// the merged file: temp file in the same directory + write + fsync + chmod to
// mode + rename onto path. `path` itself is never opened for writing — only
// the disposable temp file is — so any failure before the final rename leaves
// whatever was already at `path` byte-for-byte untouched.
func writeSettings(path string, data []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return cmuxAtomicWriteFile(path, data, mode)
}

// targetMode is the mode a write to path should preserve: the existing file's
// own mode when one is already there (so a user's tightened 0600 stays 0600
// after we merge into it), or 0o644 for a brand-new file. Must be read BEFORE
// any write touches path.
func targetMode(path string) os.FileMode {
	if fi, err := os.Stat(path); err == nil {
		return fi.Mode().Perm()
	}
	return 0o644
}

// cmuxAtomicWriteAndSync is the seam around flushing bytes into an
// already-created temp file. Tests override it to inject a failure at exactly
// this point — after the disposable temp file exists but before it is renamed
// onto the real target — to prove that failure mode never reaches the real
// settings file. (The direct os.WriteFile this replaced opened `path` itself
// with O_TRUNC before writing, so the identical failure used to truncate the
// user's real file first and THEN fail.)
var cmuxAtomicWriteAndSync = func(f *os.File, data []byte) error {
	if _, err := f.Write(data); err != nil {
		return err
	}
	return f.Sync()
}

// cmuxAtomicWriteFile writes data to a sibling temp file in path's own directory,
// flushes + syncs it, chmods it to mode, then renames it onto path. Every step
// up to and including a failed rename touches ONLY the disposable temp file —
// whatever was at `path` before the call is never opened for writing, so a
// failure anywhere in this function leaves it exactly as it was.
func cmuxAtomicWriteFile(path string, data []byte, mode os.FileMode) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, filepath.Base(path)+".tmp-*")
	if err != nil {
		return fmt.Errorf("create temp file in %s: %w", dir, err)
	}
	tmpPath := tmp.Name()
	defer func() {
		_ = tmp.Close()        // no-op if already closed below
		_ = os.Remove(tmpPath) // no-op once the rename below has moved it away
	}()

	if err := cmuxAtomicWriteAndSync(tmp, data); err != nil {
		return fmt.Errorf("write %s: %w", tmpPath, err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("close %s: %w", tmpPath, err)
	}
	if err := os.Chmod(tmpPath, mode); err != nil {
		return fmt.Errorf("chmod %s: %w", tmpPath, err)
	}
	if err := os.Rename(tmpPath, path); err != nil {
		return fmt.Errorf("rename %s onto %s: %w", tmpPath, path, err)
	}
	return nil
}

// cmuxReadBack is the seam verifyWrittenSettings reads the freshly-written
// file through. Tests override it to simulate a corrupted read-back (garbage
// bytes, or a read error) even when the real rename already committed, to
// prove the verify step alone turns that into a hard failure rather than a
// false success.
var cmuxReadBack = os.ReadFile

// verifyWrittenSettings re-reads path right after a write and confirms it
// parses as JSON carrying every one of our four hook commands. A successful
// os.Rename only proves the bytes moved — this is what proves the bytes on
// disk are actually the merge we intended, rather than trusting the write
// blindly.
func verifyWrittenSettings(path string) error {
	data, err := cmuxReadBack(path)
	if err != nil {
		return fmt.Errorf("read back %s: %w", path, err)
	}
	_, hooks, err := parseSettings(data, true)
	if err != nil {
		return fmt.Errorf("read-back %s does not parse as JSON: %w", path, err)
	}
	for _, ev := range cmuxHookEvents {
		if !eventHasCommand(hooks[ev], "bp cmux hook "+ev) {
			return fmt.Errorf("read-back %s is missing the %q hook after merge", path, ev)
		}
	}
	return nil
}

// --- diff (minimal LCS line diff — no external dep) -----------------------------

func printDiff(out *writer, orig, next []byte) {
	for _, ln := range diffLines(orig, next) {
		out.outf("%s", string(ln))
	}
}

// diffLines returns a `- `/`+ `/`  `-prefixed line diff of orig→next via a longest
// common subsequence backtrack. Small files (settings.json is tens of lines) make
// the O(n·m) table trivially cheap, and it keeps the writer dependency-free.
func diffLines(orig, next []byte) [][]byte {
	a := splitDiffLines(orig)
	b := splitDiffLines(next)
	n, m := len(a), len(b)
	lcs := make([][]int, n+1)
	for i := range lcs {
		lcs[i] = make([]int, m+1)
	}
	for i := n - 1; i >= 0; i-- {
		for j := m - 1; j >= 0; j-- {
			if a[i] == b[j] {
				lcs[i][j] = lcs[i+1][j+1] + 1
			} else if lcs[i+1][j] >= lcs[i][j+1] {
				lcs[i][j] = lcs[i+1][j]
			} else {
				lcs[i][j] = lcs[i][j+1]
			}
		}
	}
	var outLines [][]byte
	i, j := 0, 0
	for i < n && j < m {
		switch {
		case a[i] == b[j]:
			outLines = append(outLines, []byte("  "+a[i]))
			i++
			j++
		case lcs[i+1][j] >= lcs[i][j+1]:
			outLines = append(outLines, []byte("- "+a[i]))
			i++
		default:
			outLines = append(outLines, []byte("+ "+b[j]))
			j++
		}
	}
	for ; i < n; i++ {
		outLines = append(outLines, []byte("- "+a[i]))
	}
	for ; j < m; j++ {
		outLines = append(outLines, []byte("+ "+b[j]))
	}
	return outLines
}

// splitDiffLines splits into lines without a trailing empty element from the final
// newline. Empty input yields no lines (so a create diff is all `+`).
func splitDiffLines(b []byte) []string {
	s := strings.TrimSuffix(string(b), "\n")
	if s == "" {
		return nil
	}
	return strings.Split(s, "\n")
}
