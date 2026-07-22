package cli

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync/atomic"
	"testing"
)

// --- pure-function mutation-proofs -------------------------------------------

// parseStampArgs must NEVER re-index --criterion (the index a builder types is
// the index the server receives) and must strip ONLY the CLI-only
// --merge-gated, forwarding every other token in order. A mutation that
// shifted the index, or that leaked --merge-gated into the forwarded tail
// (which the server does not declare → splitArgs "unknown flag"), reds here.
func TestParseStampArgs_StripsMergeGatedForwardsRestVerbatim(t *testing.T) {
	tail := []string{
		"bp-task-x", "worker-1", "2",
		"--criterion", "3", "--met", "--evidence", "gate green",
		"--criterion-text", "some row", "--merge-gated",
	}
	sa, forward := parseStampArgs(tail)

	if sa.criterion == nil || *sa.criterion != 3 {
		t.Fatalf("criterion = %v, want 3 (no re-index)", sa.criterion)
	}
	if !sa.met || sa.miss {
		t.Errorf("met/miss = %v/%v, want met", sa.met, sa.miss)
	}
	if sa.criterionText != "some row" {
		t.Errorf("criterionText = %q, want %q", sa.criterionText, "some row")
	}
	if !sa.mergeGated {
		t.Errorf("mergeGated not parsed")
	}
	want := []string{
		"bp-task-x", "worker-1", "2",
		"--criterion", "3", "--met", "--evidence", "gate green",
		"--criterion-text", "some row",
	}
	if !reflect.DeepEqual(forward, want) {
		t.Errorf("forward = %v\n want %v (only --merge-gated stripped, order kept)", forward, want)
	}
	for _, tok := range forward {
		if tok == "--merge-gated" {
			t.Fatalf("--merge-gated leaked into the forwarded tail")
		}
	}
}

// The `--flag=value` inline spelling must parse identically to the space form.
func TestParseStampArgs_InlineForms(t *testing.T) {
	sa, forward := parseStampArgs([]string{"--criterion=5", "--criterion-text=inline row", "--met=true"})
	if sa.criterion == nil || *sa.criterion != 5 {
		t.Fatalf("criterion = %v, want 5", sa.criterion)
	}
	if sa.criterionText != "inline row" {
		t.Errorf("criterionText = %q, want %q", sa.criterionText, "inline row")
	}
	if !sa.met {
		t.Errorf("--met=true should set met")
	}
	// Nothing CLI-only here → forward is byte-identical to input.
	if !reflect.DeepEqual(forward, []string{"--criterion=5", "--criterion-text=inline row", "--met=true"}) {
		t.Errorf("forward mangled inline tail: %v", forward)
	}
}

// The echo is the whole point of the 0-based decision: it must TRANSLATE the
// 0-based index a script passes into the 1-based position a builder SEES on the
// board, so a 1-vs-0 slip is caught at the stamp. A mutation that dropped the
// translation (printed the raw index as the human number) or shifted it reds.
func TestStampEchoLine_TranslatesZeroToOneBased(t *testing.T) {
	cases := []struct {
		idx      int
		met      bool
		miss     bool
		text     string
		wantSubs []string
	}{
		{idx: 0, met: true, text: "first row", wantSubs: []string{"index 0 (0-based)", "criterion #1", "met", `"first row"`}},
		{idx: 6, met: true, text: "[MERGE-GATED — the lead closes this]", wantSubs: []string{"index 6 (0-based)", "criterion #7", "met"}},
		{idx: 2, miss: true, text: "third row", wantSubs: []string{"index 2 (0-based)", "criterion #3", "miss"}},
	}
	for _, c := range cases {
		idx := c.idx
		line := stampEchoLine(stampArgs{criterion: &idx, met: c.met, miss: c.miss, criterionText: c.text})
		for _, sub := range c.wantSubs {
			if !strings.Contains(line, sub) {
				t.Errorf("echo for idx=%d missing %q; got %q", c.idx, sub, line)
			}
		}
	}
}

// No index → no echo (the manifest dispatch then produces the normal usage error).
func TestStampEchoLine_NoCriterionEmpty(t *testing.T) {
	if got := stampEchoLine(stampArgs{met: true, criterionText: "x"}); got != "" {
		t.Errorf("echo with no criterion = %q, want empty", got)
	}
}

// The MERGE-GATED tripwire: a --met on a lead-owned row without --merge-gated
// is blocked; the override releases it; a --miss never blocks; a plain row is
// untouched. Tolerant of case and of a hyphen or space between the words.
func TestStampMergeGateBlocked(t *testing.T) {
	cases := []struct {
		name string
		sa   stampArgs
		want bool
	}{
		{"met+marker+no override → blocked", stampArgs{met: true, criterionText: "row [MERGE-GATED — the lead closes this]"}, true},
		{"met+marker+override → allowed", stampArgs{met: true, mergeGated: true, criterionText: "row [MERGE-GATED]"}, false},
		{"miss+marker → never blocked", stampArgs{miss: true, criterionText: "row MERGE-GATED"}, false},
		{"met+plain row → allowed", stampArgs{met: true, criterionText: "a normal acceptance criterion"}, false},
		{"lowercase marker still blocks", stampArgs{met: true, criterionText: "row merge-gated by the lead"}, true},
		{"space variant still blocks", stampArgs{met: true, criterionText: "this is MERGE GATED"}, true},
	}
	for _, c := range cases {
		if got := stampMergeGateBlocked(c.sa); got != c.want {
			t.Errorf("%s: blocked = %v, want %v", c.name, got, c.want)
		}
	}
}

// --- Execute-level wiring proofs ---------------------------------------------

// minimalStampManifest is a self-contained manifest carrying ONLY the
// `task stamp` verb (with the D56 --criterion-text flag the shared fixture
// still lacks), so the Execute path can be driven against a fake server without
// depending on the repo-wide fixture.
const minimalStampManifest = `{
  "manifest_version": "test",
  "server": {"name": "test", "version": "0", "base_url": "http://example.invalid"},
  "auth_tier": "read",
  "nouns": [{"name": "task", "summary": "tasks"}],
  "commands": [
    {
      "id": "task.stamp", "noun": "task", "verb": "stamp", "summary": "stamp",
      "http": {"method": "POST", "path_template": "/v1/tasks/:doc_id/stamp"},
      "auth_tier": "read",
      "args": [
        {"name": "doc_id", "required": true, "type": "string", "summary": "id"},
        {"name": "worker_id", "required": true, "type": "string", "summary": "w"},
        {"name": "observed_epoch", "required": true, "type": "int", "summary": "e"}
      ],
      "flags": [
        {"name": "criterion", "type": "int", "summary": "idx"},
        {"name": "criterion-text", "type": "string", "summary": "text"},
        {"name": "met", "type": "bool", "summary": "m"},
        {"name": "evidence", "type": "string", "summary": "ev"},
        {"name": "miss", "type": "bool", "summary": "x"},
        {"name": "note", "type": "string", "summary": "n"}
      ],
      "writes": true, "batch": false, "paginated": false, "dry_run": false,
      "default_output": "minimal"
    }
  ]
}`

// stampTestServer wires a fake Barkpark that counts POSTs to the stamp route,
// points the CLI at it via a temp manifest file, and returns the hit counter.
func stampTestServer(t *testing.T) *int32 {
	t.Helper()
	var hits int32
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/stamp") {
			atomic.AddInt32(&hits, 1)
			_, _ = w.Write([]byte(`{"ok":true}`))
			return
		}
		http.NotFound(w, r)
	}))
	t.Cleanup(backend.Close)

	mf := filepath.Join(t.TempDir(), "manifest.json")
	if err := os.WriteFile(mf, []byte(minimalStampManifest), 0o600); err != nil {
		t.Fatalf("write manifest: %v", err)
	}
	t.Setenv("BARKPARK_MANIFEST", mf)
	t.Setenv("BARKPARK_API_URL", backend.URL)
	t.Setenv("BARKPARK_API_TOKEN", "stamp-stub")
	return &hits
}

// The tripwire must fire in the REAL dispatch, refusing BEFORE any POST — a
// mutation that forgot to call the guard from Execute would let the stamp reach
// the server (hits == 1, exit 0), reddening this test.
func TestTaskStampExecute_MergeGatedRefusedBeforeSend(t *testing.T) {
	hits := stampTestServer(t)
	out, code := captureExecuteCode(t, []string{
		"task", "stamp", "bp-task-x", "w", "1",
		"--criterion", "6", "--met", "--evidence", "e",
		"--criterion-text", "final row [MERGE-GATED — the lead closes this]",
	})
	if code != exitValidation {
		t.Fatalf("exit = %d, want exitValidation (%d); out:\n%s", code, exitValidation, out)
	}
	if n := atomic.LoadInt32(hits); n != 0 {
		t.Fatalf("stamp POST fired %d times; the guard must refuse BEFORE sending", n)
	}
	if !strings.Contains(out, "MERGE-GATED") || !strings.Contains(strings.ToLower(out), "refus") {
		t.Errorf("refusal message missing; got:\n%s", out)
	}
}

// --merge-gated releases the tripwire AND must be stripped before dispatch: if
// it leaked to splitArgs the manifest would reject it as an unknown flag (no
// POST, usage exit), so a reaching POST proves both the override and the strip.
func TestTaskStampExecute_OverrideReleasesAndStripsFlag(t *testing.T) {
	hits := stampTestServer(t)
	out, code := captureExecuteCode(t, []string{
		"task", "stamp", "bp-task-x", "w", "1",
		"--criterion", "6", "--met", "--evidence", "e",
		"--criterion-text", "final row [MERGE-GATED — the lead closes this]",
		"--merge-gated",
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK; out:\n%s", code, out)
	}
	if n := atomic.LoadInt32(hits); n != 1 {
		t.Fatalf("stamp POST fired %d times, want 1 (override sends; --merge-gated stripped)", n)
	}
	if !strings.Contains(out, "criterion #7") {
		t.Errorf("echo should still translate index 6 → criterion #7; got:\n%s", out)
	}
}

// A plain stamp reaches the server AND emits the translating echo — the
// end-to-end proof that a builder who stamps the criterion they SEE (#3, index
// 2) gets a one-line confirmation naming that exact board position.
func TestTaskStampExecute_EchoTranslatesOnNormalStamp(t *testing.T) {
	hits := stampTestServer(t)
	out, code := captureExecuteCode(t, []string{
		"task", "stamp", "bp-task-x", "w", "1",
		"--criterion", "2", "--met", "--evidence", "e",
		"--criterion-text", "a normal row",
	})
	if code != exitOK {
		t.Fatalf("exit = %d, want exitOK; out:\n%s", code, out)
	}
	if n := atomic.LoadInt32(hits); n != 1 {
		t.Fatalf("stamp POST fired %d times, want 1", n)
	}
	if !strings.Contains(out, "index 2 (0-based)") || !strings.Contains(out, "criterion #3") {
		t.Errorf("echo did not translate 0-based 2 → board #3; got:\n%s", out)
	}
}
