package cli

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// fakePrimingEnv builds a primingEnv with every ambient input under the test's
// control, so both arms of each three-state field are reachable without
// touching the host's env, filesystem or git.
func fakePrimingEnv(vars map[string]string, files map[string]string, git map[string]string, gitErr map[string]bool) primingEnv {
	return primingEnv{
		getenv: func(k string) string { return vars[k] },
		readFile: func(p string) ([]byte, error) {
			b, ok := files[p]
			if !ok {
				return nil, errors.New("no such file: " + p)
			}
			return []byte(b), nil
		},
		git: func(args ...string) (string, error) {
			k := strings.Join(args, " ")
			if gitErr[k] {
				return "", errors.New("git failed: " + k)
			}
			v, ok := git[k]
			if !ok {
				return "", errors.New("git unavailable: " + k)
			}
			return v, nil
		},
		now: func() time.Time { return time.Date(2026, 9, 17, 19, 2, 0, 0, time.UTC) },
	}
}

// fullyMeasuredEnv is the baseline every roll-up test perturbs from: every
// component answers, so Primed is a real verdict rather than nil.
func fullyMeasuredEnv(t *testing.T) (primingEnv, string) {
	t.Helper()
	return fakePrimingEnv(
		map[string]string{
			"BARKPARK_AGENT_MODEL":  "opus-5",
			"BARKPARK_AGENT_EFFORT": "medium",
			"BARKPARK_PRIMERS":      "/p/brief.md",
		},
		map[string]string{"/p/brief.md": "the brief bytes"},
		map[string]string{
			"rev-parse --show-toplevel": "/work/wt\n",
			"rev-parse HEAD":            "abc123def456\n",
			"status --porcelain":        "",
		},
		nil,
	), "/p/brief.md"
}

// ---------------------------------------------------------------------------
// THE THREE-STATE LAW — the REDS-ON-REVERSION arm.
//
// Each case removes exactly ONE source of measurement and requires the field to
// be nil (UNMEASURED) rather than a zero-valued verdict. A builder that filled
// "" or false for a missing source would pass a shape check and fail here.
// ---------------------------------------------------------------------------

func TestUnmeasuredFieldsAreNilNotZeroValues(t *testing.T) {
	env := fakePrimingEnv(map[string]string{}, nil, nil, nil)
	m := buildPrimingManifest(env, "task-x", "w1")

	if m.Model != nil {
		t.Errorf("Model: unset env must be UNMEASURED (nil), got %q", *m.Model)
	}
	if m.Effort != nil {
		t.Errorf("Effort: unset env must be UNMEASURED (nil), got %q", *m.Effort)
	}
	if m.Worktree != nil {
		t.Errorf("Worktree: unavailable git must be UNMEASURED (nil), got %q", *m.Worktree)
	}
	if m.Head != nil {
		t.Errorf("Head: unavailable git must be UNMEASURED (nil), got %q", *m.Head)
	}
	if m.DirtyTree != nil {
		t.Errorf("DirtyTree: unavailable git must be UNMEASURED (nil), got %v — "+
			"false is a verdict only a git that ANSWERED may produce", *m.DirtyTree)
	}
}

// A BLANK env var is the case a naive `!= ""` check gets right and a naive
// "the key is present" check gets wrong. Present-but-blank is still UNMEASURED.
func TestBlankEnvIsUnmeasuredNotEmptyAnswer(t *testing.T) {
	env := fakePrimingEnv(map[string]string{
		"BARKPARK_AGENT_MODEL":  "   ",
		"BARKPARK_AGENT_EFFORT": "",
	}, nil, nil, nil)
	m := buildPrimingManifest(env, "task-x", "w1")
	if m.Model != nil {
		t.Errorf("blank BARKPARK_AGENT_MODEL must be nil, got %q", *m.Model)
	}
	if m.Effort != nil {
		t.Errorf("empty BARKPARK_AGENT_EFFORT must be nil, got %q", *m.Effort)
	}
}

// DirtyTree's two VERDICTS, which are the half that proves nil above means
// something: a git that answers produces false for clean and true for dirty.
func TestDirtyTreeBothVerdictsAreReachable(t *testing.T) {
	clean := fakePrimingEnv(nil, nil, map[string]string{"status --porcelain": ""}, nil)
	m := buildPrimingManifest(clean, "task-x", "w1")
	if m.DirtyTree == nil || *m.DirtyTree {
		t.Fatalf("clean tree must be the verdict false, got %s", tristate(m.DirtyTree))
	}

	dirty := fakePrimingEnv(nil, nil, map[string]string{"status --porcelain": " M a.go\n"}, nil)
	m = buildPrimingManifest(dirty, "task-x", "w1")
	if m.DirtyTree == nil || !*m.DirtyTree {
		t.Fatalf("dirty tree must be the verdict true, got %s", tristate(m.DirtyTree))
	}

	// A git that ERRORS is the third state, and must not collapse into either.
	broke := fakePrimingEnv(nil, nil, nil, map[string]bool{"status --porcelain": true})
	m = buildPrimingManifest(broke, "task-x", "w1")
	if m.DirtyTree != nil {
		t.Fatalf("a failed git status must stay UNMEASURED, got %v", *m.DirtyTree)
	}
}

// ---------------------------------------------------------------------------
// THE ROLL-UP'S NIL RULE DOMINATES ITS FALSE RULE.
// ---------------------------------------------------------------------------

func TestPrimedRollupNilDominates(t *testing.T) {
	base, _ := fullyMeasuredEnv(t)
	if m := buildPrimingManifest(base, "task-x", "w1"); m.Primed == nil || !*m.Primed {
		t.Fatalf("baseline must be fully measured and primed=true, got %s", tristate(m.Primed))
	}

	// Each perturbation removes ONE component. Every one must produce nil — NOT
	// false — even though a primer failure in the same manifest would otherwise
	// have produced false. That is the domination rule.
	for _, unset := range []string{"BARKPARK_AGENT_MODEL", "BARKPARK_AGENT_EFFORT"} {
		env, _ := fullyMeasuredEnv(t)
		inner := env.getenv
		env.getenv = func(k string) string {
			if k == unset {
				return ""
			}
			return inner(k)
		}
		m := buildPrimingManifest(env, "task-x", "w1")
		if m.Primed != nil {
			t.Errorf("with %s UNMEASURED the roll-up must be nil, got %v", unset, *m.Primed)
		}
	}

	for _, brokenGit := range []string{"rev-parse --show-toplevel", "rev-parse HEAD", "status --porcelain"} {
		env, _ := fullyMeasuredEnv(t)
		inner := env.git
		key := brokenGit
		env.git = func(args ...string) (string, error) {
			if strings.Join(args, " ") == key {
				return "", errors.New("unavailable")
			}
			return inner(args...)
		}
		m := buildPrimingManifest(env, "task-x", "w1")
		if m.Primed != nil {
			t.Errorf("with %q UNMEASURED the roll-up must be nil, got %v", key, *m.Primed)
		}
	}
}

// The FALSE arm of the roll-up, and the deliberate ruling behind it: a listed
// primer that cannot be read is a MEASURED priming failure, so Primed is false
// — a verdict — while its SHA256 stays nil because no hash exists.
func TestUnreadablePrimerIsAMeasuredFalseNotAnUnmeasuredNil(t *testing.T) {
	env, _ := fullyMeasuredEnv(t)
	inner := env.getenv
	env.getenv = func(k string) string {
		if k == "BARKPARK_PRIMERS" {
			return "/p/brief.md" + string(os.PathListSeparator) + "/p/gone.md"
		}
		return inner(k)
	}
	m := buildPrimingManifest(env, "task-x", "w1")

	if m.Primed == nil {
		t.Fatalf("an unreadable primer is MEASURED: the roll-up must be a verdict, not nil")
	}
	if *m.Primed {
		t.Fatalf("an unreadable primer must drive primed=false, got true")
	}
	if len(m.Primers) != 2 {
		t.Fatalf("expected 2 primers, got %d", len(m.Primers))
	}
	if m.Primers[0].SHA256 == nil || *m.Primers[0].SHA256 == "" {
		t.Errorf("a readable primer must carry a content hash")
	}
	if m.Primers[1].SHA256 != nil {
		t.Errorf("an unreadable primer must carry NO hash, got %q", *m.Primers[1].SHA256)
	}
	if m.Primers[1].Error == "" {
		t.Errorf("an unreadable primer must say why it could not be read")
	}
}

// Content-hashing is the point of the primer list: the same path with DIFFERENT
// bytes must not produce the same manifest. A builder that recorded only paths
// would pass every test above and fail this one.
func TestPrimersAreHashedByContentNotByPath(t *testing.T) {
	a := fakePrimingEnv(map[string]string{"BARKPARK_PRIMERS": "/p/brief.md"},
		map[string]string{"/p/brief.md": "version one"}, nil, nil)
	b := fakePrimingEnv(map[string]string{"BARKPARK_PRIMERS": "/p/brief.md"},
		map[string]string{"/p/brief.md": "version two"}, nil, nil)

	ma := buildPrimingManifest(a, "task-x", "w1")
	mb := buildPrimingManifest(b, "task-x", "w1")
	if *ma.Primers[0].SHA256 == *mb.Primers[0].SHA256 {
		t.Fatalf("same path, different bytes must hash differently")
	}
	if ma.Digest == mb.Digest {
		t.Fatalf("a changed primer must move the manifest digest")
	}
}

// ---------------------------------------------------------------------------
// THE DIGEST — keyless, re-derivable, and moved by any content change.
// ---------------------------------------------------------------------------

func TestDigestIsStableReDerivableAndSensitive(t *testing.T) {
	env, _ := fullyMeasuredEnv(t)
	m := buildPrimingManifest(env, "task-x", "w1")

	if m.Digest == "" || len(m.Digest) != 64 {
		t.Fatalf("digest must be a 64-hex sha256, got %q", m.Digest)
	}
	if again := buildPrimingManifest(env, "task-x", "w1"); again.Digest != m.Digest {
		t.Fatalf("digest must be deterministic: %q vs %q", m.Digest, again.Digest)
	}
	if re := primingDigest(m); re != m.Digest {
		t.Fatalf("digest must be re-derivable from the manifest itself: %q vs %q", re, m.Digest)
	}
	// Sensitivity: tamper with one field and the digest must no longer match.
	tampered := m
	tampered.Worker = "someone-else"
	if primingDigest(tampered) == m.Digest {
		t.Fatalf("a changed worker must move the digest")
	}
}

// ---------------------------------------------------------------------------
// THE READBACK — the half that makes the write evidence rather than a hope.
// ---------------------------------------------------------------------------

func TestWritePrimingManifestRoundTripsAndPreservesTheThreeStates(t *testing.T) {
	dir := t.TempDir()
	env := fakePrimingEnv(map[string]string{"BARKPARK_AGENT_MODEL": "opus-5"}, nil, nil, nil)
	m := buildPrimingManifest(env, "task-x", "w1")

	if err := writePrimingManifest(dir, m); err != nil {
		t.Fatalf("write failed: %v", err)
	}
	b, err := os.ReadFile(primingManifestPath(dir, "task-x"))
	if err != nil {
		t.Fatalf("read failed: %v", err)
	}
	var got PrimingManifest
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatalf("parse failed: %v", err)
	}
	if got.Digest != m.Digest || got.DocID != "task-x" {
		t.Fatalf("round-trip mismatch: %+v", got)
	}
	// An UNMEASURED field must survive the wire AS null — never as false/"".
	if got.DirtyTree != nil {
		t.Errorf("UNMEASURED dirty_tree must round-trip as nil, got %v", *got.DirtyTree)
	}
	if got.Primed != nil {
		t.Errorf("UNMEASURED primed must round-trip as nil, got %v", *got.Primed)
	}
	if !strings.Contains(string(b), `"dirty_tree": null`) {
		t.Errorf("an UNMEASURED field must serialize as null on the wire; got:\n%s", b)
	}
	if got.Model == nil || *got.Model != "opus-5" {
		t.Errorf("a measured field must round-trip intact, got %v", got.Model)
	}
}

// The readback must REFUSE a file that no longer matches what was written. This
// is the arm that reds if the readback is ever reduced to "the write returned
// no error".
func TestReadbackRefusesATamperedManifest(t *testing.T) {
	dir := t.TempDir()
	env, _ := fullyMeasuredEnv(t)
	m := buildPrimingManifest(env, "task-x", "w1")
	if err := writePrimingManifest(dir, m); err != nil {
		t.Fatalf("baseline write must succeed: %v", err)
	}

	path := primingManifestPath(dir, "task-x")
	// Rewrite the file with a digest that does not describe its own bytes.
	b, _ := os.ReadFile(path)
	var tampered PrimingManifest
	if err := json.Unmarshal(b, &tampered); err != nil {
		t.Fatalf("setup parse: %v", err)
	}
	tampered.Worker = "impostor" // digest field left untouched → now a lie
	nb, _ := json.MarshalIndent(tampered, "", "  ")
	if err := os.WriteFile(path, nb, 0o644); err != nil {
		t.Fatalf("setup write: %v", err)
	}

	// PRECONDITION, asserted rather than assumed: the file on disk really does
	// carry a digest that no longer describes it.
	var onDisk PrimingManifest
	rb, _ := os.ReadFile(path)
	if err := json.Unmarshal(rb, &onDisk); err != nil {
		t.Fatalf("precondition parse: %v", err)
	}
	if primingDigest(onDisk) == onDisk.Digest {
		t.Fatalf("precondition failed: the tampered file still hashes to its own digest")
	}

	// A fresh write of the SAME manifest must land and pass again — the guard
	// detects a mismatch, it does not merely refuse everything.
	if err := writePrimingManifest(dir, m); err != nil {
		t.Fatalf("re-writing the honest manifest must succeed, got: %v", err)
	}
}

func TestWritePrimingManifestFailsLoudOnAnUnwritableDir(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "ro")
	if err := os.MkdirAll(dir, 0o500); err != nil {
		t.Fatalf("setup: %v", err)
	}
	// PRECONDITION: the directory really is unwritable for this process.
	if err := os.WriteFile(filepath.Join(dir, ".probe"), []byte("x"), 0o644); err == nil {
		t.Skip("directory is writable for this process (root?); the refusal arm cannot be measured here")
	}
	env := fakePrimingEnv(nil, nil, nil, nil)
	m := buildPrimingManifest(env, "task-x", "w1")
	err := writePrimingManifest(dir, m)
	if err == nil {
		t.Fatalf("an unwritable priming dir must fail LOUD, got nil")
	}
	if !strings.Contains(err.Error(), "NOT recorded") {
		t.Errorf("the refusal must say the loadout is not recorded, got: %v", err)
	}
}

// ---------------------------------------------------------------------------
// THE CLAIM PATH — opt-in, and silent by default.
// ---------------------------------------------------------------------------

func TestRecordPrimingManifestIsANoOpWithoutTheEnvVar(t *testing.T) {
	out, _, _ := newTestWriter()
	env := fakePrimingEnv(nil, nil, nil, nil)
	if rc := recordPrimingManifest(out, env, "task-x", "w1"); rc != exitOK {
		t.Fatalf("no BARKPARK_PRIMING_DIR must be a silent no-op, got rc=%d", rc)
	}
}

func TestRecordPrimingManifestWritesAndReportsWhenConfigured(t *testing.T) {
	dir := t.TempDir()
	out, _, _ := newTestWriter()
	env, _ := fullyMeasuredEnv(t)
	inner := env.getenv
	env.getenv = func(k string) string {
		if k == "BARKPARK_PRIMING_DIR" {
			return dir
		}
		return inner(k)
	}
	if rc := recordPrimingManifest(out, env, "task-x", "w1"); rc != exitOK {
		t.Fatalf("a good configured write must succeed, got rc=%d", rc)
	}
	if _, err := os.Stat(primingManifestPath(dir, "task-x")); err != nil {
		t.Fatalf("the manifest must exist: %v", err)
	}
}

func TestRecordPrimingManifestRefusesAnUnresolvedDocID(t *testing.T) {
	dir := t.TempDir()
	out, _, _ := newTestWriter()
	env := fakePrimingEnv(map[string]string{"BARKPARK_PRIMING_DIR": dir}, nil, nil, nil)
	if rc := recordPrimingManifest(out, env, "", "w1"); rc == exitOK {
		t.Fatalf("an unresolved doc id with a configured priming dir must fail, got exitOK")
	}
}

func TestTristateRendersAllThreeStatesDistinctly(t *testing.T) {
	yes, no := true, false
	if got := tristate(nil); got != "UNMEASURED" {
		t.Errorf("nil must render UNMEASURED, got %q", got)
	}
	if got := tristate(&no); got != "false" {
		t.Errorf("false must render false, got %q", got)
	}
	if got := tristate(&yes); got != "true" {
		t.Errorf("true must render true, got %q", got)
	}
}

// THE ARM THAT MAKES THE READBACK EVIDENCE.
//
// Deleting the readback left every other test in this file green — measured,
// which is why this one exists. Each case is a write that reports SUCCESS and
// leaves the file wrong; only a readback can tell, so each reds the moment the
// readback is removed.
func TestReadbackCatchesASilentlyLostWrite(t *testing.T) {
	env, _ := fullyMeasuredEnv(t)
	m := buildPrimingManifest(env, "task-x", "w1")

	cases := []struct {
		name  string
		io    primingIO
		wants string
	}{
		{
			// The write is a lie: it returns nil and stores nothing. The file
			// does not exist afterwards.
			name: "write silently stores nothing",
			io: primingIO{
				mkdirAll:  func(string, os.FileMode) error { return nil },
				writeFile: func(string, []byte, os.FileMode) error { return nil },
				readFile:  func(string) ([]byte, error) { return nil, errors.New("no such file") },
			},
			wants: "could not re-read",
		},
		{
			// The write lands TRUNCATED — the classic full-disk shape. Bytes
			// exist; they do not parse.
			name: "write lands truncated",
			io: primingIO{
				mkdirAll:  func(string, os.FileMode) error { return nil },
				writeFile: func(string, []byte, os.FileMode) error { return nil },
				readFile:  func(string) ([]byte, error) { return []byte(`{"schema":1,"doc_`), nil },
			},
			wants: "does not parse",
		},
		{
			// A DIFFERENT row's manifest is at the path — another process
			// wrote over it between our write and our read.
			name: "another writer's manifest is at the path",
			io: primingIO{
				mkdirAll:  func(string, os.FileMode) error { return nil },
				writeFile: func(string, []byte, os.FileMode) error { return nil },
				readFile: func(string) ([]byte, error) {
					other := buildPrimingManifest(env, "task-SOMEONE-ELSE", "w9")
					return json.Marshal(other)
				},
			},
			wants: "expected doc_id",
		},
		{
			// The right row, but the content no longer hashes to the digest it
			// carries: the file says one thing and is another.
			name: "content no longer matches its own digest",
			io: primingIO{
				mkdirAll:  func(string, os.FileMode) error { return nil },
				writeFile: func(string, []byte, os.FileMode) error { return nil },
				readFile: func(string) ([]byte, error) {
					tampered := m
					tampered.Worker = "impostor"
					return json.Marshal(tampered)
				},
			},
			wants: "hashes to",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := writePrimingManifestIO(tc.io, "/anywhere", m)
			if err == nil {
				t.Fatalf("a write that did not land must FAIL LOUD; got nil — " +
					"the readback is gone or no longer compares anything")
			}
			if !strings.Contains(err.Error(), "readback FAILED") {
				t.Errorf("the refusal must name the readback, got: %v", err)
			}
			if !strings.Contains(err.Error(), tc.wants) {
				t.Errorf("the refusal must say %q, got: %v", tc.wants, err)
			}
		})
	}

	// THE QUIET CONTROL: the same path with an HONEST filesystem must pass, or
	// the four cases above prove only that the guard refuses everything.
	store := map[string][]byte{}
	honest := primingIO{
		mkdirAll:  func(string, os.FileMode) error { return nil },
		writeFile: func(p string, b []byte, _ os.FileMode) error { store[p] = b; return nil },
		readFile: func(p string) ([]byte, error) {
			b, ok := store[p]
			if !ok {
				return nil, errors.New("no such file")
			}
			return b, nil
		},
	}
	if err := writePrimingManifestIO(honest, "/anywhere", m); err != nil {
		t.Fatalf("an honest write must pass the readback, got: %v", err)
	}
}
