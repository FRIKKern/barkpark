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
	backup := ""
	if exists {
		var err error
		backup, err = backupSettings(path, orig)
		if err != nil {
			// Refuse to overwrite without a backup — that is the one destructive
			// move the contract forbids. Honest failure, nothing written.
			return cmuxMergeFallback(out, path, err)
		}
	}
	if err := writeSettings(path, next); err != nil {
		return cmuxMergeFallback(out, path, err)
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
func backupSettings(path string, orig []byte) (string, error) {
	stamp := cmuxNow().UTC().Format("20060102T150405Z")
	backup := path + ".bak-" + stamp
	if err := os.WriteFile(backup, orig, 0o644); err != nil {
		return "", err
	}
	return backup, nil
}

// writeSettings creates the parent directory as needed and writes the merged file.
func writeSettings(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o644)
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
