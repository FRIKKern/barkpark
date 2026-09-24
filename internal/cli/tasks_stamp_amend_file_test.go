package cli

// tasks_stamp_amend_file_test.go — `bp task stamp --amend --amended-criterion-file`
// (task-f65368969b1a2471).
//
// THE DEFECT: the server has accepted a criterion-WORDING amendment since #19930
// (POST /v1/tasks/:doc_id/stamp with amend=true + amended_criterion + note), and
// its manifest prose tells the operator to pass the replacement wording with
// `--amended-criterion-file <path>`. No bp parser implemented that flag, so
// every binary — including one freshly built at origin/main — refused it with
// cli_manifest_drift and prescribed a reinstall that could not help: the code
// was missing, not stale.
//
// These tests drive the WHOLE verb (Execute → runTaskStamp → the POST → the
// read-back) against a fake server whose manifest carries the server's own
// prose, and assert the bytes the server receives.

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// amendStampManifest is minimalStampManifest plus the three flags the server
// declares for the amendment, with the --amended-criterion summary in the
// server's own words: it ADVERTISES --amended-criterion-file, which is what
// arms the drift refusal on a binary that does not implement it.
var amendStampManifest = strings.Replace(
	minimalStampManifest,
	`{"name": "note", "type": "string", "summary": "n"},`,
	`{"name": "note", "type": "string", "summary": "n"},
        {"name": "amend", "type": "bool", "summary": "AMEND a criterion whose WORDING turned out false."},
        {"name": "amended-criterion", "type": "string", "summary": "The REPLACEMENT wording for --amend. Pass it from a FILE — --amended-criterion-file <path> (or `+"`-`"+` for stdin) — never as an inline shell argument."},
        {"name": "observed-rev", "type": "string", "summary": "The doc rev you read."},`,
	1,
)

// amendCurrent / amendReplacement are criterion wording in the shape the ledger
// stores: MARKDOWN with backticked code spans and a $VAR — inert in a file,
// ACTIVE syntax inside a double-quoted shell argument.
const (
	amendCurrent     = "code is NOT on `origin/main` yet ($SHA pending)"
	amendReplacement = "code IS on `origin/main` as `941406d9f` — $SHA resolved,\nsecond line kept"
)

// amendServer is a fake Barkpark that records the stamp POST's raw query and
// body and, like the real server, replaces the criterion wording on an amend
// (met and evidence pinned).
type amendServer struct {
	mu       sync.Mutex
	criteria []map[string]any
	posts    int
	query    url.Values
	body     map[string]any
}

func (s *amendServer) start(t *testing.T) {
	t.Helper()
	be := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s.mu.Lock()
		defer s.mu.Unlock()
		switch {
		case r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/stamp"):
			s.posts++
			s.query = r.URL.Query()
			raw, _ := io.ReadAll(r.Body)
			s.body = map[string]any{}
			if len(raw) > 0 {
				_ = json.Unmarshal(raw, &s.body)
			}
			amended, _ := s.body["amended_criterion"].(string)
			if s.query.Get("amend") == "true" && strings.TrimSpace(amended) != "" {
				s.criteria[0]["criterion"] = amended
			}
			_, _ = w.Write([]byte(`{"ok":true,"doc":{"doc_id":"bp-task-r"},"help":[]}`))
		case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/v1/tasks/"):
			body, _ := json.Marshal(map[string]any{
				"ok": true,
				"doc": map[string]any{
					"doc_id":  "bp-task-r",
					"status":  "published",
					"content": map[string]any{"acceptance_criteria": s.criteria},
				},
			})
			_, _ = w.Write(body)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(be.Close)

	mf := filepath.Join(t.TempDir(), "manifest.json")
	if err := os.WriteFile(mf, []byte(amendStampManifest), 0o600); err != nil {
		t.Fatalf("write manifest: %v", err)
	}
	t.Setenv("BARKPARK_MANIFEST", mf)
	t.Setenv("BARKPARK_API_URL", be.URL)
	t.Setenv("BARKPARK_API_TOKEN", "stamp-amend-stub")
}

func sealedAmendRow() []map[string]any {
	return []map[string]any{{"criterion": amendCurrent, "met": true, "evidence": "PR #1 merged as abc123"}}
}

// writeJQFile writes text the way `jq -r … > file` does: with ONE trailing
// newline appended. The server's criterion-text CAS is byte-exact, so this is
// the trap the file door must survive.
func writeJQFile(t *testing.T, name, text string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(p, []byte(text+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

// TestTaskStampAmendedCriterionFileReachesTheWireAsAmendedCriterion is the
// named detector for the flag: remove --amended-criterion-file, or stop it
// reaching the POST as `amended_criterion`, and this reds. On unmodified code
// it reds with cli_manifest_drift and NOTHING is posted.
func TestTaskStampAmendedCriterionFileReachesTheWireAsAmendedCriterion(t *testing.T) {
	s := &amendServer{criteria: sealedAmendRow()}
	s.start(t)

	crit := writeJQFile(t, "crit.txt", amendCurrent)
	amended := writeJQFile(t, "amended.txt", amendReplacement)

	so, se := captureStreams(t, []string{
		"task", "stamp", "bp-task-r", "w", "1",
		"--criterion", "0", "--amend",
		"--amended-criterion-file", amended,
		"--criterion-text-file", crit,
		"--note", "the sentence asserted what origin/main refutes",
		"--observed-rev", "rev-abc",
		"-o", "json",
	})

	if strings.Contains(se, manifestFlagDriftCode) {
		t.Fatalf("bp still refuses --amended-criterion-file as manifest drift — the flag is documented and NOT implemented:\n%s", se)
	}
	if s.posts != 1 {
		t.Fatalf("expected exactly one stamp POST, got %d\nstdout:\n%s\nstderr:\n%s", s.posts, so, se)
	}
	if got := s.query["amend"]; len(got) != 1 || got[0] != "true" {
		t.Errorf("amend must reach the wire as amend=true, got query %v", s.query)
	}
	if got := s.query["observed-rev"]; len(got) != 1 || got[0] != "rev-abc" {
		t.Errorf("--observed-rev must reach the wire (the sealed-row fence), got query %v", s.query)
	}
	// Byte-exact, ONE trailing newline stripped, interior newline kept.
	if got := s.body["amended_criterion"]; got != amendReplacement {
		t.Errorf("amended_criterion on the wire = %q, want %q (body keys %v)", got, amendReplacement, stampBodyKeys(s.body))
	}
	if got := s.body["criterion_text"]; got != amendCurrent {
		t.Errorf("criterion_text on the wire = %q, want %q — the CAS is byte-exact", got, amendCurrent)
	}
	if got := s.body["note"]; got != "the sentence asserted what origin/main refutes" {
		t.Errorf("note on the wire = %q", got)
	}
	// Prose stays OFF the request line (the ~9.9 KB wall) and under ONE key.
	for _, k := range []string{"amended-criterion", "amended_criterion", "amendedCriterion"} {
		if _, inQuery := s.query[k]; inQuery {
			t.Errorf("replacement wording rode the QUERY as %q — prose belongs in the body", k)
		}
	}
	if _, camel := s.body["amendedCriterion"]; camel {
		t.Errorf("amendedCriterion is NO key to the server (it reads amended_criterion or amended-criterion)")
	}

	// End to end: the read-back must CONFIRM the amendment against the NEW
	// wording, not report the changed row as "a DIFFERENT criterion".
	doc := decodeOne(t, so)
	stamp, _ := doc["stamp"].(map[string]any)
	if stamp["confirmed"] != true {
		t.Fatalf("the amendment landed but the receipt did not confirm it: %v\nstderr:\n%s", stamp, se)
	}
}

// TestTaskStampAmendedCriterionFromStdin covers the `-` door.
func TestTaskStampAmendedCriterionFromStdin(t *testing.T) {
	s := &amendServer{criteria: sealedAmendRow()}
	s.start(t)
	orig := stampStdin
	t.Cleanup(func() { stampStdin = orig })
	stampStdin = strings.NewReader(amendReplacement + "\n")

	crit := writeJQFile(t, "crit.txt", amendCurrent)
	_, se := captureStreams(t, []string{
		"task", "stamp", "bp-task-r", "w", "1",
		"--criterion", "0", "--amend",
		"--amended-criterion-file", "-",
		"--criterion-text-file", crit,
		"--note", "why", "--observed-rev", "rev-abc",
	})
	if s.posts != 1 {
		t.Fatalf("expected one POST, got %d\nstderr:\n%s", s.posts, se)
	}
	if got := s.body["amended_criterion"]; got != amendReplacement {
		t.Errorf("stdin amended_criterion = %q, want %q", got, amendReplacement)
	}
}

// TestTaskStampBlankAmendedFileIsRefusedClientSide: blank replacement wording
// is refused BEFORE anything is sent, like an empty --criterion-text-file. The
// server refuses it too (400 invalid_stamp out of parse_stamp — String.trim,
// so whitespace-only counts as blank), and the client applies the same rule so
// a blank file never becomes a request.
func TestTaskStampBlankAmendedFileIsRefusedClientSide(t *testing.T) {
	for _, blank := range []string{"", "   \t"} {
		s := &amendServer{criteria: sealedAmendRow()}
		s.start(t)
		crit := writeJQFile(t, "crit.txt", amendCurrent)
		amended := writeJQFile(t, "amended.txt", blank)
		so, se := captureStreams(t, []string{
			"task", "stamp", "bp-task-r", "w", "1",
			"--criterion", "0", "--amend",
			"--amended-criterion-file", amended,
			"--criterion-text-file", crit,
			"--note", "why", "--observed-rev", "rev-abc",
		})
		if s.posts != 0 {
			t.Fatalf("a blank amended file (%q) was POSTED — it must be refused client-side", blank)
		}
		// The refusal rides stdout as a JSON error under a pipe, stderr otherwise.
		if both := so + se; !strings.Contains(both, "amended_criterion_source") || !strings.Contains(both, "is blank") {
			t.Errorf("blank amended file (%q) refusal does not name itself:\n%s", blank, both)
		}
	}
}

// TestAmendedCriterionFileNewlineHandling pins the byte-exact rule and that it
// is the SAME rule the criterion-text file uses: exactly one trailing newline
// (with a preceding CR) is stripped, interior newlines survive.
func TestAmendedCriterionFileNewlineHandling(t *testing.T) {
	multi := "first line\n\nthird, with a `code span` and $VAR"
	for _, tc := range []struct{ name, written, want string }{
		{"no trailing newline", multi, multi},
		{"one trailing newline (jq -r > file)", multi + "\n", multi},
		{"crlf", multi + "\r\n", multi},
		{"two trailing newlines keep one", multi + "\n\n", multi + "\n"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			a := filepath.Join(dir, "amended.txt")
			c := filepath.Join(dir, "crit.txt")
			for _, p := range []string{a, c} {
				if err := os.WriteFile(p, []byte(tc.written), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			tail, err := resolveCriterionTextFile([]string{"--criterion-text-file", c, "--amended-criterion-file", a})
			if err != nil {
				t.Fatal(err)
			}
			tail, err = resolveAmendedCriterionFile(tail)
			if err != nil {
				t.Fatal(err)
			}
			if !containsExact(tail, "--amended-criterion="+tc.want) {
				t.Fatalf("amended: want %q, got %q", tc.want, tail)
			}
			// Consistency: the same bytes on disk give the same text on both
			// sides of the amendment's CAS.
			if !containsExact(tail, "--criterion-text="+tc.want) {
				t.Fatalf("criterion-text and amended-criterion diverged on the same bytes: %q", tail)
			}
		})
	}
}

// TestAmendedCriterionFileRefusals: every misuse fails loudly and forwards
// nothing.
func TestAmendedCriterionFileRefusals(t *testing.T) {
	dir := t.TempDir()
	good := filepath.Join(dir, "a.txt")
	if err := os.WriteFile(good, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	blank := filepath.Join(dir, "blank.txt")
	if err := os.WriteFile(blank, []byte(" \n"), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name string
		tail []string
		want string
	}{
		{"both doors", []string{"--amended-criterion", "x", "--amended-criterion-file", good}, "not both"},
		{"no path", []string{"--amended-criterion-file", "--note"}, "needs a path"},
		{"empty inline path", []string{"--amended-criterion-file="}, "empty path"},
		{"missing file", []string{"--amended-criterion-file", filepath.Join(dir, "nope")}, "reading the replacement criterion wording from"},
		{"blank file", []string{"--amended-criterion-file", blank}, "is blank"},
		{"passed twice", []string{"--amended-criterion-file", good, "--amended-criterion-file", good}, "passed twice"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := resolveAmendedCriterionFile(tc.tail)
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("want refusal containing %q, got err=%v tail=%q", tc.want, err, got)
			}
			if got != nil {
				t.Fatalf("a refusal forwarded a tail: %q", got)
			}
		})
	}
}

// TestStampStdinClaimedTwice: one stdin cannot feed both text doors.
func TestStampStdinClaimedTwice(t *testing.T) {
	if !stampStdinClaimedTwice([]string{"--criterion-text-file", "-", "--amended-criterion-file=-"}) {
		t.Error("both doors on stdin was not detected")
	}
	if stampStdinClaimedTwice([]string{"--criterion-text-file", "c.txt", "--amended-criterion-file", "-"}) {
		t.Error("control: one door on stdin is fine")
	}
}

// TestAmendedCriterionRidesTheBodyAsSnakeCase pins the key the server reads.
func TestAmendedCriterionRidesTheBodyAsSnakeCase(t *testing.T) {
	cmd := stampCmd()
	if !commandFlagBelongsInBody(cmd, "amended-criterion") {
		t.Error("amended-criterion is criterion prose and must ride the BODY, not the request line")
	}
	if got := stampBodyKey2(cmd, "amended-criterion"); got != "amended_criterion" {
		t.Errorf("stampBodyKey2(task.stamp, amended-criterion) = %q, want amended_criterion", got)
	}
}

// TestAmendedCriterionFileIsNoLongerManifestDrift: the resolved tail passes
// the parser against the server-shaped manifest; the CONTROL shows the same
// unresolved tail still trips the drift refusal, so the assertion discriminates.
func TestAmendedCriterionFileIsNoLongerManifestDrift(t *testing.T) {
	m, err := manifest.Parse([]byte(amendStampManifest))
	if err != nil {
		t.Fatal(err)
	}
	cmd := m.Commands[0]
	path := writeJQFile(t, "amended.txt", "new wording")
	raw := []string{"task-1", "w", "1", "--criterion", "0", "--amend", "--amended-criterion-file", path, "--note", "why"}

	if _, _, err := splitArgs(cmd, raw); err == nil || !strings.Contains(err.Error(), manifestFlagDriftCode) {
		t.Fatalf("control: the unresolved flag should still be drift to the bare parser, got %v", err)
	}
	resolved, err := resolveAmendedCriterionFile(append([]string(nil), raw...))
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := splitArgs(cmd, resolved); err != nil {
		t.Fatalf("the resolved --amended-criterion-file is still refused: %v", err)
	}
}
