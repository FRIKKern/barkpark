package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// THE DETECTOR for the held-file half of task-f79e39f4992749a5: an append that
// does not land must FAIL LOUD at claim time. Revert recordHeldClaim's readback
// and TestHeldFileReadbackCatchesAnAppendThatDidNotLand goes green-on-nothing —
// which is why the mutation twin below asserts the readback is what catches it.
func TestRecordHeldClaimAppendsAndReadsBack(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "held.lead-cli-s8.txt")

	if err := recordHeldClaim(path, "task-f0e49432f1653c2f"); err != nil {
		t.Fatalf("recordHeldClaim: %v", err)
	}
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read back: %v", err)
	}
	if !strings.Contains(string(b), "task-f0e49432f1653c2f") {
		t.Fatalf("held file does not contain the claimed id; got %q", b)
	}
}

// IDEMPOTENT. A lease renewal re-claims the same row; the pulse loop must not
// then pulse it twice, and the file must not grow without bound.
func TestRecordHeldClaimIsIdempotent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "held.txt")
	for i := 0; i < 3; i++ {
		if err := recordHeldClaim(path, "task-aaa"); err != nil {
			t.Fatalf("pass %d: %v", i, err)
		}
	}
	b, _ := os.ReadFile(path)
	if n := strings.Count(string(b), "task-aaa"); n != 1 {
		t.Fatalf("id written %d times, want 1; file=%q", n, b)
	}
}

// THE MUTATION TWIN. Disarm the write by pointing the held file at a path whose
// parent does not exist: the append cannot land, and the claim must be told so
// rather than reporting a protected claim it did not protect. Without the
// readback (or the append's own error) this returns nil and the lease lapses
// silently — the measured failure on task-f0e49432f1653c2f.
func TestRecordHeldClaimFailsLoudWhenTheAppendCannotLand(t *testing.T) {
	path := filepath.Join(t.TempDir(), "no-such-dir", "held.txt")
	err := recordHeldClaim(path, "task-aaa")
	if err == nil {
		t.Fatal("recordHeldClaim returned nil for a held file it could not write — an unprotected claim reported as protected")
	}
	if !strings.Contains(err.Error(), "task-aaa") || !strings.Contains(err.Error(), path) {
		t.Fatalf("error names neither the id nor the file: %v", err)
	}
}

// POSITIVE CONTROL for the readback itself: the append is skipped (the id is
// already there) and the readback still has to prove it. A file that is
// truncated between the two must be caught, not assumed.
func TestHeldFileHasIgnoresCommentsAndBlanks(t *testing.T) {
	path := filepath.Join(t.TempDir(), "held.txt")
	os.WriteFile(path, []byte("\n# a comment\ntask-bbb   # held since 08:00Z\n"), 0o644)

	got, err := heldFileHas(path, "task-bbb")
	if err != nil || !got {
		t.Fatalf("commented line not matched: got=%v err=%v", got, err)
	}
	// The control: a line that is ONLY a comment must not match its own text.
	if got, _ := heldFileHas(path, "a"); got {
		t.Fatal("a comment body matched as a doc id")
	}
	if got, _ := heldFileHas(path, "task-zzz"); got {
		t.Fatal("an id absent from the file was reported present")
	}
}

// THE SESSION KEY is ENTROPY, not a label (task-f79e39f4992749a5 criterion 0's
// negative arm). Two sessions that each mint must get DIFFERENT keys with no
// coordination, and one session must get the SAME key on every call, or the
// stored `claim.session` stops discriminating.
func TestSessionKeyMintsOncePerFileAndDiffersAcrossFiles(t *testing.T) {
	dir := t.TempDir()
	a1 := sessionKeyFromFile(filepath.Join(dir, "a", "session.key"))
	a2 := sessionKeyFromFile(filepath.Join(dir, "a", "session.key"))
	b1 := sessionKeyFromFile(filepath.Join(dir, "b", "session.key"))

	if a1 == "" || len(a1) != 32 {
		t.Fatalf("minted key %q is not 32 hex chars — a short or empty key is not entropy", a1)
	}
	if a1 != a2 {
		t.Fatalf("one session got two keys (%q then %q): its writes would look like two sessions", a1, a2)
	}
	if a1 == b1 {
		t.Fatalf("two sessions minted the SAME key %q — this is the lane-scoped collision, reproduced", a1)
	}
	if fi, err := os.Stat(filepath.Join(dir, "a", "session.key")); err != nil {
		t.Fatalf("key file not persisted: %v", err)
	} else if fi.Mode().Perm() != 0o600 {
		t.Fatalf("key file mode %v, want 0600 — the key is a credential", fi.Mode().Perm())
	}
}

// An explicit key wins, so a supervisor can hand a restarted process the same
// identity on purpose. This is the ONE sanctioned client-chosen value, and the
// moduledoc says why it is not the default.
func TestSessionKeyHonoursAnExplicitEnvKey(t *testing.T) {
	t.Setenv("BARKPARK_SESSION_KEY", "  pinned-by-supervisor  ")
	if got := resolveSessionKey(); got != "pinned-by-supervisor" {
		t.Fatalf("resolveSessionKey() = %q, want the trimmed explicit key", got)
	}
}
