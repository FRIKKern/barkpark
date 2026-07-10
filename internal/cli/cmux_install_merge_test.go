package cli

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// mergeCapture drives cmuxInstallMergeAt over a temp settings path with an
// in-memory writer. jsonOut selects the machine envelope.
func mergeCapture(t *testing.T, g globals, path string, jsonOut bool) (map[string]any, string, int) {
	t.Helper()
	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "table"}
	if jsonOut {
		w.output = "json"
		g.output = "json"
		g.outputSet = true
	}
	code := cmuxInstallMergeAt(w, g, path)
	var env map[string]any
	if jsonOut && so.Len() > 0 {
		if err := json.Unmarshal(so.Bytes(), &env); err != nil {
			t.Fatalf("unmarshal stdout %q: %v", so.String(), err)
		}
	}
	return env, so.String(), code
}

// eventGroupsWithCommand parses the written settings and returns, per event, how
// many groups carry a hook with the given command — the dedup invariant probe.
func eventGroupsWithCommand(t *testing.T, path, event, cmd string) int {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	var top struct {
		Hooks map[string][]struct {
			Hooks []struct {
				Command string `json:"command"`
			} `json:"hooks"`
		} `json:"hooks"`
	}
	if err := json.Unmarshal(data, &top); err != nil {
		t.Fatalf("parse merged settings: %v\n%s", err, data)
	}
	n := 0
	for _, grp := range top.Hooks[event] {
		for _, h := range grp.Hooks {
			if h.Command == cmd {
				n++
			}
		}
	}
	return n
}

// A settings file carrying a FOREIGN SessionStart hook (cmux's own) plus an
// unrelated top-level key: the merge adds our four hooks, keeps the foreign hook,
// and leaves the unrelated key intact.
func TestCmuxMergePreservesForeignHookAndKey(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "settings.json")
	fixture := `{
  "model": "opus",
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "cmux claude-hook SessionStart" } ] }
    ]
  }
}`
	if err := os.WriteFile(path, []byte(fixture), 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}

	_, _, code := mergeCapture(t, globals{yes: true}, path, false)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}

	data, _ := os.ReadFile(path)
	var top map[string]json.RawMessage
	if err := json.Unmarshal(data, &top); err != nil {
		t.Fatalf("merged not valid JSON: %v\n%s", err, data)
	}
	// Unrelated top-level key survives with its value.
	var model string
	if err := json.Unmarshal(top["model"], &model); err != nil || model != "opus" {
		t.Fatalf("unrelated key not preserved: model=%q err=%v", model, err)
	}
	// All four of our hooks are wired.
	for _, ev := range cmuxHookEvents {
		if n := eventGroupsWithCommand(t, path, ev, "bp cmux hook "+ev); n != 1 {
			t.Errorf("event %s: our command present %d times, want 1", ev, n)
		}
	}
	// The foreign SessionStart hook is NOT removed — SessionStart now has 2 groups.
	var probe struct {
		Hooks map[string][]json.RawMessage `json:"hooks"`
	}
	_ = json.Unmarshal(data, &probe)
	if got := len(probe.Hooks["SessionStart"]); got != 2 {
		t.Errorf("SessionStart groups = %d, want 2 (foreign + ours)", got)
	}
	if !strings.Contains(string(data), "cmux claude-hook SessionStart") {
		t.Error("foreign cmux hook was dropped")
	}
}

// Idempotent: a second --yes merge writes nothing and reports the no-op; file
// bytes are byte-identical.
func TestCmuxMergeIdempotent(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "settings.json")
	if err := os.WriteFile(path, []byte(`{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"cmux claude-hook SessionStart"}]}]}}`), 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}

	if _, _, code := mergeCapture(t, globals{yes: true}, path, false); code != exitOK {
		t.Fatalf("first merge exit = %d", code)
	}
	first, _ := os.ReadFile(path)

	_, stdout, code := mergeCapture(t, globals{yes: true}, path, false)
	if code != exitOK {
		t.Fatalf("second merge exit = %d", code)
	}
	second, _ := os.ReadFile(path)
	if !bytes.Equal(first, second) {
		t.Errorf("second merge changed the bytes:\nfirst:\n%s\nsecond:\n%s", first, second)
	}
	if !strings.Contains(strings.ToLower(stdout), "already wired") {
		t.Errorf("second run should report a no-op, got:\n%s", stdout)
	}
	// No stray extra backups from the no-op run: exactly one .bak from the first write.
	baks, _ := filepath.Glob(path + ".bak-*")
	if len(baks) != 1 {
		t.Errorf("backup count = %d, want 1 (only the first write backs up)", len(baks))
	}
}

// Without --yes: prints the diff, writes nothing, makes no backup, exits 0.
func TestCmuxMergePreviewWritesNothing(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "settings.json")
	fixture := `{"hooks":{}}`
	if err := os.WriteFile(path, []byte(fixture), 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}

	_, stdout, code := mergeCapture(t, globals{}, path, false)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	after, _ := os.ReadFile(path)
	if string(after) != fixture {
		t.Errorf("preview must not write; file changed:\n%s", after)
	}
	if baks, _ := filepath.Glob(path + ".bak-*"); len(baks) != 0 {
		t.Errorf("preview must not back up, found %v", baks)
	}
	for _, want := range []string{"preview", "--yes", "+ "} {
		if !strings.Contains(stdout, want) {
			t.Errorf("preview output missing %q:\n%s", want, stdout)
		}
	}
}

// Backup before write: a timestamped sibling holding the ORIGINAL bytes.
func TestCmuxMergeBacksUpBeforeWrite(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "settings.json")
	original := `{"model":"opus","hooks":{}}`
	if err := os.WriteFile(path, []byte(original), 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}

	env, _, code := mergeCapture(t, globals{yes: true}, path, true)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	backup, _ := env["backup"].(string)
	if backup == "" {
		t.Fatalf("no backup path reported: %v", env)
	}
	got, err := os.ReadFile(backup)
	if err != nil {
		t.Fatalf("read backup: %v", err)
	}
	if string(got) != original {
		t.Errorf("backup should hold the original bytes, got:\n%s", got)
	}
}

// Malformed settings.json → print-only fallback with a note, no write, exit 0.
func TestCmuxMergeMalformedFallsBackToPrint(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "settings.json")
	garbage := "{ this is not json"
	if err := os.WriteFile(path, []byte(garbage), 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}

	_, stdout, code := mergeCapture(t, globals{yes: true}, path, false)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0 (fail-safe)", code)
	}
	after, _ := os.ReadFile(path)
	if string(after) != garbage {
		t.Errorf("malformed file must be left untouched, got:\n%s", after)
	}
	if baks, _ := filepath.Glob(path + ".bak-*"); len(baks) != 0 {
		t.Errorf("malformed path must not back up, found %v", baks)
	}
	if !strings.Contains(strings.ToLower(stdout), "could not") {
		t.Errorf("fallback should carry a plain note:\n%s", stdout)
	}
	// The printed block is still the paste-by-hand source of truth.
	if !strings.Contains(stdout, "bp cmux hook SessionStart") {
		t.Errorf("fallback should print the hook block:\n%s", stdout)
	}
}

// Dedup by exact command string: after a manual paste of our exact block, a
// --yes merge adds nothing (each event keeps exactly one of our commands).
func TestCmuxMergeDedupsManualPaste(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "settings.json")
	// Simulate a human who pasted cmuxHooksBlock by hand already.
	if err := os.WriteFile(path, []byte(cmuxHooksBlock), 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}

	env, _, code := mergeCapture(t, globals{yes: true}, path, true)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	// The manual paste already carried all four — merge is a no-op.
	if changed, _ := env["changed"].(bool); changed {
		// A reformat-only change is tolerable, but no duplicates may appear.
		t.Logf("changed=true (reformat only is acceptable): %v", env)
	}
	for _, ev := range cmuxHookEvents {
		if n := eventGroupsWithCommand(t, path, ev, "bp cmux hook "+ev); n != 1 {
			t.Errorf("event %s: command present %d times after paste+merge, want 1 (no dup)", ev, n)
		}
	}
}

// A missing settings file is a first-install: --yes creates it (parent dir too),
// with no backup, and all four hooks wired.
func TestCmuxMergeCreatesMissingFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "nested", "settings.json") // parent does not exist yet

	env, _, code := mergeCapture(t, globals{yes: true}, path, true)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}
	if written, _ := env["written"].(bool); !written {
		t.Fatalf("should report written on create: %v", env)
	}
	if backup, _ := env["backup"].(string); backup != "" {
		t.Errorf("create must not back up (nothing to back up), got %q", backup)
	}
	for _, ev := range cmuxHookEvents {
		if n := eventGroupsWithCommand(t, path, ev, "bp cmux hook "+ev); n != 1 {
			t.Errorf("event %s: command present %d times, want 1", ev, n)
		}
	}
}

// The verb dispatches through runCmuxInstall on --merge, and refuses unknown flags.
func TestCmuxInstallMergeDispatch(t *testing.T) {
	// --merge with a home-dir seam pointed at a temp file proves the wiring end
	// to end without touching a real ~/.claude/settings.json.
	dir := t.TempDir()
	t.Setenv("HOME", dir) // defaultCmuxSettingsPath → <dir>/.claude/settings.json
	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "table"}
	if code := runCmuxInstall(w, globals{}, []string{"--merge"}); code != exitOK {
		t.Fatalf("--merge preview exit = %d, want 0\n%s", code, se.String())
	}
	if !strings.Contains(so.String(), "preview") {
		t.Errorf("--merge without --yes should preview:\n%s", so.String())
	}

	so.Reset()
	se.Reset()
	if code := runCmuxInstall(w, globals{}, []string{"--bogus"}); code != exitUsage {
		t.Errorf("unknown flag exit = %d, want exitUsage", code)
	}
}
