package cli

import (
	"bytes"
	"encoding/json"
	"errors"
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

// A write failure injected AFTER the disposable temp file exists (simulating
// the exact point where the old direct os.WriteFile(path, ...) would already
// have truncated the REAL settings.json, since O_TRUNC fires at open() before
// a single byte of the new content is written) must leave the original file
// byte-for-byte untouched, because the new code never opens `path` itself for
// writing at all — only the temp sibling. Exit is non-zero... no: exit stays
// exitOK here and the fallback fires, because the target is PROVABLY
// untouched (the atomic design's whole point) — but the emitted text must
// truthfully say so, not just claim it blindly as the old unconditional
// message did. This test reds on today's main: reverting cmuxAtomicWriteFile
// to a direct os.WriteFile(path, data, 0o644) makes the injected failure
// truncate `path` itself, so the "original bytes intact" assertion fails.
func TestCmuxMergeWriteFailureLeavesOriginalIntact(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "settings.json")
	original := `{"model":"opus","hooks":{}}`
	if err := os.WriteFile(path, []byte(original), 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}

	origSeam := cmuxAtomicWriteAndSync
	cmuxAtomicWriteAndSync = func(f *os.File, data []byte) error {
		return errors.New("injected write failure")
	}
	defer func() { cmuxAtomicWriteAndSync = origSeam }()

	_, stdout, code := mergeCapture(t, globals{yes: true}, path, false)
	if code != exitOK {
		t.Fatalf("exit = %d, want 0 (the target is provably untouched)", code)
	}

	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	if string(got) != original {
		t.Errorf("original bytes were NOT left intact after the injected write failure:\noriginal:\n%s\ngot:\n%s", original, got)
	}
	if baks, _ := filepath.Glob(path + ".bak-*"); len(baks) != 0 {
		t.Errorf("a failed write must leave no stray backup either, found %v", baks)
	}
	if !strings.Contains(strings.ToLower(stdout), "nothing was written") {
		t.Errorf("fallback text should say nothing was written (it's true here):\n%s", stdout)
	}
}

// A settings.json with a tightened mode (0600, as a user who cares about
// token-bearing siblings in the same file might set) keeps that exact mode
// after a successful --yes merge — checked with os.Stat, not assumed from the
// call site.
func TestCmuxMergePreservesExistingMode(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "settings.json")
	if err := os.WriteFile(path, []byte(`{"hooks":{}}`), 0o600); err != nil {
		t.Fatalf("seed: %v", err)
	}

	if _, _, code := mergeCapture(t, globals{yes: true}, path, false); code != exitOK {
		t.Fatalf("exit = %d, want 0", code)
	}

	fi, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat %s: %v", path, err)
	}
	if got := fi.Mode().Perm(); got != 0o600 {
		t.Errorf("mode after merge = %o, want 0600 (preserved)", got)
	}
}

// A corrupted read-back — the rename committed, but what comes back does not
// parse as JSON carrying our hooks — is a hard failure: non-zero exit, a
// message on stderr, and the envelope (when machine output is requested)
// marks written=true/verified=false rather than claiming success.
func TestCmuxMergeCorruptedReadBackFails(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "settings.json")
	if err := os.WriteFile(path, []byte(`{"hooks":{}}`), 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}

	origSeam := cmuxReadBack
	cmuxReadBack = func(string) ([]byte, error) {
		return []byte("not actually json"), nil
	}
	defer func() { cmuxReadBack = origSeam }()

	var so, se bytes.Buffer
	w := &writer{stdout: &so, stderr: &se, output: "table"}
	code := cmuxInstallMergeAt(w, globals{yes: true}, path)
	if code == exitOK {
		t.Fatalf("exit = %d, want non-zero on a corrupted read-back", code)
	}
	if se.Len() == 0 {
		t.Error("a corrupted read-back must say something on stderr")
	}
	if strings.Contains(strings.ToLower(so.String()+se.String()), "nothing was written") {
		t.Errorf("the rename committed — this must NOT claim nothing was written:\nstdout:%s\nstderr:%s", so.String(), se.String())
	}

	// The real write went through (the rename committed before verify ran) —
	// this is not a "refuse to touch it" situation, so the file DID change.
	on, _ := os.ReadFile(path)
	if string(on) == `{"hooks":{}}` {
		t.Error("expected the merged content to have landed before the read-back check ran")
	}

	// Machine-output parity: the envelope says so too.
	var so2, se2 bytes.Buffer
	w2 := &writer{stdout: &so2, stderr: &se2, output: "json"}
	if err := os.WriteFile(path, []byte(`{"hooks":{}}`), 0o644); err != nil {
		t.Fatalf("reseed: %v", err)
	}
	code2 := cmuxInstallMergeAt(w2, globals{yes: true, output: "json", outputSet: true}, path)
	if code2 == exitOK {
		t.Fatalf("json-mode exit = %d, want non-zero", code2)
	}
	var env map[string]any
	if err := json.Unmarshal(so2.Bytes(), &env); err != nil {
		t.Fatalf("unmarshal envelope %q: %v", so2.String(), err)
	}
	if ok, _ := env["ok"].(bool); ok {
		t.Errorf("envelope ok=true on a corrupted read-back: %v", env)
	}
	if written, _ := env["written"].(bool); !written {
		t.Errorf("envelope should still report written=true (the rename committed): %v", env)
	}
	if verified, present := env["verified"].(bool); !present || verified {
		t.Errorf("envelope should report verified=false: %v", env)
	}
}

// MUTATION PROOF: this is the exact scenario TestCmuxMergeWriteFailureLeavesOriginalIntact
// guards. To reproduce the red→green by hand:
//
//	1. Edit writeSettings to `return os.WriteFile(path, data, 0o644)` (dropping
//	   cmuxAtomicWriteFile entirely) and drop the mode param from backupSettings
//	   the same way.
//	2. `go test ./internal/cli/ -run TestCmuxMergeWriteFailureLeavesOriginalIntact -v`
//	   now fails: the injected cmuxAtomicWriteAndSync failure is never reached
//	   (the reverted code doesn't call that seam at all), so os.WriteFile opens
//	   `path` with O_TRUNC, truncates it, writes the full merged bytes, and
//	   SUCCEEDS — the "original bytes intact" assertion reds because the file
//	   changed to the merged content instead of staying as `original`.
//	3. Restoring the atomic implementation greens it again.
//
// (Left as a comment, not a t.Run, because actually reverting production code
// from inside a test would defeat the point of the regression test it revert
// is proving; this documents the mutation performed by hand during review —
// see the task evidence for the captured red output.)

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
