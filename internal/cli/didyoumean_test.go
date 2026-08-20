package cli

import (
	"encoding/json"
	"io"
	"os"
	"strings"
	"testing"
)

// captureStreams runs Execute(args) with os.Stdout and os.Stderr redirected to
// TWO SEPARATE pipes and returns them independently — the only way to prove the
// contract these tests exist for: the alias rewrite note lands on stderr while
// stdout stays byte-identical to the canonical verb. (captureExecute in
// cli_test.go merges both into one stream, which cannot make that distinction.)
// Both pipes are drained concurrently so a write larger than the OS pipe buffer
// never deadlocks.
func captureStreams(t *testing.T, args []string) (stdout, stderr string) {
	t.Helper()
	outR, outW, err := os.Pipe()
	if err != nil {
		t.Fatalf("os.Pipe (stdout): %v", err)
	}
	errR, errW, err := os.Pipe()
	if err != nil {
		t.Fatalf("os.Pipe (stderr): %v", err)
	}
	origOut, origErr := os.Stdout, os.Stderr
	os.Stdout, os.Stderr = outW, errW

	outC := make(chan string, 1)
	errC := make(chan string, 1)
	go func() { b, _ := io.ReadAll(outR); outC <- string(b) }()
	go func() { b, _ := io.ReadAll(errR); errC <- string(b) }()

	Execute(args)

	os.Stdout, os.Stderr = origOut, origErr
	_ = outW.Close()
	_ = errW.Close()
	stdout, stderr = <-outC, <-errC
	_ = outR.Close()
	_ = errR.Close()
	return stdout, stderr
}

// TestTaskShowAlias pins charter decision 12's `task show`→`get` rewrite: the
// alias fires before manifest dispatch, stdout is byte-identical to the
// canonical `task get`, and the only difference is the one rewrite note on
// stderr. --dry-run keeps the assertion offline and deterministic (dryRun prints
// the resolved request to stdout and exits 0 without a network call).
func TestTaskShowAlias(t *testing.T) {
	t.Setenv("BARKPARK_MANIFEST", fullManifest)

	aliasOut, aliasErr := captureStreams(t, []string{"task", "show", "some-id", "--dry-run"})
	canonOut, _ := captureStreams(t, []string{"task", "get", "some-id", "--dry-run"})

	if aliasOut != canonOut {
		t.Errorf("stdout not byte-identical between `task show` and `task get`:\nshow:\n%q\nget:\n%q", aliasOut, canonOut)
	}
	if aliasOut == "" {
		t.Fatalf("expected a dry-run request on stdout, got empty")
	}
	// The rewrite note must be on stderr, and must NOT leak into stdout.
	if !strings.Contains(aliasErr, "running `barkpark task get`") {
		t.Errorf("rewrite note missing from stderr; got:\n%s", aliasErr)
	}
	if strings.Contains(aliasOut, "note:") {
		t.Errorf("rewrite note leaked into stdout:\n%s", aliasOut)
	}
}

// TestTaskListAlias pins `task list`→`ls`: the alias resolves to the canonical
// verb (stdout identical to `task ls`) with the rewrite note on stderr, and the
// dry-run exits 0.
func TestTaskListAlias(t *testing.T) {
	t.Setenv("BARKPARK_MANIFEST", fullManifest)

	aliasOut, aliasErr := captureStreams(t, []string{"task", "list", "--dry-run"})
	canonOut, _ := captureStreams(t, []string{"task", "ls", "--dry-run"})

	if aliasOut != canonOut {
		t.Errorf("stdout not byte-identical between `task list` and `task ls`:\nlist:\n%q\nls:\n%q", aliasOut, canonOut)
	}
	if !strings.Contains(aliasErr, "running `barkpark task ls`") {
		t.Errorf("rewrite note missing from stderr; got:\n%s", aliasErr)
	}

	// And it exits 0 (dry-run success), not a usage error.
	if _, code := captureExecuteCode(t, []string{"task", "list", "--dry-run"}); code != exitOK {
		t.Errorf("`task list --dry-run` exit = %d, want %d", code, exitOK)
	}
}

// TestUsageErrHintfEnvelope pins the hint-threading half: a mistyped task verb
// (`task raedy`) surfaces the nearest-verb suggestion in the `-o json` error
// envelope's `error.hint` field — the machine surface agents actually read —
// while the human table mode is byte-unaffected (empty stdout, suggestion on
// stderr, exit 2).
func TestUsageErrHintfEnvelope(t *testing.T) {
	t.Setenv("BARKPARK_MANIFEST", fullManifest)

	// Machine mode: the envelope carries the executable did-you-mean hint.
	jsonOut, _ := captureStreams(t, []string{"task", "raedy", "-o", "json"})
	var env struct {
		OK    bool `json:"ok"`
		Error struct {
			Code    string `json:"code"`
			Message string `json:"message"`
			Hint    string `json:"hint"`
		} `json:"error"`
	}
	if err := json.Unmarshal([]byte(jsonOut), &env); err != nil {
		t.Fatalf("stdout is not a parseable JSON envelope: %v\ngot:\n%s", err, jsonOut)
	}
	if env.OK {
		t.Errorf("expected ok:false envelope, got ok:true")
	}
	if env.Error.Code != "usage" {
		t.Errorf("error.code = %q, want %q", env.Error.Code, "usage")
	}
	if env.Error.Hint != "barkpark task ready" {
		t.Errorf("error.hint = %q, want %q", env.Error.Hint, "barkpark task ready")
	}

	// Table mode (-o table explicit — a piped stdout otherwise defaults to json):
	// the hint is machine-only, so stdout stays EMPTY and the human did-you-mean
	// line renders on stderr exactly as before the hint-threading change. Exit is
	// the usage bucket.
	tableOut, tableErr := captureStreams(t, []string{"task", "raedy", "-o", "table"})
	if strings.TrimSpace(tableOut) != "" {
		t.Errorf("table-mode stdout should be empty, got:\n%s", tableOut)
	}
	if !strings.Contains(tableErr, "did you mean `barkpark task ready`") {
		t.Errorf("table-mode stderr missing did-you-mean line; got:\n%s", tableErr)
	}
	if _, code := captureExecuteCode(t, []string{"task", "raedy", "-o", "table"}); code != exitUsage {
		t.Errorf("`task raedy` exit = %d, want %d", code, exitUsage)
	}
}
